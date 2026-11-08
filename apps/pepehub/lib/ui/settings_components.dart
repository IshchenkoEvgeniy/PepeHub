import 'package:flutter/material.dart';

import 'shelf_components.dart';

class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  const SettingsGroup({super.key, required this.children});
  @override
  Widget build(BuildContext context) {
    final colors = ShelfPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Material(
        color: colors.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: colors.line),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsLink extends StatelessWidget {
  final String title;
  final String? subtitle, value;
  final IconData icon;
  final VoidCallback? onTap;
  final bool enabled;
  const SettingsLink({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.value,
    this.onTap,
    this.enabled = true,
  });
  @override
  Widget build(BuildContext context) {
    final colors = ShelfPalette.of(context);
    // A link without an action is shown as unavailable, not as a dead row.
    final enabled = this.enabled && onTap != null;
    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: enabled ? colors.selected : colors.raised,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          icon,
          size: 20,
          color: enabled ? colors.accent : Theme.of(context).disabledColor,
        ),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null && value == null
          ? null
          : Text(
              [?subtitle, ?value].join(' · '),
              style: TextStyle(color: colors.muted),
            ),
      trailing: !enabled ? null : const Icon(Icons.chevron_right, size: 20),
      onTap: enabled ? onTap : null,
    );
  }
}

class SettingsHeading extends StatelessWidget {
  final String title, subtitle;
  const SettingsHeading(this.title, this.subtitle, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: ShelfPalette.of(context).muted),
          ),
        ],
      ],
    ),
  );
}

class SettingsNotice extends StatelessWidget {
  final String text;
  const SettingsNotice(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ShelfPalette.of(context).selected,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(text),
    ),
  );
}

/// Small caption between groups inside one section.
class SettingsSubheading extends StatelessWidget {
  final String text;
  const SettingsSubheading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 0, 10),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: ShelfPalette.of(context).muted,
        letterSpacing: .8,
      ),
    ),
  );
}

/// «Reset to defaults» with a confirmation, placed at the end of a section.
class SettingsResetButton extends StatelessWidget {
  final String what;
  final Future<void> Function() onReset;
  final bool enabled;
  const SettingsResetButton({
    super.key,
    required this.what,
    required this.onReset,
    this.enabled = true,
  });
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      key: ValueKey('settings-reset:$what'),
      onPressed: !enabled
          ? null
          : () async {
              final accepted = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Сбросить настройки?'),
                  content: Text(
                    'Будут восстановлены значения по умолчанию: $what. Книги, история и заметки не изменятся.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Отмена'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Сбросить'),
                    ),
                  ],
                ),
              );
              if (accepted == true) await onReset();
            },
      icon: const Icon(Icons.restart_alt, size: 20),
      label: const Text('Сбросить к значениям по умолчанию'),
    ),
  );
}

/// A setting chosen from a short list. The list sits at the end of the row on
/// wide layouts and moves under the title when space is short.
class SettingsDropdownTile<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final T? value;
  final List<T> items;
  final String Function(T) label;
  final ValueChanged<T>? onChanged;
  const SettingsDropdownTile({
    super.key,
    required this.title,
    required this.value,
    required this.items,
    required this.label,
    required this.onChanged,
    this.subtitle,
  });
  @override
  Widget build(BuildContext context) {
    final muted = ShelfPalette.of(context).muted;
    Widget dropdown(bool expanded) => value == null
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : DropdownButton<T>(
            value: value,
            isExpanded: expanded,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(14),
            items: [
              for (final item in items)
                DropdownMenuItem(value: item, child: Text(label(item))),
            ],
            onChanged: onChanged == null
                ? null
                : (next) {
                    if (next != null) onChanged!(next);
                  },
          );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.bodyLarge),
        if (subtitle != null)
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: muted),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, size) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final stacked = size.maxWidth < 360 + 120 * (scale - 1).clamp(0, 2);
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 10, stacked ? 16 : 12, 10),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [text, dropdown(true)],
                )
              : Row(
                  children: [
                    Expanded(child: text),
                    const SizedBox(width: 12),
                    dropdown(false),
                  ],
                ),
        );
      },
    );
  }
}
