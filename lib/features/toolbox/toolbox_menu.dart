import 'package:folders/core/services/app_shortcuts.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/toolbox/duplicate_finder_screen.dart';
import 'package:folders/features/toolbox/memory_cleaner_screen.dart';
import 'package:folders/features/toolbox/music_player_screen.dart';
import 'package:folders/features/toolbox/ram_cleaner_screen.dart';
import 'package:folders/features/video_player/video_library_screen.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What the Toolbox holds.
enum Tool {
  ramCleaner('ram_cleaner', LucideIcons.memoryStick, 'RAM cleaner', 'See memory in use, and free what the system allows'),
  memoryCleaner('memory_cleaner', LucideIcons.eraser, 'Memory cleaner', 'Remove temporary files, caches and other junk'),
  duplicateFinder('duplicate_finder', LucideIcons.copy, 'Duplicate finder', 'Find files with the same contents, and clean them up'),
  videoPlayer('video_player', LucideIcons.film, 'Video player', 'All the videos on this device'),
  musicPlayer('music_player', LucideIcons.music, 'Music player', 'All your music, one song after another');

  const Tool(this.id, this.icon, this.title, this.description);

  static const _routePrefix = 'tool/';

  final String id;
  final IconData icon;
  final String title;
  final String description;

  /// The tool a shortcut's route asks for.
  static Tool? fromRoute(String route) {
    for (final tool in values) {
      if (route == '$_routePrefix${tool.id}') return tool;
    }
    return null;
  }

  AppShortcut get shortcut => AppShortcut(
        id: 'tool_$id',
        title: title,
        description: description,
        icon: icon,
        route: '$_routePrefix$id',
      );

  Widget get screen => switch (this) {
        ramCleaner => const RamCleanerScreen(),
        memoryCleaner => const MemoryCleanerScreen(),
        duplicateFinder => const DuplicateFinderScreen(),
        videoPlayer => const VideoLibraryScreen(),
        musicPlayer => const MusicPlayerScreen(),
      };
}

/// The sidebar's Toolbox: a menu over the page, closed by a tap outside it or
/// Esc. A tool opens from it; the pin, a right-click or a long press on a tool
/// adds a shortcut to it.
Future<void> showToolboxMenu(BuildContext context) {
  // Over the whole window, but tools open in the tab it was called from.
  final navigator = Navigator.of(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: AppGlass.isOn(context) ? 0.15 : 0.35),
    // At once: a blur can't fade in with the rest of the menu.
    transitionDuration: Duration.zero,
    pageBuilder: (menu, _, _) => ToolboxMenu(
      onOpen: (tool) {
        Navigator.pop(menu);
        navigator.push(MaterialPageRoute(builder: (_) => tool.screen));
      },
    ),
  );
}

class ToolboxMenu extends StatelessWidget {
  const ToolboxMenu({super.key, required this.onOpen});

  final ValueChanged<Tool> onOpen;

  static const _radius = 16.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Row(
            children: [
              Icon(LucideIcons.wrench, size: 16, color: colors.mutedForeground),
              const SizedBox(width: 8),
              Text('Toolbox', style: text.titleSmall),
            ],
          ),
        ),
        Flexible(
          child: GridView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisExtent: 104,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: Tool.values.length,
            itemBuilder: (_, index) => _ToolTile(
              tool: Tool.values[index],
              autofocus: index == 0,
              onOpen: onOpen,
            ),
          ),
        ),
      ],
    );
    final theme = Theme.of(context);
    final solid = theme.dialogTheme.backgroundColor ?? colors.popover;
    final radius = BorderRadius.circular(_radius);
    final panel = AppGlass.isLiquid(context, listen: true)
        ? LiquidGlass(tint: solid, borderRadius: radius, opacity: 0.72, child: Material(type: MaterialType.transparency, child: content))
        : DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(borderRadius: radius, border: Border.all(color: colors.border)),
            child: ClipRRect(borderRadius: radius, child: GlassSurface(color: solid, child: content)),
          );
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 480, maxHeight: size.height),
            child: panel,
          ),
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool, required this.autofocus, required this.onOpen});

  final Tool tool;
  final bool autofocus;
  final ValueChanged<Tool> onOpen;

  /// The places this system has for a shortcut, then there it goes.
  Future<void> _addShortcut(BuildContext context, Offset at) async {
    final inAppDrawer = await AppShortcuts.isInAppDrawer(tool.shortcut);
    if (!context.mounted) return;
    final place = await ExplorerMenu.showAt<ShortcutPlace>(
      context,
      at,
      items: [
        for (final place in AppShortcuts.places)
          ExplorerMenu.item<ShortcutPlace>(
            context,
            value: place,
            label: place == ShortcutPlace.appDrawer && inAppDrawer ? 'Remove from the app drawer' : _placeLabel(place),
            icon: _placeIcon(place),
          ),
      ],
    );
    if (place == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (place == ShortcutPlace.appDrawer && inAppDrawer) {
      final removed = await AppShortcuts.setInAppDrawer(tool.shortcut, false);
      HapticFeedback.lightImpact();
      messenger?.showSnackBar(SnackBar(
        content: Text(removed ? '${tool.title} removed from the app drawer' : "Couldn't remove ${tool.title} from the app drawer"),
      ));
      return;
    }
    final colors = AppTheme.gradientOf(context.colors.primary);
    var added = false;
    try {
      added = await AppShortcuts.add(tool.shortcut, place, colors: colors);
    } on Exception {
      // Said below.
    }
    // The launcher asks about a home screen one, and says what became of it.
    if (added && place == ShortcutPlace.homeScreen) return;
    HapticFeedback.lightImpact();
    messenger?.showSnackBar(SnackBar(
      content: Text(added ? '${tool.title} added to ${_placeName(place)}' : "Couldn't add the shortcut to ${_placeName(place)}"),
    ));
  }

  static String _placeLabel(ShortcutPlace place) => switch (place) {
        ShortcutPlace.appDrawer => 'Add to the app drawer',
        ShortcutPlace.homeScreen => 'Add to home screen',
        ShortcutPlace.appIconMenu => "Add to the app icon's menu",
        ShortcutPlace.desktop => 'Add to desktop',
        ShortcutPlace.startMenu => 'Add to Start menu',
        ShortcutPlace.appMenu => 'Add to app menu',
        ShortcutPlace.applications => 'Add to Applications',
      };

  static String _placeName(ShortcutPlace place) => switch (place) {
        ShortcutPlace.appDrawer => 'the app drawer',
        ShortcutPlace.homeScreen => 'the home screen',
        ShortcutPlace.appIconMenu => "the app icon's menu",
        ShortcutPlace.desktop => 'the desktop',
        ShortcutPlace.startMenu => 'the Start menu',
        ShortcutPlace.appMenu => 'the app menu',
        ShortcutPlace.applications => 'Applications',
      };

  static IconData _placeIcon(ShortcutPlace place) => switch (place) {
        ShortcutPlace.homeScreen => LucideIcons.house,
        ShortcutPlace.appIconMenu => LucideIcons.smartphone,
        ShortcutPlace.desktop => LucideIcons.monitor,
        ShortcutPlace.appDrawer ||
        ShortcutPlace.startMenu ||
        ShortcutPlace.appMenu ||
        ShortcutPlace.applications =>
          LucideIcons.layoutGrid,
      };

  /// Where a menu opens from a widget without a pointer: under its centre.
  static Offset _centerOf(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Tooltip(
      message: tool.description,
      waitDuration: const Duration(milliseconds: 600),
      child: Stack(
        children: [
          Positioned.fill(
            child: Builder(
              builder: (tile) => InkWell(
                autofocus: autofocus,
                borderRadius: BorderRadius.circular(12),
                onTap: () => onOpen(tool),
                onLongPress: () => _addShortcut(tile, _centerOf(tile)),
                onSecondaryTapUp: (details) => _addShortcut(tile, details.globalPosition),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
                  child: Column(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SizedBox.square(dimension: 44, child: Icon(tool.icon, size: 22, color: colors.primary)),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tool.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: colors.foreground, height: 1.2),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: ExcludeFocus(
              child: Builder(
                builder: (pin) => IconButton(
                  tooltip: 'Add shortcut',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  color: colors.mutedForeground,
                  icon: const Icon(LucideIcons.pin),
                  onPressed: () => _addShortcut(pin, _centerOf(pin)),
                ),
              ),
            ),
          ),
        ],
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
