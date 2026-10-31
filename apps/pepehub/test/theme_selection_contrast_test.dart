import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/ui/app_theme.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  for (final style in AppStyle.values) {
    testWidgets(
      'selected filter, choice and icon stay readable in ${style.name}',
      (tester) async {
        final theme = AppTheme.data(Brightness.dark, style: style);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  FilterChip(
                    label: const Text('Избранное'),
                    selected: true,
                    onSelected: (_) {},
                  ),
                  ChoiceChip(
                    label: const Text('Период'),
                    selected: true,
                    onSelected: (_) {},
                  ),
                  FilterChip(
                    label: const Text('Все'),
                    selected: false,
                    onSelected: (_) {},
                  ),
                  IconButton(
                    isSelected: true,
                    onPressed: () {},
                    icon: const Icon(Icons.shuffle),
                  ),
                ],
              ),
            ),
          ),
        );
        Color textColor(String text) =>
            DefaultTextStyle.of(tester.element(find.text(text))).style.color!;
        expect(
          contrast(textColor('Избранное'), theme.chipTheme.selectedColor!),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(textColor('Период'), theme.chipTheme.selectedColor!),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(textColor('Все'), theme.chipTheme.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
        final iconColor = IconTheme.of(
          tester.element(find.byIcon(Icons.shuffle)),
        ).color!;
        expect(
          contrast(iconColor, theme.colorScheme.primary),
          greaterThanOrEqualTo(3),
        );
        expect(
          contrast(
            theme.chipTheme.checkmarkColor!,
            theme.chipTheme.selectedColor!,
          ),
          greaterThanOrEqualTo(3),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
