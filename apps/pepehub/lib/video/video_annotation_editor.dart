import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'video_annotations.dart';
import 'video_repository.dart';
import 'video_tools.dart';

/// Captured when the note action is pressed, independent of later player ticks.
class VideoAnnotationDraft {
  final VideoLesson lesson;
  final int positionMs, durationMs;
  final int? endMs;
  final VideoAnnotation? existing;
  final String? initialTitle, initialBody;
  final bool forAnki;
  const VideoAnnotationDraft({
    required this.lesson,
    required this.positionMs,
    required this.durationMs,
    this.endMs,
    this.existing,
    this.initialTitle,
    this.initialBody,
    this.forAnki = false,
  });
}

/// Shared geometry keeps the original video mounted and clear of the editor.
class VideoAnnotationLayout {
  late final Rect video, editor;
  VideoAnnotationLayout(Size size, EdgeInsets padding, double aspectRatio) {
    final area = Rect.fromLTWH(
      padding.left,
      padding.top,
      (size.width - padding.horizontal).clamp(0, double.infinity),
      (size.height - padding.vertical).clamp(0, double.infinity),
    );
    if (area.width >= 640 && area.width > area.height * 1.3) {
      final panel = (area.width * .38).clamp(280.0, 420.0);
      video = Rect.fromLTWH(
        area.left,
        area.top,
        area.width - panel,
        area.height,
      );
      editor = Rect.fromLTWH(video.right, area.top, panel, area.height);
    } else {
      // Keep a readable, unobscured frame even when the keyboard is visible.
      final frame = (area.width / aspectRatio.clamp(.5, 3.0))
          .clamp(0.0, (area.height - 140).clamp(0, area.height * .55))
          .toDouble();
      video = Rect.fromLTWH(area.left, area.top, area.width, frame);
      editor = Rect.fromLTWH(
        area.left,
        video.bottom,
        area.width,
        area.height - frame,
      );
    }
  }
}

class VideoAnnotationEditor extends StatefulWidget {
  final VideoRepository repository;
  final VideoAnnotationDraft draft;
  final ValueChanged<VideoAnnotation> onSaved;
  final VoidCallback onCancel;
  final ValueChanged<VideoAnnotationDraft>? onAnki;
  const VideoAnnotationEditor({
    super.key,
    required this.repository,
    required this.draft,
    required this.onSaved,
    required this.onCancel,
    this.onAnki,
  });
  @override
  State<VideoAnnotationEditor> createState() => VideoAnnotationEditorState();
}

class VideoAnnotationEditorState extends State<VideoAnnotationEditor> {
  final _form = GlobalKey<FormState>(), _bodyFocus = FocusNode();
  late final _body = TextEditingController(
    text: widget.draft.existing?.body ?? widget.draft.initialBody ?? '',
  );
  late final _start = TextEditingController(
    text: videoTimestamp(
      widget.draft.existing?.startMs ?? widget.draft.positionMs,
      precise: true,
    ),
  );
  late final _end = TextEditingController(
    text: (widget.draft.existing?.endMs ?? widget.draft.endMs) == null
        ? ''
        : videoTimestamp(
            (widget.draft.existing?.endMs ?? widget.draft.endMs)!,
            precise: true,
          ),
  );
  late final _title = TextEditingController(
    text:
        widget.draft.existing?.title ??
        widget.draft.initialTitle ??
        _automaticTitle,
  );
  late bool _manualTitle =
      widget.draft.existing != null || widget.draft.initialTitle != null;
  bool _details = false, saving = false;
  String? _error;
  late final (String, String, String, String) _initial;

  String get _automaticTitle {
    final first = _body.text.trim().split(RegExp(r'[\r\n]')).first.trim();
    return first.isEmpty
        ? 'Фрагмент ${videoTimestamp(parseVideoTimestamp(_start.text) ?? widget.draft.positionMs)}'
        : String.fromCharCodes(first.runes.take(140));
  }

  @override
  void initState() {
    super.initState();
    // Materialize the snapshot before the first keystroke changes controllers.
    _initial = (_body.text, _start.text, _end.text, _title.text);
  }

  @override
  void dispose() {
    _bodyFocus.dispose();
    _body.dispose();
    _start.dispose();
    _end.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> requestClose() async {
    if (saving) return;
    final dirty = (_body.text, _start.text, _end.text, _title.text) != _initial;
    if (dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Закрыть без сохранения?'),
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

  String? _timeError(String? text) {
    final time = parseVideoTimestamp(text ?? '');
    if (time == null) return 'Введите секунды или мм:сс';
    if (widget.draft.durationMs > 0 && time > widget.draft.durationMs) {
      return 'Время больше длительности видео';
    }
    return null;
  }

  String? _endError(String? text) {
    if ((text ?? '').trim().isEmpty) return null;
    final error = _timeError(text);
    if (error != null) return error;
    final start = parseVideoTimestamp(_start.text);
    return start != null && parseVideoTimestamp(text!)! <= start
        ? 'Конец должен быть позже начала'
        : null;
  }

  String? _titleError(String? text) =>
      (text ?? '').trim().isEmpty || (text?.trim().runes.length ?? 0) > 140
      ? 'От 1 до 140 знаков'
      : null;

  Future<void> submit() async {
    if (saving) return;
    if (!_manualTitle) _title.text = _automaticTitle;
    final metadataError =
        _titleError(_title.text) ??
        _timeError(_start.text) ??
        _endError(_end.text);
    if (metadataError != null) {
      setState(() {
        _details = true;
        _error = metadataError;
      });
      return;
    }
    if (!_form.currentState!.validate()) return;
    setState(() {
      saving = true;
      _error = null;
    });
    try {
      final saved = await widget.repository.saveAnnotation(
        widget.draft.lesson,
        existing: widget.draft.existing,
        title: _title.text,
        body: _body.text,
        startMs: parseVideoTimestamp(_start.text)!,
        endMs: _end.text.trim().isEmpty ? null : parseVideoTimestamp(_end.text),
        durationMs: widget.draft.durationMs,
      );
      if (mounted) widget.onSaved(saved);
    } catch (error) {
      if (mounted) {
        setState(() {
          saving = false;
          _error = '$error';
        });
      }
    }
  }

  Widget _text({required bool expanded}) => TextFormField(
    key: const ValueKey('video-annotation-body'),
    controller: _body,
    focusNode: _bodyFocus,
    autofocus: true,
    enabled: !saving,
    expands: expanded,
    minLines: expanded ? null : 2,
    maxLines: expanded ? null : 4,
    textAlignVertical: TextAlignVertical.top,
    textCapitalization: TextCapitalization.sentences,
    keyboardType: TextInputType.multiline,
    decoration: const InputDecoration(
      hintText: 'Запишите фразу или свою мысль…',
      isDense: true,
      contentPadding: EdgeInsets.all(12),
    ),
    onChanged: (_) {
      if (!_manualTitle) _title.text = _automaticTitle;
    },
    validator: (text) =>
        (text?.runes.length ?? 0) > 20000 ? 'До 20000 знаков' : null,
  );

  @override
  Widget build(BuildContext context) => FocusScope(
    autofocus: true,
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): submit,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): submit,
        const SingleActivator(LogicalKeyboardKey.escape): requestClose,
      },
      child: Material(
        key: const ValueKey('video-annotation-editor'),
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
                    if (widget.onAnki != null)
                      IconButton(
                        tooltip: 'Сделать карточку Anki',
                        onPressed: saving
                            ? null
                            : () {
                                final error =
                                    _timeError(_start.text) ??
                                    _endError(_end.text);
                                if (error != null) {
                                  setState(() {
                                    _details = true;
                                    _error = error;
                                  });
                                  return;
                                }
                                widget.onAnki!(
                                  VideoAnnotationDraft(
                                    lesson: widget.draft.lesson,
                                    positionMs: parseVideoTimestamp(
                                      _start.text,
                                    )!,
                                    durationMs: widget.draft.durationMs,
                                    endMs: _end.text.trim().isEmpty
                                        ? null
                                        : parseVideoTimestamp(_end.text),
                                    initialBody: _body.text,
                                    forAnki: true,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.style_outlined),
                        iconSize: 20,
                        visualDensity: VisualDensity.compact,
                      ),
                    Expanded(
                      child: Tooltip(
                        message: widget.draft.lesson.title,
                        child: Text(
                          videoTimestamp(
                            parseVideoTimestamp(_start.text) ??
                                widget.draft.positionMs,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: _details
                          ? 'Скрыть параметры заметки'
                          : 'Параметры заметки',
                      onPressed: saving
                          ? null
                          : () => setState(() => _details = !_details),
                      icon: Icon(
                        _details ? Icons.expand_less : Icons.tune,
                        size: 20,
                      ),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(40, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.all(8),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Отменить заметку',
                      onPressed: saving ? null : requestClose,
                      icon: const Icon(Icons.close, size: 20),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(40, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.all(8),
                      ),
                    ),
                    Flexible(
                      flex: 3,
                      child: TextButton(
                        onPressed: saving ? null : submit,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
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
                            : const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text('Сохранить'),
                              ),
                      ),
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
                  child: _details
                      ? SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _text(expanded: false),
                              const SizedBox(height: 12),
                              TextFormField(
                                key: const ValueKey('video-annotation-title'),
                                controller: _title,
                                enabled: !saving,
                                decoration: const InputDecoration(
                                  labelText: 'Название',
                                  isDense: true,
                                ),
                                onChanged: (_) => _manualTitle = true,
                                validator: _titleError,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                key: const ValueKey('video-annotation-start'),
                                controller: _start,
                                onChanged: (_) {
                                  if (!_manualTitle) {
                                    _title.text = _automaticTitle;
                                  }
                                  setState(() {});
                                },
                                enabled: !saving,
                                decoration: const InputDecoration(
                                  labelText: 'Начало',
                                  isDense: true,
                                ),
                                validator: _timeError,
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                key: const ValueKey('video-annotation-end'),
                                controller: _end,
                                enabled: !saving,
                                decoration: const InputDecoration(
                                  labelText: 'Конец — необязательно',
                                  isDense: true,
                                ),
                                validator: _endError,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                widget.draft.lesson.title,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        )
                      : _text(expanded: true),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
