import 'package:flutter/material.dart';

import '../library/models.dart';
import 'obsidian_library_page.dart' show libraryLabels;

Future<Map<String, String>?> reviewLibraryLink(
  BuildContext context,
  ObsidianLibraryItem target,
  ObsidianLibraryItem source,
) {
  final sourceFields = {
    for (final field in source.fields) field.field: field.key,
  };
  final fields = [
    'status',
    'total',
    'progress',
    'unit',
    'startDate',
    'endDate',
    'readingTime',
    'author',
    'genre',
    'series',
  ];
  final selected = {
    'status',
    'progress',
    'total',
    'unit',
    'startDate',
    'endDate',
    'readingTime',
  };
  String text(Object? value) => value == null || value == ''
      ? 'Не указано'
      : value is List
      ? value.join(', ')
      : '$value';
  return showDialog<Map<String, String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Связать карточку'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  target.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(target.path, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                const Text(
                  'Выберите поля, которые будут обновляться из файла и истории чтения. Остальные значения останутся в карточке библиотеки.',
                ),
                for (final field in fields)
                  if (source.values[sourceFields[field]] != null &&
                      source.values[sourceFields[field]] != '')
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(libraryLabels[field] ?? field),
                      subtitle: Text(
                        'Библиотека: ${text(target.value(field))}\nИз файла: ${text(source.value(field))}',
                      ),
                      value: selected.contains(field),
                      onChanged: (value) => update(() {
                        final group =
                            ['total', 'progress', 'unit'].contains(field)
                            ? ['total', 'progress', 'unit']
                            : [field];
                        if (value == true) {
                          selected.addAll(group);
                        } else {
                          selected.removeAll(group);
                        }
                      }),
                    ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              for (final field in fields)
                field: selected.contains(field) ? 'local' : 'obsidian',
            }),
            child: const Text('Связать'),
          ),
        ],
      ),
    ),
  );
}
