import 'package:flutter/material.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import 'library_duration_input.dart';

Future<void> editLibraryAudioTime(
  BuildContext context,
  LibraryService service,
  LibraryEntry entry,
) async {
  final unit = entry.item.value('unit') == 'hours' ? 'hours' : 'minutes';
  final total = TextEditingController(
    text: '${entry.item.value('total') ?? ''}',
  );
  final progress = TextEditingController(
    text: '${entry.item.value('progress') ?? ''}',
  );
  final form = GlobalKey<FormState>();
  var saving = false;
  String? error;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Время прослушивания',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(entry.item.title),
                const SizedBox(height: 20),
                LibraryDurationInput(
                  controller: total,
                  label: 'Общая длительность аудиокниги',
                  unit: unit,
                  enabled: !saving,
                ),
                LibraryDurationInput(
                  controller: progress,
                  label: 'Прослушано',
                  unit: unit,
                  enabled: !saving,
                ),
                ListenableBuilder(
                  listenable: Listenable.merge([total, progress]),
                  builder: (context, _) {
                    final length = double.tryParse(total.text) ?? 0,
                        heard = double.tryParse(progress.text) ?? 0;
                    final known = length.isFinite && length > 0;
                    final percent = known && heard.isFinite
                        ? (heard / length * 100).clamp(0.0, 100.0)
                        : 0.0;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          known ? 'Прослушано ${percent.toStringAsFixed(1)}%' : 'Укажите общую длительность для ввода в процентах.',
                        ),
                        Slider(
                          value: percent,
                          min: 0,
                          max: 100,
                          divisions: 1000,
                          onChanged: known && !saving
                              ? (percent) =>
                                    progress.text = '${length * percent / 100}'
                              : null,
                        ),
                        TextButton(
                          onPressed: known && !saving
                              ? () => progress.text = total.text
                              : null,
                          child: const Text('Прослушано полностью'),
                        ),
                      ],
                    );
                  },
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          if (!form.currentState!.validate()) return;
                          final length = num.tryParse(total.text),
                              heard = num.tryParse(progress.text);
                          if (length != null &&
                              length > 0 &&
                              heard != null &&
                              heard > length) {
                            update(
                              () => error = 'Прослушанное время больше общей длительности.',
                            );
                            return;
                          }
                          update(() {
                            saving = true;
                            error = null;
                          });
                          try {
                            await service.save(entry.item.id, {
                              ...entry.item.values,
                              'total': length,
                              'progress': heard,
                              'unit': unit,
                            }, original: entry.item.values);
                            if (context.mounted) Navigator.pop(context);
                          } catch (failure) {
                            if (context.mounted) {
                              update(() {
                                saving = false;
                                error = '$failure';
                              });
                            }
                          }
                        },
                  child: Text(saving ? 'Сохранение…' : 'Сохранить'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  total.dispose();
  progress.dispose();
}
