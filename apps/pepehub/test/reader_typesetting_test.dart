import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/reader_keep_awake.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_viewport.dart';

import 'reader_improvements_test.dart' show settle, size;

String spanText(InlineSpan span) =>
    span.toPlainText(includePlaceholders: false);

Widget pagedReader(
  String text,
  ReaderPreferences preferences, {
  ValueChanged<int>? onPosition,
}) => MaterialApp(
  home: Scaffold(
    body: ReaderViewport(
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

  testWidgets('volume buttons turn pages only when enabled on Android', (
    tester,
  ) async {
    size(tester, const Size(420, 500));
    final text = 'A long text for reading. ' * 400;
    for (final enabled in [false, true]) {
      var position = 0;
      await tester.pumpWidget(
        pagedReader(
          text,
          ReaderPreferences(volumeKeys: enabled),
          onPosition: (v) => position = v,
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(SelectableText).first);
      await tester.pumpAndSettle();
      position = 0;
      await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeDown);
      await tester.pumpAndSettle();
      if (enabled) {
        expect(position, greaterThan(0));
        final prior = position;
        await tester.sendKeyEvent(LogicalKeyboardKey.audioVolumeUp);
        await tester.pumpAndSettle();
        expect(position, lessThan(prior));
      } else {
        expect(position, 0);
      }
      await tester.pumpWidget(const SizedBox());
    }
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
