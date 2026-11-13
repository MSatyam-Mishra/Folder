import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/social_files.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:folders/core/app_licenses.dart';
import 'package:folders/core/build_features.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/platform/windows_locations.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:folders/core/services/directory_services.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/features/category_view/bloc/bloc/screens/category_viewer_screen.dart';
import 'package:folders/features/category_view/file_category_screen.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/localsend/screens/localsend_screen.dart';
import 'package:folders/features/network/wifi_sharing.dart';
import 'package:folders/features/sidebar/bloc/bloc/sidebar_bloc.dart';
import 'package:folders/features/tags/tags_sidebar.dart';
import 'package:folders/features/tools/screens/app_manager_screen.dart';
import 'package:folders/features/tools/screens/usb_boot_screen.dart';
import 'package:folders/features/vault/screens/vault_screen.dart';
import 'package:folders/features/vault/vault_store.dart';
import 'package:folders/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:folders/shared/widgets/storage_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Closes the navigation drawer if [context] is inside an open one. When the
/// menu is docked as a side pane (tablets, foldables) this does nothing.
void dismissDrawer(BuildContext context) {
  final scaffold = Scaffold.maybeOf(context);
  if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
}

/// Modal navigation drawer for phones.
class MainDrawer extends StatelessWidget {
  const MainDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppSidebar(child: MainDrawerContent());
  }
}

/// Storage, category and tool navigation; shown in [MainDrawer] on phones and
/// as a docked side pane on wide screens.
class MainDrawerContent extends StatelessWidget {
  const MainDrawerContent({super.key, this.padding});

  /// Padding around the list; defaults to none (the drawer adds safe area).
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return CompactText(child: Column(
      children: [
        const _SidebarHeader(),
        Divider(height: 1, color: context.colors.border),
        Expanded(
          child: ListView(
            padding: (padding ?? EdgeInsets.zero).add(
              const EdgeInsets.only(bottom: 16),
            ),
            children: [
              const AppSidebarSection('Storage'),
              if (Platform.isWindows)
                const _WindowsStorageSection()
              else if (Platform.isLinux || Platform.isMacOS)
                const _UnixStorageSection()
              else
                BlocBuilder<SidebarBloc, SidebarState>(
                  builder: (context, state) => Column(
                    children: [
                      const StorageDrawerItem(
                        icon: LucideIcons.smartphone,
                        title: 'Internal storage',
                        path: ExplorerPaths.androidInternalStorage,
                      ),
                      if (state is SidebarLoaded)
                        for (final volume in state.externalStorage)
                          StorageDrawerItem(
                            icon: LucideIcons.hardDrive,
                            title: 'External (${p.basename(volume.path)})',
                            path: volume.path,
                          ),
                    ],
                  ),
                ),
              const AppSidebarSection('Categories'),
              BlocBuilder<SidebarBloc, SidebarState>(
                builder: (context, state) {
                  if (state is! SidebarLoaded) return const SizedBox.shrink();
                  return Column(
                    children: [
                      for (final category in state.categories)
                        if ((category.name != 'Apps' || Platform.isAndroid) &&
                            (category.name != 'Vault' || VaultStore.supported))
                          AppSidebarItem(
                            icon: _categoryIcon(category.name) ?? category.icon,
                            label: category.name,
                            trailing: category.fileCount > 0
                                ? Text('${category.fileCount}')
                                : null,
                            onTap: () => _openCategory(context, category.name),
                          ),
                    ],
                  );
                },
              ),
              const AppSidebarSection('Social'),
              for (final app in SocialApp.values)
                AppSidebarItem(
                  icon: app.icon,
                  label: app.label,
                  onTap: () {
                    dismissDrawer(context);
                    context.read<FileExplorerBloc>().add(LoadDirectory(ExplorerPaths.socialPath(app.id)));
                  },
                ),
              const TagsSidebarSection(),
              const AppSidebarSection('Tools'),
              AppSidebarItem(
                icon: LucideIcons.wrench,
                label: 'Toolbox',
                detail: 'Cleaners, players and sharing',
                onTap: () {
                  dismissDrawer(context);
                  showToolboxMenu(context);
                },
              ),
              AppSidebarItem(
                icon: LucideIcons.radio,
                label: 'Nearby share',
                detail: 'Send and receive with LocalSend',
                onTap: () => _push(context, const LocalSendScreen()),
              ),
              AppSidebarItem(
                icon: LucideIcons.wifi,
                label: 'Wi-Fi sharing',
                detail: 'Browser (HTTP) or FTP',
                onTap: () => _openFileServer(context),
              ),
              if (kVideoDownloaderEnabled)
                AppSidebarItem(
                  icon: LucideIcons.cloudDownload,
                  label: 'Video downloader',
                  onTap: () => _push(context, const VideoDownloaderScreen()),
                ),
              // Writing disk images needs Android's USB host access (or root).
              if (Platform.isAndroid)
                AppSidebarItem(
                  icon: LucideIcons.usb,
                  label: 'USB boot',
                  onTap: () => _push(context, const UsbBootScreen()),
                ),
              AppSidebarItem(
                icon: LucideIcons.info,
                label: 'About and licences',
                onTap: () {
                  dismissDrawer(context);
                  showLicensePage(
                    context: context,
                    applicationName: 'Folders',
                    applicationLegalese: appLegalese,
                  );
                },
              ),
            ],
          ),
        ),
      ],
    ));
  }

  static IconData? _categoryIcon(String name) => switch (name) {
    'Photos' => LucideIcons.image,
    'Video' => LucideIcons.clapperboard,
    'Audio' => LucideIcons.music,
    'Documents' => LucideIcons.fileText,
    'Vault' => LucideIcons.lock,
    'Archives' => LucideIcons.archive,
    'Downloads' => LucideIcons.download,
    'Apps' => LucideIcons.layoutGrid,
    _ => null,
  };

  static void _push(BuildContext context, Widget screen) {
    dismissDrawer(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
  }

  static Future<void> _openCategory(BuildContext context, String name) async {
    dismissDrawer(context);
    // On computers: a folder holding its files, in the browser.
    if (ExplorerPaths.categoryIsFolder(name)) {
      context.read<FileExplorerBloc>().add(LoadDirectory(ExplorerPaths.categoryPath(name)));
      return;
    }
    final type = switch (name) {
      'Photos' => RequestType.image,
      'Video' => RequestType.video,
      'Audio' => RequestType.audio,
      _ => null,
    };
    if (type != null) {
      _push(context, CategoryViewerScreen(categoryType: type, title: name));
      return;
    }
    final explorer = context.read<FileExplorerBloc>();
    void showFolder(String folder) => explorer.add(LoadDirectory(folder));
    switch (name) {
      case 'Documents':
        _push(
          context,
          FileCategoryScreen(
            group: DeviceFileGroup.documents,
            onShowInFolder: showFolder,
          ),
        );
      case 'Archives':
        _push(
          context,
          FileCategoryScreen(
            group: DeviceFileGroup.archives,
            onShowInFolder: showFolder,
          ),
        );
      case 'Downloads':
        final downloads = await DirectoryService.findDownloadsDirectory();
        if (!context.mounted) return;
        if (downloads == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No Downloads folder on this device')),
          );
          return;
        }
        showFolder(downloads.path);
      case 'Apps':
        _push(context, const AppManagerScreen());
      case 'Vault':
        _push(context, const VaultScreen());
    }
  }

  static Future<void> _openFileServer(BuildContext context) {
    dismissDrawer(context);
    return openWifiSharing(
      Navigator.of(context),
      explorer: context.read<FileExplorerBloc>(),
    );
  }
}

/// App mark and name, with a theme switch (System → Light → Dark).
class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final mode = context.select((ThemeCubit c) => c.state.themeMode);
    final (icon, label, next) = switch (mode) {
      ThemeMode.system => (
        LucideIcons.monitor,
        'System theme',
        ThemeMode.light,
      ),
      ThemeMode.light => (LucideIcons.sun, 'Light theme', ThemeMode.dark),
      ThemeMode.dark => (LucideIcons.moon, 'Dark theme', ThemeMode.system),
    };
    // 56 px like the page header, so their bottom borders line up when the
    // sidebar is docked next to the page.
    return Container(
      height: 56,
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              LucideIcons.folderOpen,
              size: 17,
              color: colors.primaryForeground,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Folders', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                // One line, however narrow the sidebar is made.
                Text(
                  'Files, viewers and tools',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          AppIconButton(
            icon: Icon(icon, size: 17),
            tooltip: '$label · tap to change',
            onPressed: () => context.read<ThemeCubit>().setThemeMode(next),
          ),
        ],
      ),
    );
  }
}

/// Whether a /Volumes entry on macOS is a drive to list: hidden and system
/// entries (.timemachine, com.apple.TimeMachine.localsnapshots) aren't.
@visibleForTesting
bool isListedMacVolume(String name) =>
    !name.startsWith('.') && !name.startsWith('com.apple.');

/// Linux and macOS: the home folder, the whole file system and mounted
/// drives (USB sticks, other disks).
class _UnixStorageSection extends StatefulWidget {
  const _UnixStorageSection();

  @override
  State<_UnixStorageSection> createState() => _UnixStorageSectionState();
}

class _UnixStorageSectionState extends State<_UnixStorageSection> {
  late List<Directory> _volumes = _findVolumes();

  /// macOS: lists /Volumes again when a drive or disk image is mounted or
  /// ejected.
  StreamSubscription<FileSystemEvent>? _volumeWatch;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST')) {
      _volumeWatch = Directory('/Volumes').watch().listen(
        (_) {
          if (mounted) setState(() => _volumes = _findVolumes());
        },
        onError: (Object e) => debugPrint('Volumes watch failed: $e'),
      );
    }
  }

  @override
  void dispose() {
    _volumeWatch?.cancel();
    super.dispose();
  }

  static List<Directory> _findVolumes() {
    final user = Platform.environment['USER'];
    final parents = Platform.isMacOS
        ? const ['/Volumes']
        : [if (user != null) ...['/media/$user', '/run/media/$user'], '/mnt'];
    final found = <Directory>[];
    for (final parent in parents) {
      try {
        for (final entity in Directory(parent).listSync(followLinks: false)) {
          if (entity is Directory &&
              (!Platform.isMacOS ||
                  isListedMacVolume(p.basename(entity.path)))) {
            found.add(entity);
          }
        }
      } on FileSystemException {
        // Missing or unreadable.
      }
    }
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final home = Platform.environment['HOME'];
    return Column(
      children: [
        if (home != null)
          StorageDrawerItem(icon: LucideIcons.house, title: 'Home', path: home),
        const StorageDrawerItem(
          icon: LucideIcons.hardDrive,
          title: 'File system',
          path: '/',
        ),
        for (final volume in _volumes)
          StorageDrawerItem(
            icon: LucideIcons.usb,
            title: p.basename(volume.path),
            path: volume.path,
          ),
      ],
    );
  }
}

class _WindowsStorageSection extends StatelessWidget {
  const _WindowsStorageSection();

  static IconData _libraryIcon(String name) => switch (name.toLowerCase()) {
    'desktop' => LucideIcons.monitor,
    'documents' => LucideIcons.fileText,
    'downloads' => LucideIcons.download,
    'music' => LucideIcons.music,
    'pictures' => LucideIcons.image,
    'videos' => LucideIcons.clapperboard,
    _ => LucideIcons.folder,
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WindowsStorageLocation>>(
      future: WindowsLocations.listAll(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final drives = snapshot.data!
            .where((e) => e.kind == WindowsStorageKind.drive)
            .toList();
        final libraries = snapshot.data!
            .where((e) => e.kind == WindowsStorageKind.library)
            .toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final d in drives)
              StorageDrawerItem(
                icon: LucideIcons.hardDrive,
                title: d.displayName,
                path: d.path,
              ),
            if (libraries.isNotEmpty) ...[
              const AppSidebarSection('Libraries'),
              const StorageDrawerItem(
                icon: LucideIcons.monitor,
                title: 'This PC',
                path: ExplorerPaths.windowsRoots,
              ),
              for (final lib in libraries)
                StorageDrawerItem(
                  icon: _libraryIcon(lib.displayName),
                  title: lib.displayName,
                  path: lib.path,
                ),
            ],
          ],
        );
      },
    );
  }
}
