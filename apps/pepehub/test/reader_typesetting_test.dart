import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/reader_keep_awake.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reader_window.dart';

import 'reader_improvements_test.dart' show settle, size;

String spanText(InlineSpan span) =>
    span.toPlainText(includePlaceholders: false);

Widget pagedReader(
  String text,
  ReaderPreferences preferences, {
  ValueChanged<int>? onPosition,
  ReaderViewportController? controller,
}) => MaterialApp(
  home: Scaffold(
    body: ReaderViewport(
      controller: controller,
      text: text,
      style: const TextStyle(fontSize: 18, height: 1.4),
      scaler: TextScaler.noScaling,
      width: 420,
      height: 500,
      margin: 20,
      anchor: 0,
      scrolling: false,
      firstChapter: true,
      lastChapter: true,
      onPosition: onPosition ?? (_) {},
      onChapter: (_) {},
      preferences: preferences,
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('typesetting preferences round-trip with safe defaults', () {
    const defaults = ReaderPreferences();
    expect(defaults.textAlign, 'left');
    expect(defaults.keepAwake, isTrue);
    expect(defaults.volumeKeys, isFalse);
    final restored = ReaderPreferences.fromJson(
      const ReaderPreferences(
        textAlign: 'justify',
        keepAwake: false,
        volumeKeys: true,
      ).toJson(),
    );
    expect(restored.textAlign, 'justify');
    expect(restored.keepAwake, isFalse);
    expect(restored.volumeKeys, isTrue);
    expect(
      ReaderPreferences.fromJson({'textAlign': 'center'}).textAlign,
      'left',
    );
    expect(ReaderPreferences.fromJson({}).keepAwake, isTrue);
  });

  testWidgets('justified pages keep the line before a page break justified', (
    tester,
  ) async {
    size(tester, const Size(420, 500));
    final text = 'Слово за словом складывается длинный абзац. ' * 120;
    await tester.pumpWidget(
      pagedReader(text, const ReaderPreferences(textAlign: 'justify')),
    );
    await settle(tester);
    final page = tester.widget<SelectableText>(
      find.byType(SelectableText).first,
    );
    expect(page.textAlign, TextAlign.justify);
    final rendered = spanText(page.textSpan!);
    expect(rendered, endsWith(justifyFillerText));
    final book = rendered.substring(
      0,
      rendered.length - justifyFillerText.length,
    );
    expect(text.startsWith(book), isTrue, reason: 'offsets must stay intact');
    expect(tester.takeException(), isNull);
  });

  testWidgets('left alignment adds no filler', (tester) async {
    size(tester, const Size(420, 500));
    final text = 'Слово за словом складывается длинный абзац. ' * 120;
    await tester.pumpWidget(pagedReader(text, const ReaderPreferences()));
    await settle(tester);
    final page = tester.widget<SelectableText>(
      find.byType(SelectableText).first,
    );
    expect(page.textAlign, TextAlign.left);
    expect(spanText(page.textSpan!), isNot(endsWith(justifyFillerText)));
  });

  testWidgets('a page ending its paragraph needs no filler', (tester) async {
    size(tester, const Size(420, 500));
    await tester.pumpWidget(
      pagedReader(
        'Короткий абзац.\n\nЕщё один короткий абзац.',
        const ReaderPreferences(textAlign: 'justify'),
      ),
    );
    await settle(tester);
    final page = tester.widget<SelectableText>(
      find.byType(SelectableText).first,
    );
    expect(spanText(page.textSpan!), isNot(endsWith(justifyFillerText)));
  });

  testWidgets('volume buttons turn pages through the reader window channel', (
    tester,
  ) async {
    size(tester, const Size(420, 500));
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReaderWindow.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReaderWindow.channel, null),
    );
    final controller = ReaderViewportController();
    var position = 0;
    final window = ReaderWindow(onVolumeKey: controller.turn);
    await tester.pumpWidget(
      pagedReader(
        'A long text for reading. ' * 400,
        const ReaderPreferences(volumeKeys: true),
        onPosition: (v) => position = v,
        controller: controller,
      ),
    );
    await settle(tester);
    window.configure(volumeKeys: true, navigationBar: true);
    await tester.pump();
    expect(calls.single.method, 'configure');
    expect(calls.single.arguments, {
      'volumeKeys': true,
      'navigationBar': true,
    });
    // An unchanged configuration is not sent again.
    window.configure(volumeKeys: true, navigationBar: true);
    expect(calls, hasLength(1));

    Future<void> press(int direction) async {
      await messenger.handlePlatformMessage(
        ReaderWindow.channel.name,
        ReaderWindow.channel.codec.encodeMethodCall(
          MethodCall('volumeKey', direction),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await press(1);
    expect(position, greaterThan(0));
    final prior = position;
    await press(-1);
    expect(position, lessThan(prior));

    window.reset();
    await tester.pump();
    expect(calls.last.method, 'reset');
    // After closing, stray key messages are ignored.
    final last = position;
    await press(1);
    expect(position, last);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('keep awake holds the screen until the reader idles', (
    tester,
  ) async {
    final calls = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReaderKeepAwake.channel, (call) async {
          if (call.method == 'setReadingAwake') calls.add(call.arguments);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ReaderKeepAwake.channel, null),
    );
    final awake = ReaderKeepAwake(idle: const Duration(minutes: 10));
    awake.touch();
    await tester.pump();
    expect(calls, isEmpty, reason: 'disabled by default');
    awake.enabled = true;
    await tester.pump();
    expect(calls, [true]);
    await tester.pump(const Duration(minutes: 9));
    awake.touch();
    await tester.pump(const Duration(minutes: 9));
    expect(awake.awake, isTrue, reason: 'activity extends the period');
    await tester.pump(const Duration(minutes: 2));
    expect(calls, [true, false]);
    awake.touch();
    await tester.pump();
    expect(calls, [true, false, true]);
    awake.enabled = false;
    await tester.pump();
    expect(calls, [true, false, true, false]);
    awake.dispose();
  });
}
