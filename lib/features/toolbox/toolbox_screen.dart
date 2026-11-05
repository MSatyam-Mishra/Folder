import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/features/category_view/bloc/bloc/screens/category_viewer_screen.dart';
import 'package:explorer/features/toolbox/duplicate_finder_screen.dart';
import 'package:explorer/features/toolbox/memory_cleaner_screen.dart';
import 'package:explorer/features/toolbox/music_player_screen.dart';
import 'package:explorer/features/toolbox/ram_cleaner_screen.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The sidebar's Toolbox: cleaners and players.
class ToolboxScreen extends StatelessWidget {
  const ToolboxScreen({super.key, required this.showFolder});

  /// Shows a folder in the browser, closing the Toolbox.
  final ValueChanged<String> showFolder;

  void _openVideos(BuildContext context) {
    // Where the browser shows videos as a folder, that's the library.
    if (ExplorerPaths.categoryIsFolder('Video')) {
      Navigator.pop(context);
      showFolder(ExplorerPaths.categoryPath('Video'));
      return;
    }
    _push(context, const CategoryViewerScreen(categoryType: RequestType.video, title: 'Video player'));
  }

  static void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    return ExplorerScaffold(
      title: 'Toolbox',
      body: ListView(
        padding: EdgeInsets.fromLTRB(12, top + 12, 12, MediaQuery.paddingOf(context).bottom + 16),
        children: [
          _Tool(
            icon: LucideIcons.memoryStick,
            title: 'RAM cleaner',
            subtitle: 'See memory in use, and free what the system allows',
            onTap: () => _push(context, const RamCleanerScreen()),
          ),
          _Tool(
            icon: LucideIcons.eraser,
            title: 'Memory cleaner',
            subtitle: 'Remove temporary files, caches and other junk',
            onTap: () => _push(context, const MemoryCleanerScreen()),
          ),
          _Tool(
            icon: LucideIcons.copy,
            title: 'Duplicate finder',
            subtitle: 'Find files with the same contents, and clean them up',
            onTap: () => _push(context, const DuplicateFinderScreen()),
          ),
          _Tool(
            icon: LucideIcons.film,
            title: 'Video player',
            subtitle: 'All the videos on this device',
            onTap: () => _openVideos(context),
          ),
          _Tool(
            icon: LucideIcons.music,
            title: 'Music player',
            subtitle: 'All your music, one song after another',
            onTap: () => _push(context, const MusicPlayerScreen()),
          ),
        ],
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool({required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox.square(dimension: 44, child: Icon(icon, size: 22, color: colors.primary)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleSmall),
                  const SizedBox(height: 2),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks before deleting for good; shared by the cleaners.
Future<bool> confirmToolboxDelete(BuildContext context, {required String title, required String message}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) {
      final colors = dialog.colors;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}
