import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_resume.dart';
import 'package:pepehub/ui/audio_rewind_options.dart';

void main() {
  test(
    'pause thresholds, zero/disabled choices and damaged settings are explicit',
    () {
      const policy = AudioRewindSettings();
      for (final entry in {
        0: 0,
        4: 0,
        5: 3,
        59: 3,
        60: 10,
        3599: 10,
        3600: 30,
        86400: 30,
      }.entries) {
        expect(policy.secondsAfter(Duration(seconds: entry.key)), entry.value);
      }
      expect(policy.secondsAfter(const Duration(seconds: -1)), 0);
      expect(
        policy.copyWith(enabled: false).secondsAfter(const Duration(days: 1)),
        0,
      );
      final custom = policy.copyWith(
        shortSeconds: 0,
        mediumSeconds: 45,
        longSeconds: 120,
      );
      expect(
        AudioRewindSettings.fromJson(custom.toJson())
            .secondsAfter(const Duration(hours: 2)),
        120,
      );
      expect(
        AudioRewindSettings.fromJson({
          'short': -1,
          'medium': 'wrong',
          'long': 9999,
        }).toJson(),
        policy.toJson(),
      );
    },
  );
  testWidgets(
    'return settings fit a phone with large text and persist distinct choices via callbacks',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var settings = const AudioRewindSettings();
      var sleep = 10, enabled = true;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: Scaffold(
                body: SafeArea(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: AudioRewindOptions(
                        sleepEnabled: enabled,
                        sleepSeconds: sleep,
                        settings: settings,
                        onSleepEnabled: (v) => setState(() => enabled = v),
                        onSleepSeconds: (v) => setState(() => sleep = v),
                        onSettings: (v) => setState(() => settings = v),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButton<int>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('45 с').last);
      await tester.pumpAndSettle();
      expect(sleep, 45);
      await tester.scrollUntilVisible(find.text('Пауза от 1 часа'), 200);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(DropdownButton<int>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('120 с').last);
      await tester.pumpAndSettle();
      expect(settings.longSeconds, 120);
      expect(tester.takeException(), isNull);
    },
  );
}
