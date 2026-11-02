import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/shared/file_icons/file_thumbnail.dart';
import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

import 'entity_meta.dart';
import 'file_list_item.dart' show SelectionCheck;

/// One file or folder in the explorer's grid and gallery views.
///
/// Grid tiles show the file icon, a two-line name and the size (files) or
/// date (folders). Gallery tiles fill the top with a thumbnail for images.
class FileGridItem extends StatelessWidget {
  const FileGridItem({
    super.key,
    required this.entity,
    required this.displayName,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onTap,
    required this.onLongPress,
    this.onSecondaryTapUp,
    this.gallery = false,
    this.zoom = 1,
  });

  /// Tile size, 1 the usual (see ExplorerZoom).
  final double zoom;

  final FileSystemEntity entity;
  final String displayName;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  /// Right-click, with where it happened (for a context menu).
  final GestureTapUpCallback? onSecondaryTapUp;
  final bool gallery;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(12);
    final title = displayName.isEmpty ? entity.path : displayName;

    return Material(
      color: isSelected ? colors.accent : colors.card,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: isSelected ? colors.ring : colors.border,
          width: isSelected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTapUp: onSecondaryTapUp,
        child: Stack(
          children: [
            Positioned.fill(
              child: gallery ? _gallery(context, title) : _grid(context, title),
            ),
            if (isSelectionMode)
              Positioned(
                top: 8,
                right: 8,
                child: SelectionCheck(selected: isSelected),
              ),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, String title) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      child: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final room = constraints.biggest.shortestSide;
                // The icon grows with the room it has: the name below stays
                // the same height, so that room grows faster than the zoom.
                final icon = Center(
                  child: EntityIcon(
                    entity: entity,
                    size: math.min(room, math.max(44 * zoom, room * 0.65)),
                  ),
                );
                if (entity is! File) return icon;
                return Center(
                  child: FileThumbnail(path: entity.path, size: room.clamp(32.0, 1200.0), fallback: icon),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 34,
            child: Center(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  fontSize: 12.5,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? context.colors.accentForeground
                      : context.colors.foreground,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          _Meta(entity: entity, center: true),
        ],
      ),
    );
  }

  Widget _gallery(BuildContext context, String title) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ColoredBox(
                color: colors.muted,
                child: _Thumbnail(entity: entity),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: isSelected
                      ? colors.accentForeground
                      : colors.foreground,
                ),
              ),
              const SizedBox(height: 1),
              _Meta(entity: entity),
            ],
          ),
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.entity, this.center = false});

  final FileSystemEntity entity;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11);
    return EntityStatBuilder(
      entity: entity,
      builder: (context, stat) => Text(
        stat == null
            ? ' '
            : entity is Directory
                ? EntityFormat.date(stat.modified)
                : EntityFormat.size(stat.size),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: style,
      ),
    );
  }
}

/// Image thumbnail (decoded at tile size), or the file icon for other types.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.entity});

  final FileSystemEntity entity;

  @override
  Widget build(BuildContext context) {
    final isVideo = FileTypes.kindOf(entity.path) == FileKind.video;
    return LayoutBuilder(
      builder: (context, constraints) {
        // In proportion to the tile: 56 at the usual size.
        final icon = Center(
          child: EntityIcon(entity: entity, size: (constraints.biggest.shortestSide * 0.35).clamp(24.0, 400.0)),
        );
        if (entity is Directory) return icon;
        return Stack(
          fit: StackFit.expand,
          children: [
            FileThumbnail(
              path: entity.path,
              size: constraints.biggest.longestSide.isFinite ? constraints.biggest.longestSide : 200,
              cover: true,
              radius: 0,
              fallback: icon,
            ),
            if (isVideo) Positioned(left: 6, bottom: 6, child: _Badge(LucideIcons.play)),
          ],
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        border: Border.all(color: colors.border),
      ),
      child: Icon(icon, size: 11, color: colors.foreground),
    );
  }
}
