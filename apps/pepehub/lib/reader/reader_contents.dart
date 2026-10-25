import 'package:flutter/material.dart';

/// Keeps original chapter indexes when the visible list is filtered.
class ReaderContentsSearch extends StatefulWidget {
  final List<String> titles;
  final Widget Function(BuildContext context, List<int> indexes) builder;
  const ReaderContentsSearch({
    super.key,
    required this.titles,
    required this.builder,
  });

  @override
  State<ReaderContentsSearch> createState() => _ReaderContentsSearchState();
}

class _ReaderContentsSearchState extends State<ReaderContentsSearch> {
  final controller = TextEditingController();
  String query = '';
  String? _cachedQuery;
  List<int> _indexes = const [];

  @override
  void didUpdateWidget(covariant ReaderContentsSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.titles, widget.titles)) _cachedQuery = null;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    if (_cachedQuery != normalized) {
      _cachedQuery = normalized;
      _indexes = [
        for (var i = 0; i < widget.titles.length; i++)
          if (normalized.isEmpty ||
              widget.titles[i].toLowerCase().contains(normalized) ||
              '${i + 1}' == normalized)
            i,
      ];
    }
    final indexes = _indexes;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: 'Найти главу',
              hintText: 'Название или номер главы',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Сбросить поиск глав',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        controller.clear();
                        setState(() => query = '');
                      },
                    ),
            ),
            onChanged: (value) => setState(() => query = value),
          ),
        ),
        Expanded(
          child: indexes.isEmpty
              ? const Center(child: Text('Главы не найдены'))
              : widget.builder(context, indexes),
        ),
      ],
    );
  }
}
