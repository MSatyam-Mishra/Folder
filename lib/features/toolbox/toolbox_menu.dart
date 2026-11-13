import 'dart:io';

import 'package:folders/core/build_features.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/app_shortcuts.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/localsend/screens/localsend_screen.dart';
import 'package:folders/features/network/screens/file_server_screen.dart';
import 'package:folders/features/network/wifi_sharing.dart';
import 'package:folders/features/document_scanner/document_scanner_screen.dart';
import 'package:folders/features/toolbox/duplicate_finder_screen.dart';
import 'package:folders/features/toolbox/junk_cleaner_screen.dart';
import 'package:folders/features/toolbox/music_player_screen.dart';
import 'package:folders/features/toolbox/ram_cleaner_screen.dart';
import 'package:folders/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:folders/features/video_player/video_library_screen.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What the Toolbox holds. An id names the tool's route (`tool/<id>`), its
/// shortcuts and its entry in Android's manifest, so it never changes: the
/// Junk cleaner keeps the id it had as the Memory cleaner.
enum Tool {
  ramCleaner('ram_cleaner', LucideIcons.memoryStick, 'RAM cleaner', 'See memory in use, and free what the system allows'),
  junkCleaner('memory_cleaner', LucideIcons.eraser, 'Junk cleaner', 'Remove temporary files, caches and other junk'),
  duplicateFinder('duplicate_finder', LucideIcons.copy, 'Duplicate finder', 'Find files with the same contents, and clean them up'),
  documentScanner('document_scanner', LucideIcons.scanLine, 'Document scanner', 'Scan pages to a PDF or pictures with the camera'),
  videoPlayer('video_player', LucideIcons.film, 'Video player', 'All the videos on this device'),
  musicPlayer('music_player', LucideIcons.music, 'Music player', 'All your music, one song after another'),
  videoDownloader('video_downloader', LucideIcons.cloudDownload, 'Video downloader', 'Save videos and their sound from a link'),
  wifiSharing('wifi_sharing', LucideIcons.wifi, 'Wi-Fi sharing', 'Open your files from a browser (HTTP) or FTP'),
  nearbyShare('nearby_share', LucideIcons.radio, 'Nearby share', 'Send and receive with LocalSend');

  const Tool(this.id, this.icon, this.title, this.description);

  static const _routePrefix = 'tool/';

  final String id;
  final IconData icon;
  final String title;
  final String description;

  /// The tools this build has: the video downloader only where it's built in,
  /// the document scanner (Google's, from Play services) only on Android.
  static List<Tool> get available => availableIn(videoDownloader: kVideoDownloaderEnabled, android: Platform.isAndroid);

  @visibleForTesting
  static List<Tool> availableIn({required bool videoDownloader, bool android = false}) => [
        for (final tool in values)
          if ((tool != Tool.videoDownloader || videoDownloader) && (tool != Tool.documentScanner || android)) tool,
      ];

  /// The tool a shortcut's route asks for, if this build has it.
  static Tool? fromRoute(String route, {@visibleForTesting bool videoDownloader = kVideoDownloaderEnabled, @visibleForTesting bool? android}) {
    for (final tool in availableIn(videoDownloader: videoDownloader, android: android ?? Platform.isAndroid)) {
      if (route == tool.route) return tool;
    }
    return null;
  }

  String get route => '$_routePrefix$id';

  /// Whether [route] is a tool's, whether or not this build has the tool.
  static bool isRoute(String route) => route.startsWith(_routePrefix);

  AppShortcut get shortcut => AppShortcut(
        id: 'tool_$id',
        title: title,
        description: description,
        icon: icon,
        route: route,
      );

  /// The tool's screen, as a shortcut opens it. Wi-Fi sharing starts at the
  /// user's own folder there; from the Toolbox see [open].
  Widget get screen => switch (this) {
        ramCleaner => const RamCleanerScreen(),
        junkCleaner => const JunkCleanerScreen(),
        duplicateFinder => const DuplicateFinderScreen(),
        documentScanner => const DocumentScannerScreen(),
        videoPlayer => const VideoLibraryScreen(),
        musicPlayer => const MusicPlayerScreen(),
        // A build without the downloader never offers it, nor compiles it in.
        videoDownloader => kVideoDownloaderEnabled ? const VideoDownloaderScreen() : const SizedBox.shrink(),
        wifiSharing => FileServerScreen(initialFolder: ExplorerPaths.userFolder),
        nearbyShare => const LocalSendScreen(),
      };

  /// Opens the tool on [navigator]. Wi-Fi sharing starts at the folder
  /// [explorer] shows, as from the drawer.
  Future<void> open(NavigatorState navigator, {FileExplorerBloc? explorer}) => switch (this) {
        wifiSharing => openWifiSharing(navigator, explorer: explorer),
        _ => navigator.push(MaterialPageRoute<void>(builder: (_) => screen)),
      };
}

/// The sidebar's Toolbox: a menu over the page, closed by a tap outside it or
/// Esc. A tool opens from it; the pin, a right-click or a long press on a tool
/// adds a shortcut to it.
Future<void> showToolboxMenu(BuildContext context) {
  // Over the whole window, but tools open in the tab it was called from.
  final navigator = Navigator.of(context);
  // Read now: on a phone the drawer this comes from closes meanwhile.
  FileExplorerBloc? explorer;
  try {
    explorer = context.read<FileExplorerBloc>();
  } on ProviderNotFoundException {
    explorer = null;
  }
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
        tool.open(navigator, explorer: explorer);
      },
    ),
  );
}

class ToolboxMenu extends StatelessWidget {
  const ToolboxMenu({super.key, required this.onOpen, @visibleForTesting this.tools});

  final ValueChanged<Tool> onOpen;

  /// In place of [Tool.available], for tests.
  final List<Tool>? tools;

  static const _radius = 16.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final tools = this.tools ?? Tool.available;
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
            itemCount: tools.length,
            itemBuilder: (_, index) => _ToolTile(
              tool: tools[index],
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
