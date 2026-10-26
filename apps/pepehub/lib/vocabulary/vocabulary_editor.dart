import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/pepe_widgets.dart';
import 'vocabulary_repository.dart';

class VocabularyEditor extends StatefulWidget {
  final VocabularyRepository repository;
  final VocabularyCard? existing;
  final VocabularySource? source;
  final String initialFront, initialContext;
  final ValueChanged<VocabularyCard> onSaved;
  final ValueChanged<VocabularyCard>? onSavedAndNext;
  final VoidCallback onCancel;
  const VocabularyEditor({
    super.key,
    required this.repository,
    this.existing,
    this.source,
    this.initialFront = '',
    this.initialContext = '',
    required this.onSaved,
    this.onSavedAndNext,
    required this.onCancel,
  });
  @override
  State<VocabularyEditor> createState() => VocabularyEditorState();
}

class VocabularyEditorState extends State<VocabularyEditor> {
  final _form = GlobalKey<FormState>();
  final _frontFocus = FocusNode();
  late final _front = TextEditingController(
    text: widget.existing?.front ?? widget.initialFront,
  );
  late final _back = TextEditingController(text: widget.existing?.back ?? '');
  late final _context = TextEditingController(
    text: widget.existing?.context ?? widget.initialContext,
  );
  late final _deck = TextEditingController(
    text: widget.existing?.deck ?? 'PepeHub',
  );
  late final _tags = TextEditingController(
    text: widget.existing?.tags.join(' ') ?? '',
  );
  late VocabularyKind _kind =
      widget.existing?.kind ??
      (widget.initialFront.trim().contains(RegExp(r'[.!?。！？]$'))
          ? VocabularyKind.sentence
          : VocabularyKind.word);
  late String _initial;
  bool _details = false, saving = false;
  String? _error;

  String get _snapshot => [
    _front.text,
    _back.text,
    _context.text,
    _deck.text,
    _tags.text,
    _kind.name,
  ].join('\u0000');

  @override
  void initState() {
    super.initState();
    _initial = _snapshot;
  }

  @override
  void dispose() {
    _frontFocus.dispose();
    for (final input in [_front, _back, _context, _deck, _tags]) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> requestClose() async {
    if (saving) return;
    if (_snapshot != _initial) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Закрыть карточку без сохранения?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Продолжить писать'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Не сохранять'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    if (mounted) widget.onCancel();
  }

  Future<void> submit({bool next = false}) async {
    if (saving || !_form.currentState!.validate()) return;
    setState(() {
      saving = true;
      _error = null;
    });
    try {
      final card = await widget.repository.save(
        existing: widget.existing,
        source: widget.source,
        kind: _kind,
        front: _front.text,
        back: _back.text,
        context: _context.text,
        deck: _deck.text,
        tags: _tags.text.split(RegExp(r'\s+')),
      );
      if (!mounted) return;
      if (next && widget.onSavedAndNext != null) {
        setState(() {
          _front.clear();
          _back.clear();
          _context.clear();
          saving = false;
          _initial = _snapshot;
        });
        widget.onSavedAndNext!(card);
        _frontFocus.requestFocus();
      } else {
        widget.onSaved(card);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          saving = false;
          _error = '$error';
        });
      }
    }
  }

  Widget _input(
    String id,
    TextEditingController controller,
    String label,
    int limit, {
    bool required = false,
    int maxLines = 2,
    FocusNode? focus,
  }) => TextFormField(
    key: ValueKey('vocabulary-$id'),
    controller: controller,
    focusNode: focus,
    autofocus: focus != null,
    enabled: !saving,
    minLines: 1,
    maxLines: maxLines,
    keyboardType: TextInputType.multiline,
    textCapitalization: TextCapitalization.sentences,
    decoration: InputDecoration(
      labelText: label,
      isDense: true,
      contentPadding: const EdgeInsets.all(10),
    ),
    validator: (text) => required && (text ?? '').trim().isEmpty
        ? 'Заполните поле'
        : (text?.runes.length ?? 0) > limit
        ? 'До $limit знаков'
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final source = widget.existing?.source ?? widget.source;
    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              submit,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
          const SingleActivator(LogicalKeyboardKey.escape): requestClose,
        },
        child: Material(
          key: const ValueKey('vocabulary-editor'),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          source?.positionMs == null
                              ? 'Карточка Anki'
                              : 'Anki · ${vocabularyTime(source!.positionMs!)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        tooltip: _details
                            ? 'Скрыть детали карточки'
                            : 'Детали карточки',
                        onPressed: saving
                            ? null
                            : () => setState(() => _details = !_details),
                        icon: Icon(_details ? Icons.expand_less : Icons.tune),
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        tooltip: 'Закрыть карточку',
                        onPressed: saving ? null : requestClose,
                        icon: const Icon(Icons.close),
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                      ),
                      if (widget.onSavedAndNext != null)
                        IconButton(
                          key: const ValueKey('vocabulary-save-next'),
                          tooltip: 'Сохранить и следующая карточка',
                          onPressed: saving ? null : () => submit(next: true),
                          icon: const Icon(Icons.playlist_add),
                          iconSize: 20,
                          visualDensity: VisualDensity.compact,
                        ),
                      FilledButton(
                        onPressed: saving ? null : submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        child: saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Сохранить'),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Text(
                      _error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _input(
                            'front',
                            _front,
                            'Слово или предложение',
                            5000,
                            required: true,
                            maxLines: 4,
                            focus: _frontFocus,
                          ),
                          const SizedBox(height: 10),
                          _input(
                            'back',
                            _back,
                            'Перевод / ответ',
                            20000,
                            required: true,
                            maxLines: 4,
                          ),
                          if (_details) ...[
                            const SizedBox(height: 10),
                            SegmentedButton<VocabularyKind>(
                              segments: const [
                                ButtonSegment(
                                  value: VocabularyKind.word,
                                  label: Text('Слово'),
                                ),
                                ButtonSegment(
                                  value: VocabularyKind.sentence,
                                  label: Text('Предложение'),
                                ),
                              ],
                              selected: {_kind},
                              onSelectionChanged: saving
                                  ? null
                                  : (values) =>
                                        setState(() => _kind = values.single),
                            ),
                            const SizedBox(height: 10),
                            _input(
                              'context',
                              _context,
                              'Контекст / пример',
                              20000,
                              maxLines: 4,
                            ),
                            const SizedBox(height: 10),
                            _input(
                              'deck',
                              _deck,
                              'Колода Anki',
                              200,
                              required: true,
                              maxLines: 1,
                            ),
                            const SizedBox(height: 10),
                            _input(
                              'tags',
                              _tags,
                              'Теги через пробел',
                              5000,
                              maxLines: 2,
                            ),
                            if (source != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: Text(
                                  'Источник: ${source.label}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VocabularyEditorPage extends StatefulWidget {
  final VocabularyRepository repository;
  final VocabularyCard? existing;
  final VocabularySource? source;
  final String initialFront;
  const VocabularyEditorPage({
    super.key,
    required this.repository,
    this.existing,
    this.source,
    this.initialFront = '',
  });
  @override
  State<VocabularyEditorPage> createState() => _VocabularyEditorPageState();
}

class _VocabularyEditorPageState extends State<VocabularyEditorPage> {
  final editor = GlobalKey<VocabularyEditorState>();
  bool allowPop = false;
  void _finish(VocabularyCard? card) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, card);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) editor.currentState?.requestClose();
    },
    child: PepeSubpage(
      title: 'Карточка Anki',
      showAudioMiniPlayer: false,
      maxWidth: 780,
      body: VocabularyEditor(
        key: editor,
        repository: widget.repository,
        existing: widget.existing,
        source: widget.source,
        initialFront: widget.initialFront,
        onSaved: _finish,
        onCancel: () => _finish(null),
      ),
    ),
  );
}
