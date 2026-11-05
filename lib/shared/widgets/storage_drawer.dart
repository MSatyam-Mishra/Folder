import 'package:folder/core/theme/app_style.dart';
import 'package:folder/shared/file_icons/place_icon.dart';
import 'package:folder/shared/widgets/main_drawer.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:filesize/filesize.dart';
import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class StorageDrawerItem extends StatefulWidget {
  final IconData icon;
  final String title;
  final String path;

  const StorageDrawerItem({
    super.key,
    required this.icon,
    required this.title,
    required this.path,
  });

  @override
  State<StorageDrawerItem> createState() => _StorageDrawerItemState();
}

class _StorageDrawerItemState extends State<StorageDrawerItem> {
  double? _totalSpace;
  double? _usedSpace;
  DiskSpacePlus diskSpacePlus = DiskSpacePlus();

  @override
  void initState() {
    super.initState();
    _getDiskSpace();
  }

  Future<void> _getDiskSpace() async {
    // Attempt to get space for specific path
    double? total;
    double? free;

    if (widget.path == ExplorerPaths.androidInternalStorage) {
      try {
        total = await diskSpacePlus.getTotalDiskSpace;
        free = await diskSpacePlus.getFreeDiskSpace;
      } catch (e) {
        // debugPrint(e.toString());
      }
    } else {
      // For external storage paths, plugins vary.
      // We'll leave it simple for now and rely on Internal only showing space
      // unless we find a plugin that reliably takes paths.
      // disk_space_plus usually only returns for internal.
    }

    if (mounted) {
      if (total != null && free != null) {
        setState(() {
          _totalSpace = total;
          _usedSpace = total! - free!;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final total = _totalSpace;
    final used = _usedSpace;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          dismissDrawer(context);
          context.read<FileExplorerBloc>().add(LoadDirectory(widget.path));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              PlaceIcon(
                place: Place.named(widget.title) ?? Place.of(widget.path),
                path: widget.path,
                icon: widget.icon,
                size: 17,
                color: context.look.sidebarIcons ?? context.look.iconColor(widget.icon, colors.foreground),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    if (total != null && used != null && total > 0) ...[
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: used / total,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${filesize(((total - used) * 1024 * 1024).toInt())} '
                        'free of ${filesize((total * 1024 * 1024).toInt())}',
                        style: text.bodySmall,
                      ),
                    ],
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
