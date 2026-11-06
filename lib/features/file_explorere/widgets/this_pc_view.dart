import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/platform/windows_locations.dart';
import 'package:folders/core/services/thumbnails/system_icons.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/shared/file_icons/place_icon.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// This PC, as in File Explorer: the libraries, then the drives with how
/// full they are.
List<Widget> thisPcSlivers({
  required List<FileSystemEntity> entities,
  required String Function(FileSystemEntity) labelOf,
  required bool Function(FileSystemEntity) isSelected,
  required double top,
  required double zoom,
  required void Function(FileSystemEntity) onTap,
  required GestureTapUpCallback? Function(FileSystemEntity) onSecondaryTap,
  required Widget Function(FileSystemEntity, Widget) wrap,
}) {
  final drives = [for (final e in entities) if (ExplorerPaths.isDriveRoot(e.path)) e];
  final libraries = [for (final e in entities) if (!ExplorerPaths.isDriveRoot(e.path)) e];

  Widget section(String title) => SliverToBoxAdapter(
        child: Builder(
          builder: (context) => Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
      );

  Widget grid(List<FileSystemEntity> items, {required double extent, required double height, required bool drive}) =>
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: extent * zoom,
            mainAxisExtent: height + 40 * (zoom - 1),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final entity = items[index];
              return wrap(
                entity,
                _Tile(
                  entity: entity,
                  label: labelOf(entity),
                  drive: drive,
                  selected: isSelected(entity),
                  iconSize: (drive ? 44 : 36) * zoom,
                  onTap: () => onTap(entity),
                  onSecondaryTapUp: onSecondaryTap(entity),
                ),
              );
            },
            childCount: items.length,
          ),
        ),
      );

  return [
    SliverToBoxAdapter(child: SizedBox(height: top)),
    if (libraries.isNotEmpty) ...[
      section('Libraries'),
      grid(libraries, extent: 250, height: 60, drive: false),
    ],
    if (drives.isNotEmpty) ...[
      section('Devices and drives'),
      grid(drives, extent: 330, height: 76, drive: true),
    ],
  ];
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.entity,
    required this.label,
    required this.drive,
    required this.selected,
    required this.iconSize,
    required this.onTap,
    this.onSecondaryTapUp,
  });

  final FileSystemEntity entity;
  final String label;
  final bool drive;
  final bool selected;
  final double iconSize;
  final VoidCallback onTap;
  final GestureTapUpCallback? onSecondaryTapUp;

  /// A drive looks like a drive. Windows' own icons in every style, but
  /// for Sweet's and Dracula's library folders.
  Widget _icon(BuildContext context) {
    final folder = EntityIcon(entity: entity, size: iconSize);
    if (!drive && context.look.iconPack != null) return folder;
    final fallback = drive ? Icon(LucideIcons.hardDrive, size: iconSize * 0.8) : folder;
    if (!SystemIcons.supported) return SizedBox.square(dimension: iconSize, child: Center(child: fallback));
    return SystemIcon(path: entity.path, size: iconSize, fallback: fallback);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final radius = BorderRadius.circular(10);
    return Material(
      color: selected ? colors.accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: selected ? colors.ring : colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: onSecondaryTapUp,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              _icon(context),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: selected ? colors.accentForeground : colors.foreground,
                      ),
                    ),
                    if (drive) _DriveSpace(root: entity.path),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How full a drive is: a bar (red when nearly full, as in File Explorer)
/// and what's free.
class _DriveSpace extends StatefulWidget {
  const _DriveSpace({required this.root});

  final String root;

  @override
  State<_DriveSpace> createState() => _DriveSpaceState();
}

class _DriveSpaceState extends State<_DriveSpace> {
  late Future<DriveSpace?> _space = WindowsLocations.spaceOf(widget.root);

  @override
  void didUpdateWidget(_DriveSpace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root != widget.root) _space = WindowsLocations.spaceOf(widget.root);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<DriveSpace?>(
      future: _space,
      builder: (context, snapshot) {
        final space = snapshot.data;
        if (space == null || space.total <= 0) return const SizedBox.shrink();
        final used = (space.total - space.free) / space.total;
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: used.clamp(0.0, 1.0),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                backgroundColor: colors.foreground.withValues(alpha: 0.1),
                color: used >= 0.9 ? const Color(0xFFDA3B01) : colors.primary,
              ),
              const SizedBox(height: 4),
              Text(
                '${EntityFormat.size(space.free)} free of ${EntityFormat.size(space.total)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
