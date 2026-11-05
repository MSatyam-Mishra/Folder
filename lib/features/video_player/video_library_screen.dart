import 'dart:async';
import 'dart:io';

import 'package:explorer/core/services/device_files.dart';
import 'package:explorer/features/file_explorere/widgets/entity_meta.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_menu.dart';
import 'package:explorer/features/localsend/screens/localsend_screen.dart';
import 'package:explorer/features/toolbox/music_player_screen.dart';
import 'package:explorer/features/vault/screens/vault_screen.dart';
import 'package:explorer/features/video_player/play_queue.dart';
import 'package:explorer/features/video_player/video_library.dart';
import 'package:explorer/features/video_player/video_player_page.dart';
import 'package:explorer/features/video_player/video_player_settings.dart';
import 'package:explorer/shared/file_icons/file_thumbnail.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

/// The Toolbox's video player: every folder holding videos, what's new in each
/// and what was played last, with a way to the other players and to streams.
class VideoLibraryScreen extends StatefulWidget {
  const VideoLibraryScreen({super.key});

  @override
  State<VideoLibraryScreen> createState() => _VideoLibraryScreenState();
}

class _VideoLibraryScreenState extends State<VideoLibraryScreen> {
  static const _gridKey = 'video_library_grid';

  final _history = VideoHistory.instance;
  List<DeviceFile>? _videos;
  var _grid = false;
  var _searching = false;
  var _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    await _history.load();
    await VideoPlaylists.instance.load();
    final videos = await VideoLibrary.find();
    if (!mounted) return;
    setState(() {
      _grid = prefs.getBool(_gridKey) ?? false;
      _videos = videos;
    });
  }

  Future<void> _setGrid(bool grid) async {
    setState(() => _grid = grid);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_gridKey, grid);
  }

  void _push(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  /// The round button: on with what played last, or else the newest video.
  void _playLast() {
    final videos = _videos ?? const <DeviceFile>[];
    final last = _history.lastPlayed;
    if (last != null && (VideoHistory.isStream(last) || File(last).existsSync())) {
      final folder = [
        for (final video in videos)
          if (p.dirname(video.path) == p.dirname(last)) video.path,
      ];
      if (VideoHistory.isStream(last) || !folder.contains(last)) {
        unawaited(VideoPlayerPage.open(context, [last]));
      } else {
        unawaited(VideoPlayerPage.open(context, folder, index: folder.indexOf(last)));
      }
    } else if (videos.isNotEmpty) {
      unawaited(VideoPlayerPage.open(context, [videos.first.path]));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No videos yet')));
    }
  }

  Widget _chips() {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _Chip(icon: LucideIcons.radioTower, label: 'Network stream', onTap: () => unawaited(showNetworkStream(context))),
          _Chip(icon: LucideIcons.listVideo, label: 'Playlists', onTap: () => _push(const VideoPlaylistsScreen())),
          _Chip(icon: LucideIcons.history, label: 'Recent', onTap: () => _push(const _RecentVideosScreen())),
          _Chip(icon: LucideIcons.music, label: 'Music', onTap: () => _push(const MusicPlayerScreen())),
          _Chip(icon: LucideIcons.shieldCheck, label: 'Privacy', onTap: () => _push(const VaultScreen())),
          _Chip(icon: LucideIcons.radio, label: 'Nearby share', onTap: () => _push(const LocalSendScreen())),
        ],
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      autofocus: true,
      decoration: const InputDecoration(hintText: 'Search videos', border: InputBorder.none, isDense: true),
      onChanged: (query) => setState(() => _query = query.trim().toLowerCase()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    return ExplorerScaffold(
      title: 'Folders',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _searching ? 'Close search' : 'Search',
            icon: Icon(_searching ? LucideIcons.x : LucideIcons.search, size: 20),
            onPressed: () => setState(() {
              _searching = !_searching;
              _query = '';
            }),
          ),
          IconButton(
            tooltip: _grid ? 'List' : 'Grid',
            icon: Icon(_grid ? LucideIcons.layoutList : LucideIcons.layoutGrid, size: 20),
            onPressed: () => unawaited(_setGrid(!_grid)),
          ),
          IconButton(
            tooltip: 'Player settings',
            icon: const Icon(LucideIcons.settings2, size: 20),
            onPressed: () => unawaited(showPlayerDefaults(context)),
          ),
        ],
      ),
      floatingActionButton: AppFab(tooltip: 'Play', icon: LucideIcons.play, onPressed: _playLast),
      body: ListenableBuilder(
        listenable: _history,
        builder: (context, _) {
          final videos = _videos;
          if (videos == null) return const Center(child: CircularProgressIndicator());
          final bottom = MediaQuery.paddingOf(context).bottom + 96;
          final found = _query.isEmpty
              ? null
              : [
                  for (final video in videos)
                    if (p.basename(video.path).toLowerCase().contains(_query)) video,
                ];
          return RefreshIndicator(
            edgeOffset: top,
            onRefresh: _load,
            child: CustomScrollView(
              slivers: [
                SliverPadding(padding: EdgeInsets.only(top: top)),
                if (_searching)
                  SliverToBoxAdapter(
                    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: _searchField()),
                  )
                else
                  SliverToBoxAdapter(child: _chips()),
                if (found != null)
                  SliverList.builder(
                    itemCount: found.length,
                    itemBuilder: (_, index) => VideoRow(
                      video: found[index],
                      onTap: () => unawaited(VideoPlayerPage.open(context, [found[index].path])),
                    ),
                  )
                else if (videos.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: ExplorerEmptyState(
                      icon: LucideIcons.film,
                      title: 'No videos yet',
                      description: 'Videos on this device show up here, by folder.',
                    ),
                  )
                else
                  _folders(VideoLibrary.foldersOf(videos)),
                SliverPadding(padding: EdgeInsets.only(bottom: bottom)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _folders(List<VideoFolder> folders) {
    void open(VideoFolder folder) => _push(VideoListScreen(title: folder.name, videos: folder.videos));
    if (!_grid) {
      return SliverList.builder(
        itemCount: folders.length,
        itemBuilder: (_, index) => _FolderRow(folder: folders[index], onTap: () => open(folders[index])),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 132, mainAxisExtent: 128),
        itemCount: folders.length,
        itemBuilder: (_, index) => _FolderTile(folder: folders[index], onTap: () => open(folders[index])),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: colors.muted,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: colors.primary),
                const SizedBox(width: 6),
                Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.foreground)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A folder's icon with how many of its videos haven't been played.
class _FolderIcon extends StatelessWidget {
  const _FolderIcon({required this.folder, required this.size});

  final VideoFolder folder;
  final double size;

  @override
  Widget build(BuildContext context) {
    final history = VideoHistory.instance;
    final colors = context.colors;
    final unplayed = folder.videos.where(history.isUnplayed).length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        EntityIcon(entity: Directory(folder.path), size: size),
        if (unplayed > 0)
          Positioned(
            top: -2,
            right: -4,
            child: DecoratedBox(
              decoration: BoxDecoration(color: colors.destructive, borderRadius: BorderRadius.circular(9)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      '$unplayed',
                      style: TextStyle(color: colors.destructiveForeground, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _countOf(int videos) => videos == 1 ? '1 video' : '$videos videos';

class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.folder, required this.onTap});

  final VideoFolder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final last = VideoHistory.instance.lastFolder == folder.path;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _FolderIcon(folder: folder, size: 52),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(color: last ? context.colors.primary : null),
                  ),
                  const SizedBox(height: 2),
                  Text(_countOf(folder.videos.length), style: text.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({required this.folder, required this.onTap});

  final VideoFolder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final last = VideoHistory.instance.lastFolder == folder.path;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            _FolderIcon(folder: folder, size: 64),
            const SizedBox(height: 6),
            Text(
              folder.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(color: last ? context.colors.primary : null),
            ),
            Text(_countOf(folder.videos.length), style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// One video: its picture with how far it's been watched, whether it's new,
/// and what it is.
class VideoRow extends StatelessWidget {
  const VideoRow({super.key, required this.video, required this.onTap, this.onRemove});

  final DeviceFile video;
  final VoidCallback onTap;

  /// Takes it out of the list it's shown in.
  final VoidCallback? onRemove;

  Future<void> _menu(BuildContext context, Offset at) async {
    final choice = await ExplorerMenu.showAt<String>(
      context,
      at,
      items: [
        ExplorerMenu.item<String>(context, value: 'playlist', label: 'Add to a playlist', icon: LucideIcons.listPlus),
        if (onRemove != null)
          ExplorerMenu.item<String>(context, value: 'remove', label: 'Remove from this list', icon: LucideIcons.listX),
      ],
    );
    if (!context.mounted) return;
    if (choice == 'playlist') unawaited(showAddToPlaylist(context, video.path));
    if (choice == 'remove') onRemove?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final history = VideoHistory.instance;
    final progress = history.progressOf(video.path);
    const width = 112.0;
    const height = 63.0;
    return InkWell(
      onTap: onTap,
      onLongPress: () {
        final box = context.findRenderObject()! as RenderBox;
        unawaited(_menu(context, box.localToGlobal(box.size.center(Offset.zero))));
      },
      onSecondaryTapUp: (details) => unawaited(_menu(context, details.globalPosition)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: colors.muted),
                    FileThumbnail(
                      path: video.path,
                      size: width,
                      cover: true,
                      radius: 0,
                      fallback: Center(child: Icon(LucideIcons.film, size: 22, color: colors.mutedForeground)),
                    ),
                    if (progress != null && progress.duration > Duration.zero) ...[
                      Positioned(
                        right: 4,
                        bottom: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Text(
                              formatVideoTime(progress.duration),
                              style: const TextStyle(color: Colors.white, fontSize: 10),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: progress.fraction,
                          minHeight: 3,
                          color: colors.primary,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.basename(video.path), maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (history.isUnplayed(video)) ...[
                        DecoratedBox(
                          decoration: BoxDecoration(color: colors.destructive, borderRadius: BorderRadius.circular(3)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              'NEW',
                              style: TextStyle(color: colors.destructiveForeground, fontSize: 10, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          '${EntityFormat.size(video.size)} · ${p.basename(p.dirname(video.path))}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of videos, played one after the other from the one tapped.
class VideoListScreen extends StatelessWidget {
  const VideoListScreen({super.key, required this.title, required this.videos, this.onRemove});

  final String title;
  final List<DeviceFile> videos;
  final void Function(DeviceFile)? onRemove;

  @override
  Widget build(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    return ExplorerScaffold(
      title: title,
      body: ListenableBuilder(
        listenable: VideoHistory.instance,
        builder: (context, _) {
          if (videos.isEmpty) {
            return const ExplorerEmptyState(
              icon: LucideIcons.film,
              title: 'Nothing here yet',
              description: 'Touch and hold a video, or right-click it, to add it to a playlist.',
            );
          }
          final paths = [for (final video in videos) video.path];
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(0, top + 8, 0, MediaQuery.paddingOf(context).bottom + 16),
            itemCount: videos.length,
            itemBuilder: (_, index) => VideoRow(
              video: videos[index],
              onTap: () => unawaited(VideoPlayerPage.open(context, paths, index: index)),
              onRemove: onRemove == null ? null : () => onRemove!(videos[index]),
            ),
          );
        },
      ),
    );
  }
}

/// What was played lately, newest first.
class _RecentVideosScreen extends StatelessWidget {
  const _RecentVideosScreen();

  @override
  Widget build(BuildContext context) => VideoListScreen(
        title: 'Recent',
        videos: filesAt(VideoHistory.instance.recent),
      );
}

/// Those of [paths] that still exist.
List<DeviceFile> filesAt(Iterable<String> paths) {
  final files = <DeviceFile>[];
  for (final path in paths) {
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.file) files.add(DeviceFile(path, stat.size, stat.modified));
  }
  return files;
}

class VideoPlaylistsScreen extends StatelessWidget {
  const VideoPlaylistsScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final name = await askPlaylistName(context);
    if (name != null) await VideoPlaylists.instance.create(name);
  }

  @override
  Widget build(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final lists = VideoPlaylists.instance;
    return ExplorerScaffold(
      title: 'Playlists',
      floatingActionButton: AppFab(
        tooltip: 'New playlist',
        icon: LucideIcons.listPlus,
        onPressed: () => unawaited(_create(context)),
      ),
      body: ListenableBuilder(
        listenable: lists,
        builder: (context, _) {
          final names = lists.names;
          if (names.isEmpty) {
            return const ExplorerEmptyState(
              icon: LucideIcons.listVideo,
              title: 'No playlists yet',
              description: 'Make one here, then touch and hold a video, or right-click it, to add it.',
            );
          }
          return ListView(
            padding: EdgeInsets.only(top: top + 8),
            children: [
              for (final name in names)
                ListTile(
                  leading: const Icon(LucideIcons.listVideo),
                  title: Text(name),
                  subtitle: Text(_countOf(lists.videosOf(name).length)),
                  trailing: IconButton(
                    tooltip: 'Delete playlist',
                    icon: const Icon(LucideIcons.trash2, size: 18),
                    onPressed: () => unawaited(lists.delete(name)),
                  ),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => ListenableBuilder(
                      listenable: lists,
                      builder: (_, _) => VideoListScreen(
                        title: name,
                        videos: filesAt(lists.videosOf(name)),
                        onRemove: (video) => unawaited(lists.remove(name, video.path)),
                      ),
                    ),
                  )),
                ),
            ],
          );
        },
      ),
    );
  }
}

Future<String?> askPlaylistName(BuildContext context) {
  final field = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('New playlist'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (name) => Navigator.pop(dialog, name.trim().isEmpty ? null : name.trim()),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, field.text.trim().isEmpty ? null : field.text.trim()),
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

/// Asks which playlist, or for a new one, and adds the video there.
Future<void> showAddToPlaylist(BuildContext context, String path) async {
  final lists = VideoPlaylists.instance;
  await lists.load();
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  const newOne = '';
  final chosen = await AppSheet.show<String>(
    context,
    child: Builder(
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(LucideIcons.listPlus),
            title: const Text('New playlist…'),
            onTap: () => Navigator.pop(sheet, newOne),
          ),
          for (final name in lists.names)
            ListTile(
              leading: const Icon(LucideIcons.listVideo),
              title: Text(name),
              onTap: () => Navigator.pop(sheet, name),
            ),
        ],
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  final name = chosen == newOne ? await askPlaylistName(context) : chosen;
  if (name == null) return;
  await lists.add(name, path);
  messenger?.showSnackBar(SnackBar(content: Text('Added to $name')));
}

/// Asks for an address and plays it: http(s), HLS, RTSP, RTMP and all else mpv reads.
Future<void> showNetworkStream(BuildContext context) async {
  final history = VideoHistory.instance;
  await history.load();
  if (!context.mounted) return;
  final field = TextEditingController();
  var invalid = false;
  final address = await AppSheet.show<String>(
    context,
    child: StatefulBuilder(
      builder: (sheet, setSheet) {
        void submit() {
          final clean = cleanStreamAddress(field.text);
          if (clean == null) {
            setSheet(() => invalid = true);
          } else {
            Navigator.pop(sheet, clean);
          }
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Network stream', style: Theme.of(sheet).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('A video address: http, HLS (.m3u8), RTSP, RTMP and more.', style: Theme.of(sheet).textTheme.bodySmall),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'https://example.com/live.m3u8',
                prefixIcon: const Icon(LucideIcons.link, size: 18),
                errorText: invalid ? "That doesn't look like an address" : null,
              ),
              onSubmitted: (_) => submit(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(LucideIcons.play, size: 16),
              label: const Text('Play'),
              onPressed: submit,
            ),
            if (history.streams.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('Recent', style: Theme.of(sheet).textTheme.titleSmall),
              for (final url in history.streams.take(5))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(LucideIcons.history, size: 18),
                  title: Text(url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(sheet, url),
                ),
            ],
          ],
        );
      },
    ),
  );
  if (address == null || !context.mounted) return;
  await history.addStream(address);
  if (context.mounted) unawaited(VideoPlayerPage.open(context, [address]));
}

/// The settings that outlive a video, from the library.
Future<void> showPlayerDefaults(BuildContext context) async {
  final settings = VideoPlayerSettings.instance;
  await settings.load();
  if (!context.mounted) return;
  await AppSheet.show<void>(
    context,
    style: SheetStyle.side,
    child: ListenableBuilder(
      listenable: settings,
      builder: (sheet, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Player settings', style: Theme.of(sheet).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) ...[
            Text('On leaving the app', style: Theme.of(sheet).textTheme.titleSmall),
            for (final leaving in LeavingVideo.values)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(switch (leaving) {
                  LeavingVideo.pip => LucideIcons.pictureInPicture2,
                  LeavingVideo.background => LucideIcons.headphones,
                  LeavingVideo.pause => LucideIcons.pause,
                }, size: 18),
                title: Text(leaving.label),
                trailing: settings.leaving == leaving ? const Icon(LucideIcons.check, size: 18) : null,
                onTap: () => unawaited(settings.update(leaving: leaving)),
              ),
          ],
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(LucideIcons.history, size: 18),
            title: const Text('Continue where it stopped'),
            value: settings.resume,
            onChanged: (on) => unawaited(settings.update(resume: on)),
          ),
          const SizedBox(height: 8),
          Text('Decoder', style: Theme.of(sheet).textTheme.titleSmall),
          for (final decoder in VideoDecoder.available)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              leading: const Icon(LucideIcons.cpu, size: 18),
              title: Text('${decoder.short} · ${decoder.label}'),
              subtitle: Text(decoder.description),
              trailing: settings.decoder == decoder ? const Icon(LucideIcons.check, size: 18) : null,
              onTap: () => unawaited(settings.update(decoder: decoder)),
            ),
          if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(LucideIcons.hand, size: 18),
              title: const Text('Gestures'),
              subtitle: const Text('Drag to seek, and for brightness and volume'),
              value: settings.gestures,
              onChanged: (on) => unawaited(settings.update(gestures: on)),
            ),
        ],
      ),
    ),
  );
}
