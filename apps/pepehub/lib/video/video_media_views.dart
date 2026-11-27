import 'package:flutter/material.dart';

import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_thumbnails.dart';

/// Looks of the media list and of a course, saved between launches.
const videoViewLabels = {
  'list': 'Список',
  'compact': 'Компактно',
  'grid': 'Плитка',
  'cards': 'Крупные карточки',
};

const videoViewIcons = {
  'list': Icons.view_list_outlined,
  'compact': Icons.view_headline,
  'grid': Icons.grid_view,
  'cards': Icons.view_agenda_outlined,
};

/// One video, course or file in any of the [videoViewLabels] looks.
class VideoMediaTile extends StatelessWidget {
  final String view;
  final String title, subtitle;
  final VideoLesson? cover;
  final IconData icon;

  /// Over the frame: duration or the number of files.
  final String? badge;

  /// Shown instead of a frame (music).
  final bool frame;

  /// Null outside selection mode.
  final bool? selected;
  final bool dimmed;
  final VoidCallback? onTap, onLongPress;
  final Widget? trailing;
  final VideoThumbnails? thumbnails;
  const VideoMediaTile({
    super.key,
    required this.view,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.icon,
    this.badge,
    this.frame = true,
    this.selected,
    this.dimmed = false,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.thumbnails,
  });

  Widget _thumb(BuildContext context, double? width, {double radius = 8}) {
    final palette = ShelfPalette.of(context);
    if (!frame) {
      final icon = Icon(this.icon, color: palette.accent);
      if (selected == null) return icon;
      return Icon(
        selected! ? Icons.check_circle : Icons.radio_button_unchecked,
        color: palette.accent,
      );
    }
    return VideoThumbnail(
      lesson: cover,
      thumbnails: thumbnails,
      width: width,
      icon: icon,
      label: badge,
      checked: selected,
      radius: radius,
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 400;
    final highlighted = selected == true;
    Widget panel(
      Widget child, {
      EdgeInsets margin = const EdgeInsets.only(top: 10),
    }) => Padding(
      padding: margin,
      child: Material(
        color: highlighted ? palette.selected : palette.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: highlighted
              ? BorderSide(color: palette.accent, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: Opacity(opacity: dimmed ? 0.55 : 1, child: child),
      ),
    );
    final titleText = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall,
    );
    final subtitleText = Text(
      subtitle,
      maxLines: view == 'list' ? 3 : 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(color: palette.muted),
    );
    switch (view) {
      case 'compact':
        return panel(
          margin: const EdgeInsets.only(top: 4),
          InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
              child: Row(
                children: [
                  _thumb(context, 64, radius: 6),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        subtitleText,
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        );
      case 'grid':
        return panel(
          margin: EdgeInsets.zero,
          InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _thumb(context, null, radius: 0),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 0, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(child: titleText),
                              subtitleText,
                            ],
                          ),
                        ),
                        ?trailing,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      case 'cards':
        return panel(
          InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _thumb(context, null, radius: 0),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [titleText, subtitleText],
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      default:
        return panel(
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            leading: _thumb(context, narrow ? 80 : 112),
            title: titleText,
            subtitle: subtitleText,
            trailing: trailing,
            onTap: onTap,
            onLongPress: onLongPress,
          ),
        );
    }
  }
}

/// Slivers for rows of media: consecutive tiles share a grid in the
/// «Плитка» look, everything else (headers, playlists) is a list. Rows are
/// built lazily either way.
List<Widget> videoMediaSlivers({
  required List<Object> rows,
  required String view,
  required bool Function(Object row) isTile,
  required Widget Function(BuildContext context, Object row) build,
  EdgeInsets padding = const EdgeInsets.fromLTRB(16, 0, 16, 16),
}) {
  final slivers = <Widget>[];
  var start = 0;
  while (start < rows.length) {
    final tile = view == 'grid' && isTile(rows[start]);
    var end = start + 1;
    while (end < rows.length && (view == 'grid' && isTile(rows[end])) == tile) {
      end++;
    }
    final run = rows.sublist(start, end);
    final last = end == rows.length;
    final inner = EdgeInsets.fromLTRB(
      padding.left,
      tile ? 10 : 0,
      padding.right,
      last ? padding.bottom : 0,
    );
    slivers.add(
      SliverPadding(
        padding: inner,
        sliver: tile
            ? SliverLayoutBuilder(
                builder: (context, constraints) {
                  const spacing = 10.0, maxWidth = 230.0;
                  final width = constraints.crossAxisExtent;
                  final columns = (width / maxWidth).ceil().clamp(2, 8);
                  final tileWidth = (width - spacing * (columns - 1)) / columns;
                  final text = MediaQuery.textScalerOf(context).scale(1);
                  return SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: spacing,
                      crossAxisSpacing: spacing,
                      mainAxisExtent: tileWidth * 9 / 16 + 66 * text,
                    ),
                    itemCount: run.length,
                    itemBuilder: (context, i) => build(context, run[i]),
                  );
                },
              )
            : SliverList.builder(
                itemCount: run.length,
                itemBuilder: (context, i) => build(context, run[i]),
              ),
      ),
    );
    start = end;
  }
  return slivers;
}

/// Bar of the selection mode: count, select all and the actions.
class VideoSelectionBar extends StatelessWidget {
  final int count, total;
  final VoidCallback onClose, onSelectAll;
  final List<Widget> actions;
  const VideoSelectionBar({
    super.key,
    required this.count,
    required this.total,
    required this.onClose,
    required this.onSelectAll,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Material(
      color: palette.selected,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Снять выделение',
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
              Expanded(
                child: Text(
                  'Выбрано: $count',
                  key: const ValueKey('selection-count'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: count == total ? 'Снять все' : 'Выбрать все',
                onPressed: onSelectAll,
                icon: Icon(count == total ? Icons.deselect : Icons.select_all),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// Popup for choosing the look; [icon] shows the current one.
class VideoViewButton extends StatelessWidget {
  final String view;
  final ValueChanged<String> onSelected;
  const VideoViewButton({
    super.key,
    required this.view,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('media-view'),
    tooltip: 'Вид: ${videoViewLabels[view]}',
    icon: Icon(videoViewIcons[view]),
    initialValue: view,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final entry in videoViewLabels.entries)
        CheckedPopupMenuItem(
          value: entry.key,
          checked: entry.key == view,
          child: Text(entry.value),
        ),
    ],
  );
}
