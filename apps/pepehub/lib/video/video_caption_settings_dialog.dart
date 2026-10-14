import 'package:flutter/material.dart';

import 'video_captions_controller.dart';
import 'video_subtitle_import.dart';
import 'video_subtitles.dart';

class VideoCaptionSettingsDialog extends StatefulWidget {
  final VideoCaptionsController captions;
  final VideoSubtitlePicker picker;
  const VideoCaptionSettingsDialog({
    super.key,
    required this.captions,
    required this.picker,
  });
  @override
  State<VideoCaptionSettingsDialog> createState() =>
      _VideoCaptionSettingsDialogState();
}

class _VideoCaptionSettingsDialogState
    extends State<VideoCaptionSettingsDialog> {
  final form = GlobalKey<FormState>();
  late final lessonKey =
      '${widget.captions.lesson?.id}:${widget.captions.lesson?.mediaVersion}';
  late String audio = widget.captions.settings.audio,
      subtitle = widget.captions.settings.subtitle;
  late String translation = widget.captions.settings.translation ?? '';
  late int fontSize = widget.captions.settings.fontSize;
  late bool background = widget.captions.settings.subtitleBackground,
      translationVisible = widget.captions.settings.translationVisible;
  late final subtitleDelay = TextEditingController(
    text: '${widget.captions.settings.subtitleDelayMs / 1000}',
  );
  late final translationDelay = TextEditingController(
    text: '${widget.captions.settings.translationDelayMs / 1000}',
  );
  late final audioDelay = TextEditingController(
    text: '${widget.captions.settings.audioDelayMs / 1000}',
  );
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.captions.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.captions.removeListener(_changed);
    subtitleDelay.dispose();
    translationDelay.dispose();
    audioDelay.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final file = await widget.picker();
      if (file == null || !mounted) return;
      final imported = await showDialog<bool>(
        context: context,
        builder: (_) =>
            _SubtitleImportDialog(captions: widget.captions, file: file),
      );
      if (imported == true && mounted) {
        setState(() {
          subtitle = widget.captions.settings.subtitle;
          translation = widget.captions.settings.translation ?? '';
          subtitleDelay.text =
              '${widget.captions.settings.subtitleDelayMs / 1000}';
          translationDelay.text =
              '${widget.captions.settings.translationDelayMs / 1000}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _save() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (lessonKey !=
          '${widget.captions.lesson?.id}:${widget.captions.lesson?.mediaVersion}') {
        throw StateError('Урок сменился. Откройте настройки заново');
      }
      int milliseconds(TextEditingController input) =>
          (double.parse(input.text.replaceAll(',', '.')) * 1000).round();
      await widget.captions.save(
        VideoPlaybackSettings(
          audio: audio,
          subtitle: subtitle,
          translation: translation.isEmpty ? null : translation,
          subtitleDelayMs: milliseconds(subtitleDelay),
          translationDelayMs: milliseconds(translationDelay),
          audioDelayMs: milliseconds(audioDelay),
          fontSize: fontSize,
          subtitleBackground: background,
          translationVisible: translationVisible,
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  Widget _delay(
    String label,
    TextEditingController input,
    int bound,
    Key key,
  ) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextFormField(
      key: key,
      controller: input,
      enabled: !saving,
      decoration: InputDecoration(
        labelText: label,
        helperText: 'Секунды. Положительное значение — позже',
      ),
      validator: (value) {
        final seconds = double.tryParse((value ?? '').replaceAll(',', '.'));
        return seconds == null || !seconds.isFinite || seconds.abs() > bound
            ? 'От -$bound до $bound секунд'
            : null;
      },
    ),
  );
  @override
  Widget build(BuildContext context) {
    final captions = widget.captions, engine = widget.captions.playback.engine;
    final audioChoices = {
      for (final track in engine.audioTracks) track.id: track.label,
    };
    if (audioChoices.isEmpty) audioChoices['auto'] = 'Автоматически';
    audioChoices.putIfAbsent(audio, () => 'Недоступная дорожка ($audio)');
    final subtitleChoices = {
      'auto': 'Автоматически',
      'no': 'Без субтитров',
      for (final track in engine.subtitleTracks)
        if (track.id != 'auto' && track.id != 'no')
          'embedded:${track.id}':
              '${track.label}${track.image ? ' · графические' : ''}',
      for (final source in captions.records)
        'external:${source.id}': source.name,
    };
    subtitleChoices.putIfAbsent(
      subtitle,
      () => 'Сохранённые субтитры недоступны',
    );
    final translationChoices = {
      '': 'Без перевода',
      for (final source in captions.records)
        if (source.format != VideoSubtitleFormat.ass) source.id: source.name,
    };
    translationChoices.putIfAbsent(
      translation,
      () => 'Сохранённый перевод недоступен',
    );
    Widget choice(
      String label,
      Map<String, String> options,
      String selected,
      void Function(String) change,
      String key, {
      bool enabled = true,
    }) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$key:$selected'),
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final entry in options.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(
                entry.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: saving || !enabled
            ? null
            : (value) => setState(() => change(value!)),
      ),
    );
    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: const Text('Дорожки и субтитры'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  choice(
                    'Аудиодорожка',
                    audioChoices,
                    audio,
                    (value) => audio = value,
                    'video-audio-track',
                    enabled: engine.canSelectTracks,
                  ),
                  choice(
                    'Основные субтитры',
                    subtitleChoices,
                    subtitle,
                    (value) => subtitle = value,
                    'video-subtitle-track',
                  ),
                  _delay(
                    'Смещение основных субтитров',
                    subtitleDelay,
                    60,
                    const ValueKey('video-subtitle-delay'),
                  ),
                  choice(
                    'Перевод — второй SRT/WebVTT',
                    translationChoices,
                    translation,
                    (value) => translation = value,
                    'video-subtitle-translation',
                  ),
                  if (translation.isNotEmpty) ...[
                    _delay(
                      'Смещение перевода',
                      translationDelay,
                      60,
                      const ValueKey('video-translation-delay'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Показывать перевод'),
                      value: translationVisible,
                      onChanged: saving
                          ? null
                          : (value) =>
                                setState(() => translationVisible = value!),
                    ),
                  ],
                  _delay(
                    'Смещение звука',
                    audioDelay,
                    10,
                    const ValueKey('video-audio-delay'),
                  ),
                  const SizedBox(height: 12),
                  Text('Размер текста: $fontSize'),
                  Slider(
                    key: const ValueKey('video-subtitle-size'),
                    value: fontSize.toDouble(),
                    min: 14,
                    max: 40,
                    divisions: 26,
                    onChanged: saving
                        ? null
                        : (value) => setState(() => fontSize = value.round()),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Подложка под текстом'),
                    value: background,
                    onChanged: saving
                        ? null
                        : (value) => setState(() => background = value!),
                  ),
                  const Text(
                    'ASS сохраняет собственное оформление; графические субтитры не меняют шрифт. Расшифровка и второй перевод доступны для SRT/WebVTT.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('video-import-subtitles'),
                    onPressed: saving ? null : _import,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Добавить файл субтитров'),
                  ),
                  const Text(
                    'Добавление сразу включает выбранный файл. Текст сохраняется вместе с уроком.',
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: saving ? null : _save,
            child: Text(saving ? 'Сохранение…' : 'Применить'),
          ),
        ],
      ),
    );
  }
}

class _SubtitleImportDialog extends StatefulWidget {
  final VideoCaptionsController captions;
  final VideoSubtitleFile file;
  const _SubtitleImportDialog({required this.captions, required this.file});
  @override
  State<_SubtitleImportDialog> createState() => _SubtitleImportDialogState();
}

class _SubtitleImportDialogState extends State<_SubtitleImportDialog> {
  late final name = TextEditingController(text: widget.file.name);
  VideoSubtitleEncoding encoding = VideoSubtitleEncoding.automatic;
  bool translation = false, busy = false;
  String? error;
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.captions.importFile(
        VideoSubtitleFile(name.text.trim(), widget.file.bytes),
        encoding,
        translation: translation,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    String preview;
    try {
      final text = decodeVideoSubtitles(widget.file.bytes, encoding: encoding);
      preview = text.substring(0, text.length.clamp(0, 600));
    } catch (e) {
      preview = '$e';
    }
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Добавить субтитры'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    key: const ValueKey('video-subtitle-name'),
                    controller: name,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'Название с расширением',
                    ),
                    validator: (value) =>
                        value == null ||
                            value.trim().isEmpty ||
                            value.trim().runes.length > 200
                        ? 'От 1 до 200 знаков'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<VideoSubtitleEncoding>(
                    initialValue: encoding,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Кодировка'),
                    items: [
                      for (final (value, label) in const [
                        (
                          VideoSubtitleEncoding.automatic,
                          'Автоматически (UTF-8 / BOM)',
                        ),
                        (VideoSubtitleEncoding.utf8, 'UTF-8'),
                        (VideoSubtitleEncoding.utf16le, 'UTF-16 LE'),
                        (VideoSubtitleEncoding.utf16be, 'UTF-16 BE'),
                        (VideoSubtitleEncoding.windows1251, 'Windows-1251'),
                        (VideoSubtitleEncoding.windows1252, 'Windows-1252'),
                      ])
                        DropdownMenuItem(value: value, child: Text(label)),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() => encoding = value!),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Использовать как перевод'),
                    value: translation,
                    onChanged: busy
                        ? null
                        : (value) => setState(() => translation = value!),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(preview, style: const TextStyle(fontSize: 13)),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: busy ? null : _save,
            child: Text(busy ? 'Проверка…' : 'Добавить'),
          ),
        ],
      ),
    );
  }
}
