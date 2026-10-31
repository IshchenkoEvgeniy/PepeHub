import 'dart:convert';

import 'package:flutter/material.dart';

import '../library/metadata_values.dart';

/// Local suggestions from the downloaded library; no network or keyboard trap.
class MetadataTokensField extends StatefulWidget {
  final TextEditingController controller;
  final Object? initial;
  final String label;
  final List<String> suggestions;
  final bool enabled;
  const MetadataTokensField({
    super.key,
    required this.controller,
    required this.label,
    required this.suggestions,
    required this.enabled,
    this.initial,
  });
  @override
  State<MetadataTokensField> createState() => _MetadataTokensFieldState();
}

class _MetadataTokensFieldState extends State<MetadataTokensField> {
  final input = TextEditingController();
  final focus = FocusNode();
  late List<String> selected = metadataStrings(widget.initial);
  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  void commit(String value, {bool split = false}) {
    if (!widget.enabled) return;
    final text = value.trim();
    if (text.isEmpty) return;
    setState(() {
      selected = metadataStrings([
        ...selected,
        ...split ? metadataStrings(text) : [text],
      ]);
      input.clear();
      widget.controller.text = jsonEncode(selected);
    });
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      RawAutocomplete<String>(
        textEditingController: input,
        focusNode: focus,
        optionsBuilder: (text) => widget.suggestions
            .where(
              (s) =>
                  !selected.any((v) => v.toLowerCase() == s.toLowerCase()) &&
                  s.toLowerCase().contains(text.text.trim().toLowerCase()),
            )
            .take(8),
        onSelected: commit,
        optionsViewBuilder: (context, onSelected, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width.clamp(0, 440) - 56,
                maxHeight: 240,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final option in options)
                    ListTile(
                      dense: true,
                      title: Text(option),
                      onTap: () => onSelected(option),
                    ),
                ],
              ),
            ),
          ),
        ),
        fieldViewBuilder: (context, controller, node, submit) => TextFormField(
          controller: controller,
          focusNode: node,
          enabled: widget.enabled,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: 'Введите или выберите',
            suffixIcon: IconButton(
              tooltip: 'Добавить',
              onPressed: widget.enabled
                  ? () => commit(input.text, split: true)
                  : null,
              icon: const Icon(Icons.add),
            ),
          ),
          textInputAction: TextInputAction.done,
          onFieldSubmitted: (_) {
            submit();
            if (input.text.trim().isNotEmpty) {
              commit(input.text, split: true);
            }
          },
          onChanged: (text) => widget.controller.text = jsonEncode([
            ...selected,
            ...metadataStrings(text),
          ]),
        ),
      ),
      if (selected.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final value in selected)
                InputChip(
                  label: Text(value),
                  deleteButtonTooltipMessage: 'Убрать',
                  onDeleted: !widget.enabled
                      ? null
                      : () => setState(() {
                          selected.remove(value);
                          widget.controller.text = jsonEncode([
                            ...selected,
                            ...metadataStrings(input.text),
                          ]);
                        }),
                ),
            ],
          ),
        ),
    ],
  );
}
