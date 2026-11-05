import 'dart:io';

import 'package:folder/shared/file_icons/file_thumbnail.dart';
import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

import 'entity_meta.dart';
import 'selection_band.dart';

/// How a [FileListItem] lays out its details.
enum FileRowStyle {
  /// 60 px: icon, name and a "size · date" line.
  comfortable,

  /// 40 px: small icon, name and the size on the right.
  compact,

  /// Wide screens: name, modified, type and size in columns that line up
  /// with [FileTableHeader].
  table,
}

/// One file or folder in the explorer's list views.
class FileListItem extends StatelessWidget {
  final FileSystemEntity entity;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// In place of the name, while it's being edited.
  final Widget? nameEditor;

  /// A double tap on the picture: a quick look at the file.
  final VoidCallback? onPeek;
  final String? displayName;
  final FileRowStyle style;

  /// Where it is, for search results from subfolders ("Reports/2025").
  final String? location;

  /// Right click / two-finger tap (desktop, trackpads).
  /// Right-click, with where it happened (for a context menu).
  final GestureTapUpCallback? onSecondaryTapUp;

  const FileListItem({
    super.key,
    required this.entity,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    this.nameEditor,
    this.onPeek,
    this.displayName,
    this.style = FileRowStyle.comfortable,
    this.location,
    this.onSecondaryTapUp,
    this.zoom = 1,
  });

  /// Icon (or thumbnail) size, 1 the usual (see ExplorerZoom).
  final double zoom;

  static double _iconFor(FileRowStyle style) => switch (style) {
        FileRowStyle.comfortable => 40,
        FileRowStyle.compact => 24,
        FileRowStyle.table => 28,
      };

  /// A row's height: the usual one, plus what a bigger icon needs.
  static double heightFor(FileRowStyle style, [double zoom = 1]) =>
      switch (style) {
        FileRowStyle.comfortable => 60.0,
        FileRowStyle.compact => 40.0,
        FileRowStyle.table => 48.0,
      } +
      _iconFor(style) * (zoom - 1);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rawTitle = displayName ?? p.basename(entity.path);
    final title = rawTitle.isEmpty ? entity.path : rawTitle;
    final radius = BorderRadius.circular(8);

    final iconSize = _iconFor(style) * zoom;

    final picture = MetaData(
      metaData: itemDragPart,
      behavior: HitTestBehavior.opaque,
      child: entity is File
          ? FileThumbnail(
              path: entity.path,
              size: iconSize,
              fallback: EntityIcon(entity: entity, size: iconSize),
            )
          : EntityIcon(entity: entity, size: iconSize),
    );
    final row = Row(
      children: [
        onPeek == null
            ? picture
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                onDoubleTap: onPeek,
                child: picture,
              ),
        SizedBox(width: style == FileRowStyle.compact ? 10 : 12),
        Expanded(child: _details(context, title)),
        if (isSelectionMode) ...[
          const SizedBox(width: 12),
          SelectionCheck(selected: isSelected),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: MetaData(
        // A selected row is grabbed anywhere; others by the icon and name,
        // and the rest of the row starts a selection band.
        metaData: isSelected ? itemDragPart : null,
        child: Material(
          color: isSelected ? colors.accent : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            onLongPress: onLongPress,
            onSecondaryTapUp: onSecondaryTapUp,
            child: SizedBox(
              height: heightFor(style, zoom),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: style == FileRowStyle.compact ? 10 : 12,
                ),
                child: row,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _details(BuildContext context, String title) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final nameStyle = text.bodyMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: isSelected ? colors.accentForeground : colors.foreground,
    );
    // On a selected row the details follow the name, as in Finder (where
    // the selection is a strong blue).
    final detail = isSelected ? colors.accentForeground.withValues(alpha: 0.8) : colors.mutedForeground;
    final detailStyle = text.bodySmall?.copyWith(color: detail);
    final where = location;
    final label = MetaData(
      metaData: itemDragPart,
      behavior: HitTestBehavior.opaque,
      child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
    );
    final Widget name = nameEditor ?? (where == null || style == FileRowStyle.comfortable
        ? Align(alignment: Alignment.centerLeft, heightFactor: 1, child: label)
        : Row(
            children: [
              Flexible(child: label),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'in $where',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: detailStyle,
                ),
              ),
            ],
          ));

    switch (style) {
      case FileRowStyle.comfortable:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            name,
            const SizedBox(height: 2),
            EntityStatBuilder(
              entity: entity,
              builder: (context, stat) => Text(
                [
                  if (where != null) 'in $where',
                  if (stat != null) EntityFormat.summary(entity, stat),
                ].join(' · ').ifEmpty(' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: detailStyle,
              ),
            ),
          ],
        );
      case FileRowStyle.compact:
        return Row(
          children: [
            Expanded(child: name),
            if (entity is File)
              EntityStatBuilder(
                entity: entity,
                builder: (context, stat) => stat == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Text(
                          EntityFormat.size(stat.size),
                          style: detailStyle,
                        ),
                      ),
              ),
          ],
        );
      case FileRowStyle.table:
        final cell = text.bodySmall?.copyWith(
          fontSize: 13,
          color: detail,
        );
        return Row(
          children: [
            Expanded(child: name),
            EntityStatBuilder(
              entity: entity,
              builder: (context, stat) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Cell(
                    width: FileTableHeader.modifiedWidth,
                    child: Text(
                      stat == null ? '' : EntityFormat.date(stat.modified),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: cell,
                    ),
                  ),
                  _Cell(
                    width: FileTableHeader.typeWidth,
                    child: Text(
                      EntityFormat.kind(entity),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: cell,
                    ),
                  ),
                  _Cell(
                    width: FileTableHeader.sizeWidth,
                    alignEnd: true,
                    child: Text(
                      stat == null || entity is Directory
                          ? '—'
                          : EntityFormat.size(stat.size),
                      maxLines: 1,
                      style: cell,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.width, required this.child, this.alignEnd = false});

  final double width;
  final Widget child;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Align(
          alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
  }
}

/// Column headings above [FileRowStyle.table] rows; tapping one sorts by it
/// (tapping the active column again flips the order).
class FileTableHeader extends StatelessWidget {
  const FileTableHeader({
    super.key,
    required this.sortOption,
    required this.sortOrder,
    required this.onSort,
    this.showSelectionColumn = false,
  });

  static const double modifiedWidth = 184;
  static const double typeWidth = 148;
  static const double sizeWidth = 96;

  final SortOption sortOption;
  final SortOrder sortOrder;
  final void Function(SortOption option, SortOrder order) onSort;
  final bool showSelectionColumn;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget heading(String label, SortOption option, {bool alignEnd = false}) {
      final active = sortOption == option;
      final ascending = sortOrder == SortOrder.ascending;
      return _HeaderButton(
        label: label,
        active: active,
        ascending: ascending,
        alignEnd: alignEnd,
        onTap: () => onSort(
          option,
          active && ascending ? SortOrder.descending : SortOrder.ascending,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: SizedBox(
          height: 40,
          child: Padding(
            // Lines up with the rows: 12 padding + 28 icon + 12 gap, minus
            // the headings' own 8 px padding.
            padding: const EdgeInsets.only(left: 52 - 8, right: 12),
            child: Row(
              children: [
                Expanded(child: heading('Name', SortOption.name)),
                SizedBox(
                  width: modifiedWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: heading('Modified', SortOption.date),
                  ),
                ),
                SizedBox(
                  width: typeWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: heading('Type', SortOption.type),
                  ),
                ),
                SizedBox(
                  width: sizeWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: heading('Size', SortOption.size, alignEnd: true),
                  ),
                ),
                if (showSelectionColumn) const SizedBox(width: 12 + 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.label,
    required this.active,
    required this.ascending,
    required this.onTap,
    this.alignEnd = false,
  });

  final String label;
  final bool active;
  final bool ascending;
  final bool alignEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: active ? colors.foreground : colors.mutedForeground,
        );
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.fromLTRB(8, 6, alignEnd ? 0 : 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: style),
              const SizedBox(width: 4),
              Icon(
                active
                    ? (ascending ? LucideIcons.arrowUp : LucideIcons.arrowDown)
                    : LucideIcons.chevronsUpDown,
                size: 12,
                color: active
                    ? colors.foreground
                    : colors.mutedForeground.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// shadcn-style checkbox drawn in rows and tiles while selecting; taps go
/// to the row.
class SelectionCheck extends StatelessWidget {
  const SelectionCheck({super.key, required this.selected, this.size = 18});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected ? colors.primary : colors.background,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: selected ? colors.primary : colors.mutedForeground,
          width: 1.25,
        ),
      ),
      child: selected
          ? Icon(
              LucideIcons.check,
              size: size - 5,
              color: colors.primaryForeground,
            )
          : null,
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
