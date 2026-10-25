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
  const SettingsLink({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.value,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final colors = ShelfPalette.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: colors.selected,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: colors.accent),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: subtitle == null && value == null
          ? null
          : Text(
              [?subtitle, ?value].join(' · '),
              style: TextStyle(color: colors.muted),
            ),
      trailing: onTap == null
          ? null
          : const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
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
