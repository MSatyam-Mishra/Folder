import 'package:folders/core/formats/archive_backend.dart';
import 'package:folders/core/formats/archive_index.dart';
import 'package:folders/features/viewer_archive/archive_ui_utils.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:flutter/material.dart';

const double kArchiveRowHeight = 64;

/// One row of the archive listing: a folder or a file.
class ArchiveEntryTile extends StatelessWidget {
  const ArchiveEntryTile.folder({
    super.key,
    required ArcFolder this.folder,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    this.showPath = false,
  }) : entry = null;

  const ArchiveEntryTile.file({
    super.key,
    required ArcEntry this.entry,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    this.showPath = false,
  }) : folder = null;

  final ArcFolder? folder;
  final ArcEntry? entry;
  final bool selected;
  final bool selecting;
  final bool showPath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final f = folder;
    final e = entry;
    final name = f?.name ?? e!.name;
    final parent = _parentOf(f?.path ?? e!.path);

    String subtitle;
    if (f != null) {
      final items = f.folders.length + f.files.length;
      subtitle = '$items ${items == 1 ? 'item' : 'items'}'
          ' · ${formatBytes(f.totalSize)}';
      final date = formatDate(f.modified);
      if (date.isNotEmpty) subtitle += ' · $date';
    } else {
      final parts = <String>[];
      if (e!.isSymlink) {
        parts.add(e.linkTarget == null ? 'Link' : 'Link → ${e.linkTarget}');
      } else {
        parts.add(
          e.sizeIsExact || e.size < 0
              ? formatBytes(e.size)
              : '≈ ${formatBytes(e.size)}',
        );
        final ratio = ratioLabel(e.size, e.packedSize);
        if (ratio != null && e.size > 0) parts.add('packed $ratio');
      }
      final date = formatDate(e.modified);
      if (date.isNotEmpty) parts.add(date);
      subtitle = parts.join(' · ');
    }
    if (showPath && parent.isNotEmpty) subtitle = '$parent  ·  $subtitle';

    final badges = <Widget>[
      if (e != null && e.isEncrypted || (f?.anyEncrypted ?? false))
        Tooltip(
          message: 'Encrypted',
          child: Icon(LucideIcons.lock, size: 14, color: colors.mutedForeground),
        ),
      if (e?.unsupportedReason != null)
        Tooltip(
          message: e!.unsupportedReason!,
          child: Icon(LucideIcons.ban, size: 14, color: colors.destructive),
        ),
      if (e != null && e.unsafePath)
        Tooltip(
          message: 'Stored with an unsafe path; it will be extracted inside '
              'the destination folder.',
          child: Icon(
            LucideIcons.triangleAlert,
            size: 14,
            color: context.toneColor(Tone.warning),
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                f != null
                    ? const FolderIcon(size: 40)
                    : FileIcon(path: name, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          for (final b in badges) ...[
                            const SizedBox(width: 6),
                            b,
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (selecting)
                  Checkbox(value: selected, onChanged: (_) => onTap())
                else if (f != null)
                  Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: colors.mutedForeground,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }
}

/// Placeholder rows shown while the archive is being listed.
class ArchiveSkeleton extends StatefulWidget {
  const ArchiveSkeleton({super.key, this.rows = 9});
  final int rows;

  @override
  State<ArchiveSkeleton> createState() => _ArchiveSkeletonState();
}

class _ArchiveSkeletonState extends State<ArchiveSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = context.colors.muted;
    return FadeTransition(
      opacity: Tween(begin: 0.5, end: 1.0).animate(_pulse),
      child: Column(
        children: [
          for (var i = 0; i < widget.rows; i++)
            SizedBox(
              height: kArchiveRowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    _bar(base, 40, 40, 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          FractionallySizedBox(
                            widthFactor: 0.4 + (i * 37 % 40) / 100,
                            child: _bar(base, null, 12, 6),
                          ),
                          const SizedBox(height: 8),
                          FractionallySizedBox(
                            widthFactor: 0.3 + (i * 23 % 25) / 100,
                            child: _bar(base, null, 10, 5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bar(Color base, double? w, double h, double r) => Container(
    width: w,
    height: h,
    decoration: BoxDecoration(
      color: base,
      borderRadius: BorderRadius.circular(r),
    ),
  );
}
