import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/audio_mini_player.dart';
import 'error_log.dart';

/// Shows the rotating error log so problems on a phone can be copied out.
class ErrorLogPage extends StatefulWidget {
  const ErrorLogPage({super.key});
  @override
  State<ErrorLogPage> createState() => _ErrorLogPageState();
}

class _ErrorLogPageState extends State<ErrorLogPage> {
  String? text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value = await ErrorLog.read();
    if (mounted) setState(() => text = value);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: text ?? ''));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Журнал скопирован')));
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить журнал ошибок?'),
        content: const Text('Записи об ошибках будут удалены с устройства.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ErrorLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final value = text;
    final empty = value != null && value.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал ошибок'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Скопировать',
            onPressed: value == null || empty ? null : _copy,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Очистить',
            onPressed: value == null || empty ? null : _clear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      bottomNavigationBar: const AudioPlayerFooter(),
      body: value == null
          ? const Center(child: CircularProgressIndicator())
          : empty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('Ошибок не записано.', textAlign: TextAlign.center),
              ),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    // Very long text makes selection slow; copy keeps it all.
                    value.length > 200000
                        ? '… показаны последние записи, «Скопировать» '
                              'забирает журнал целиком …\n'
                              '${value.substring(value.length - 200000)}'
                        : value,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
