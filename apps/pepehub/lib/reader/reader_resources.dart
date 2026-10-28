import 'package:flutter/material.dart';

import 'epub.dart';

Future<void> showBookFootnote(BuildContext context, BookFootnote note) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .65,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  'Примечание ${note.label.replaceAll(RegExp(r'[\[\]]'), '')}',
                ),
                trailing: IconButton(
                  tooltip: 'Закрыть сноску',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: SelectableText(
                    note.text,
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

Future<void> showChapterResources(
  BuildContext context,
  EpubChapter chapter,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Сноски и иллюстрации',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(chapter.title),
          const SizedBox(height: 16),
          if (chapter.footnotes.isEmpty && chapter.illustrations.isEmpty)
            const Text(
              'В этой главе нет доступных встроенных сносок или иллюстраций.',
            ),
          for (final note in chapter.footnotes)
            ListTile(
              leading: const Icon(Icons.notes),
              title: Text('Сноска ${note.label}'),
              subtitle: Text(
                note.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => showBookFootnote(context, note),
            ),
          for (final illustration in chapter.illustrations)
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => showDialog<void>(
                  context: context,
                  useSafeArea: true,
                  builder: (context) => Dialog.fullscreen(
                    child: Scaffold(
                      appBar: AppBar(title: Text(illustration.label)),
                      body: InteractiveViewer(
                        minScale: .5,
                        maxScale: 5,
                        child: Center(
                          child: Image.memory(
                            illustration.bytes,
                            cacheWidth: 1600,
                            fit: BoxFit.contain,
                            errorBuilder: (_, e, s) => const Text(
                              'Формат изображения не поддерживается',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    Image.memory(
                      illustration.bytes,
                      height: 220,
                      cacheWidth: 700,
                      fit: BoxFit.contain,
                      errorBuilder: (_, e, s) => const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Не удалось показать изображение'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('${illustration.label} · увеличить'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);
