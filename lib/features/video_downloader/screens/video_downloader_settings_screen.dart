import 'dart:io';

import 'package:folders/core/services/video_downloader/downloader_backend.dart';
import 'package:folders/core/services/video_downloader/downloader_settings.dart';
import 'package:folders/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folders/core/services/video_downloader/ytdlp_models.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:folders/core/app_licenses.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../widgets/cookie_settings.dart';
import '../widgets/downloader_text.dart';
import '../widgets/rights_notice.dart';
import 'downloader_logs_screen.dart';

/// Downloads, defaults, files, cookies, network, the engine, maintenance,
/// permissions (Android) and about.
class VideoDownloaderSettingsScreen extends StatefulWidget {
  const VideoDownloaderSettingsScreen({super.key, required this.controller});

  final VideoDownloaderController controller;

  @override
  State<VideoDownloaderSettingsScreen> createState() =>
      _VideoDownloaderSettingsScreenState();
}

class _VideoDownloaderSettingsScreenState
    extends State<VideoDownloaderSettingsScreen> with WidgetsBindingObserver {
  late final _template = TextEditingController(
    text: _c.settings.filenameTemplate,
  );
  late final _langs = TextEditingController(text: _c.settings.subtitleLangs);
  late final _userAgent = TextEditingController(text: _c.settings.customUserAgent);

  /// Android: notifications and storage access, read again when the user
  /// comes back from the system settings.
  DownloaderPermissions? _permissions;
  bool _clearing = false;

  VideoDownloaderController get _c => widget.controller;

  DownloaderSettings get _s => _c.settings;

  void _set(DownloaderSettings s) => _c.updateSettings(s);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_c.engineState == EngineState.ready && _c.ytDlpVersion == null) {
      _c.refreshVersion();
    }
    if (Platform.isAndroid) _readPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) _readPermissions();
  }

  Future<void> _readPermissions() async {
    final state = await _c.permissions();
    if (mounted) setState(() => _permissions = state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _template.dispose();
    _langs.dispose();
    _userAgent.dispose();
    super.dispose();
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Save downloads in',
      initialDirectory: _c.outputDir.isEmpty ? null : _c.outputDir,
    );
    if (path == null || !mounted) return;
    if (!await _c.backend.canWrite(path)) {
      if (!mounted) return;
      _say(
        Platform.isAndroid
            ? "Folders can't write to that folder. Allow Folders to manage all files, or pick another folder."
            : "Folders can't write to that folder.",
      );
      return;
    }
    _set(_s.copyWith(outputDir: path));
  }

  Future<void> _update() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await _c.updateYtDlp();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            r.updated
                ? 'yt-dlp updated to ${r.version}'
                : 'yt-dlp is up to date (${r.version ?? 'unknown version'})',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _installEngine() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _c.installEngine();
      messenger.showSnackBar(
        const SnackBar(content: Text('The video engine is installed')),
      );
    } catch (e) {
      if (e is DownloaderException && e.cancelled) return;
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _removeEngine(EngineInfo engine) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the video engine?'),
        content: Text(
          'This frees ${DownloaderText.bytes(engine.diskBytes)}. The video '
          "downloader won't work until you download the engine again "
          '(${DownloaderText.bytes(engine.downloadBytes)}).',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.destructive,
              foregroundColor: context.colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _c.removeEngine();
      messenger.showSnackBar(
        const SnackBar(content: Text('The video engine was removed')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    try {
      final freed = await _c.clearCache();
      // Thumbnails of links and downloads are cached in memory.
      PaintingBinding.instance.imageCache.clear();
      if (mounted) {
        _say(freed > 0 ? 'Freed ${DownloaderText.bytes(freed)}' : 'The cache was already empty');
      }
    } catch (e) {
      if (mounted) _say("Couldn't clear the cache: $e");
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  void _openLogs() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DownloaderLogsScreen(log: _c.log)),
      );

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: 'Downloader settings',
      body: ListenableBuilder(
        listenable: Listenable.merge([_c, _c.cookies, _c.log]),
        builder: (context, _) => ReadableWidth(
          maxWidth: 760,
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              DockedGlossyTopBar.contentTopInset(context) + 4,
              16,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              _section(context, 'Downloads'),
              _card(_downloadTiles()),
              _section(context, 'Defaults'),
              _card(_defaultTiles()),
              _section(context, 'Files'),
              _card(_fileTiles(context)),
              _section(context, 'Cookies'),
              CookieSettingsCard(controller: _c),
              _section(context, 'Network'),
              _card(_networkTiles()),
              _section(context, 'Engine'),
              _card(_engineTiles(context)),
              _section(context, 'Maintenance'),
              _card(_maintenanceTiles()),
              if (Platform.isAndroid) ...[
                _section(context, 'Permissions'),
                _card(_permissionTiles()),
              ],
              _section(context, 'About'),
              _card([
                const ListTile(
                  leading: Icon(LucideIcons.scale),
                  title: Text('Download responsibly'),
                  subtitle: Text(rightsNoticeText),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.fileText),
                  title: const Text('Licenses'),
                  subtitle: const Text(
                    'yt-dlp, FFmpeg, Python, youtubedl-android and more',
                  ),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Folders',
                    applicationLegalese: appLegalese,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _downloadTiles() => [
        ListTile(
          leading: const Icon(LucideIcons.folderDown),
          title: Text(
            _c.outputDir.isEmpty ? 'Default folder' : _c.outputDir,
          ),
          subtitle: Text(
            _s.outputDir == null ? 'Default folder' : 'Custom folder',
          ),
          trailing: OutlinedButton(
            onPressed: _pickFolder,
            style: _buttonStyle,
            child: const Text('Change'),
          ),
        ),
        if (_s.outputDir != null)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 4),
              child: TextButton(
                onPressed: () => _set(_s.copyWith(resetOutputDir: true)),
                child: const Text('Use the default folder'),
              ),
            ),
          ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.folderOpen),
          title: const Text('Playlists in their own folder'),
          subtitle: const Text('A folder named after the playlist'),
          value: _s.playlistFolder,
          onChanged: (v) => _set(_s.copyWith(playlistFolder: v)),
        ),
        _dropdown<int>(
          icon: LucideIcons.layers,
          title: 'Downloads at once',
          value: _s.maxConcurrent,
          items: {
            for (var n = DownloaderSettings.minConcurrent;
                n <= DownloaderSettings.maxConcurrentLimit;
                n++)
              n: n == DownloaderSettings.defaultConcurrent ? '$n (default)' : '$n',
          },
          onChanged: (v) => _set(_s.copyWith(maxConcurrent: v)),
        ),
        SwitchListTile(
          secondary: Icon(_s.notifications ? LucideIcons.bell : LucideIcons.bellOff),
          title: const Text('Notifications'),
          subtitle: Text(
            Platform.isAndroid
                ? (_s.notifications
                    ? 'Progress and finished downloads in the notification shade'
                    : 'Off. Android still shows a quiet notification while '
                        'downloads run in the background.')
                : 'A message when a download finishes',
          ),
          value: _s.notifications,
          onChanged: (v) => _set(_s.copyWith(notifications: v)),
        ),
      ];

  /// What a new download gets: the options for video, or for audio only,
  /// whichever is chosen (each kind uses only its own).
  List<Widget> _defaultTiles() {
    final audio = _s.defaultKind == DownloadKind.audio;
    return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<DownloadKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: DownloadKind.video,
                icon: Icon(LucideIcons.film, size: 16),
                label: Text('Video'),
              ),
              ButtonSegment(
                value: DownloadKind.audio,
                icon: Icon(LucideIcons.music, size: 16),
                label: Text('Audio only'),
              ),
            ],
            selected: {
              _s.defaultKind == DownloadKind.audio
                  ? DownloadKind.audio
                  : DownloadKind.video,
            },
            onSelectionChanged: (v) => _set(_s.copyWith(defaultKind: v.first)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            audio
                ? 'New downloads save the sound only. Each download can still be changed.'
                : 'New downloads save the video with its sound. Each download can still be changed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (!audio)
        _dropdown<VideoQuality>(
          icon: LucideIcons.monitor,
          title: 'Video quality',
          value: _s.defaultQuality,
          items: {for (final q in VideoQuality.values) q: q.label},
          onChanged: (v) => _set(_s.copyWith(defaultQuality: v)),
        ),
        if (audio) ...[
        _dropdown<AudioFormat>(
          icon: LucideIcons.music,
          title: 'Audio format',
          value: _s.audioFormat,
          items: {for (final f in AudioFormat.values) f: f.label},
          onChanged: (v) => _set(_s.copyWith(audioFormat: v)),
        ),
        _dropdown<AudioQuality>(
          icon: LucideIcons.audioLines,
          title: 'Audio quality',
          value: _s.audioQuality,
          items: {for (final q in AudioQuality.values) q: q.label},
          onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(audioQuality: v)) : null,
        ),
        if (!_c.hasFfmpeg)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 16, 10),
              child: Text(
                'Needs FFmpeg: without it the audio is saved as the site offers it.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
        if (!audio) ...[
        _dropdown<VideoContainer>(
          icon: LucideIcons.clapperboard,
          title: 'Video file type',
          value: _s.container,
          items: {for (final c in VideoContainer.values) c: c.label},
          onChanged: (v) => _set(_s.copyWith(container: v)),
        ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.smartphone),
          title: const Text('Prefer compatible formats'),
          subtitle: const Text(
            'H.264 video and AAC audio, which play on almost any device',
          ),
          value: _s.preferCompatible,
          onChanged: (v) => _set(_s.copyWith(preferCompatible: v)),
        ),
        ],
      ];
  }

  List<Widget> _fileTiles(BuildContext context) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _template,
            autocorrect: false,
            style: CodeFont.style(
              fontSize: 13,
              color: context.colors.foreground,
            ),
            decoration: InputDecoration(
              labelText: 'Name template',
              prefixIcon: const Icon(LucideIcons.squarePen, size: 16),
              helperText:
                  'yt-dlp output template, e.g. %(uploader)s/%(title)s.%(ext)s',
              helperMaxLines: 2,
              suffixIcon: IconButton(
                tooltip: 'Reset',
                icon: const Icon(LucideIcons.rotateCcw, size: 16),
                onPressed: () {
                  _template.text = DownloaderSettings.defaultFilenameTemplate;
                  _set(
                    _s.copyWith(
                      filenameTemplate: DownloaderSettings.defaultFilenameTemplate,
                    ),
                  );
                },
              ),
            ),
            onChanged: (v) => _set(_s.copyWith(filenameTemplate: v)),
          ),
        ),
        if (!_c.hasFfmpeg)
          const ListTile(
            leading: Icon(LucideIcons.info),
            title: Text('Needs FFmpeg'),
            subtitle: Text(
              'Embedding thumbnails, metadata, chapters and subtitles needs FFmpeg.',
            ),
          ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.image),
          title: const Text('Embed thumbnail'),
          subtitle: const Text('As cover art'),
          value: _s.embedThumbnail,
          onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(embedThumbnail: v)) : null,
        ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.tag),
          title: const Text('Embed metadata'),
          subtitle: const Text('Title, artist, date and description'),
          value: _s.embedMetadata,
          onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(embedMetadata: v)) : null,
        ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.listOrdered),
          title: const Text('Embed chapters'),
          value: _s.embedChapters,
          onChanged: _c.hasFfmpeg ? (v) => _set(_s.copyWith(embedChapters: v)) : null,
        ),
        SwitchListTile(
          secondary: const Icon(LucideIcons.captions),
          title: const Text('Subtitles'),
          subtitle: Text(
            _c.hasFfmpeg
                ? 'Added to the video when available'
                : 'Saved next to the video when available',
          ),
          value: _s.subtitles,
          onChanged: (v) => _set(_s.copyWith(subtitles: v)),
        ),
        if (_s.subtitles) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _langs,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Languages',
                prefixIcon: Icon(LucideIcons.languages, size: 16),
                helperText: 'Comma-separated codes; en.* is every English variant',
              ),
              onChanged: (v) => _set(_s.copyWith(subtitleLangs: v)),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(LucideIcons.sparkles),
            title: const Text('Include automatic captions'),
            value: _s.autoSubtitles,
            onChanged: (v) => _set(_s.copyWith(autoSubtitles: v)),
          ),
        ],
      ];

  List<Widget> _networkTiles() => [
        _dropdown<UserAgentPreset>(
          icon: LucideIcons.network,
          title: 'User agent',
          value: _s.userAgent,
          items: {for (final u in UserAgentPreset.values) u: u.label},
          onChanged: (v) => _set(_s.copyWith(userAgent: v)),
        ),
        // Aligned, so no line separates them from the menu.
        if (_s.userAgent == UserAgentPreset.custom)
          Align(
            child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _userAgent,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 1,
              maxLines: 3,
              style: CodeFont.style(fontSize: 12, color: context.colors.foreground),
              decoration: const InputDecoration(
                labelText: 'Custom user agent',
                hintText: 'Mozilla/5.0 (…)',
                helperText: 'Sent as the User-Agent header. Leave it empty for '
                    "yt-dlp's own.",
                helperMaxLines: 2,
              ),
              onChanged: (v) => _set(_s.copyWith(customUserAgent: v)),
            ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 16, 12),
              child: Text(
                _s.userAgent.value ??
                    "yt-dlp picks a browser's user agent itself, and changes it "
                        'with each new release.',
                style: _s.userAgent.value == null
                    ? Theme.of(context).textTheme.bodySmall
                    : CodeFont.style(fontSize: 11.5, color: context.colors.mutedForeground),
              ),
            ),
          ),
      ];

  List<Widget> _maintenanceTiles() {
    final count = _c.log.entries.length;
    return [
      ListTile(
        leading: const Icon(LucideIcons.scrollText),
        title: const Text('Logs'),
        subtitle: Text(
          count == 0
              ? 'Nothing logged yet'
              : '$count ${count == 1 ? 'entry' : 'entries'}: downloads, errors and engine updates',
        ),
        trailing: const Icon(LucideIcons.chevronRight, size: 18),
        onTap: _openLogs,
      ),
      ListTile(
        leading: const Icon(LucideIcons.brushCleaning),
        title: const Text('Clear cache'),
        subtitle: const Text(
          "Partial downloads, thumbnails and yt-dlp's cache. Finished downloads stay.",
        ),
        trailing: _clearing
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : OutlinedButton(
                onPressed: _clearCache,
                style: _buttonStyle,
                child: const Text('Clear'),
              ),
      ),
    ];
  }

  /// Android: storage access and notifications, with the way to change them.
  List<Widget> _permissionTiles() {
    final state = _permissions;
    final storage = state?.storage;
    final notifications = state?.notifications;
    return [
      ListTile(
        leading: Icon(
          storage == false ? LucideIcons.triangleAlert : LucideIcons.hardDrive,
          color: storage == false ? context.toneColor(Tone.warning) : null,
        ),
        title: const Text('Storage'),
        subtitle: Text(switch (storage) {
          null => 'Checking…',
          true => '${state!.sdk >= 30 ? 'All files access allowed' : 'Allowed'}: '
              'downloads can go to any folder',
          false => 'Not allowed: downloads can only go to some folders',
        }),
        trailing: OutlinedButton(
          onPressed: storage == null
              ? null
              : () async {
                  if (storage) {
                    await openAppSettings();
                  } else {
                    await _c.requestStorageAccess();
                  }
                  await _readPermissions();
                },
          style: _buttonStyle,
          child: Text(storage == false ? 'Allow' : 'Settings'),
        ),
      ),
      ListTile(
        leading: Icon(
          notifications == false ? LucideIcons.bellOff : LucideIcons.bell,
          color: notifications == false && _s.notifications ? context.toneColor(Tone.warning) : null,
        ),
        title: const Text('Notification settings'),
        subtitle: Text(switch (notifications) {
          null => 'Checking…',
          true => 'Allowed',
          false => _s.notifications
              ? "Android has notifications turned off for Folders, so downloads don't show"
              : 'Turned off',
        }),
        trailing: OutlinedButton(
          onPressed: notifications == null
              ? null
              : () async {
                  if (notifications) {
                    await _c.openNotificationSettings();
                  } else {
                    await _c.allowNotifications();
                  }
                  await _readPermissions();
                },
          style: _buttonStyle,
          child: Text(notifications == false ? 'Allow' : 'Settings'),
        ),
      ),
    ];
  }

  List<Widget> _engineTiles(BuildContext context) {
    final last = _c.lastUpdateCheck;
    final version = _c.ytDlpVersion;
    final engine = _c.engine;
    return [
      if (engine != null) _videoEngineTile(engine),
      ListTile(
        leading: const Icon(LucideIcons.refreshCw),
        title: Text(
          version == null
              ? (_c.engineState == EngineState.ready
                    ? 'yt-dlp'
                    : 'yt-dlp (not set up yet)')
              : 'yt-dlp $version',
        ),
        subtitle: Text(
          last == null
              ? 'Never checked for updates'
              : 'Checked ${DateFormat('d MMM y, HH:mm').format(last)}',
        ),
        trailing: _c.updating
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : OutlinedButton(
                onPressed: _c.isSupported ? _update : null,
                style: _buttonStyle,
                child: const Text('Update'),
              ),
      ),
      SwitchListTile(
        secondary: const Icon(LucideIcons.calendarClock),
        title: const Text('Update automatically'),
        subtitle: const Text(
          'Check for a new stable release once a day. Sites '
          'change often; an old yt-dlp stops working.',
        ),
        value: _s.autoUpdate,
        onChanged: (v) => _set(_s.copyWith(autoUpdate: v)),
      ),
      ListTile(
        leading: const Icon(LucideIcons.clapperboard),
        title: Text(_c.hasFfmpeg ? 'FFmpeg available' : 'FFmpeg not found'),
        subtitle: Text(_c.backendStatus?.ffmpegNote ?? ''),
      ),
    ];
  }

  /// Android: the downloaded Python and FFmpeg.
  Widget _videoEngineTile(EngineInfo engine) {
    final busy = _c.engineState == EngineState.preparing;
    return ListTile(
      leading: const Icon(LucideIcons.package),
      title: const Text('Video engine'),
      subtitle: Text(
        busy
            ? _c.engineMessage ?? 'Installing…'
            : engine.installed
            ? '${engine.contents}, ${DownloaderText.bytes(engine.diskBytes)}'
            : 'Not downloaded. Needed to download videos '
                  '(${DownloaderText.bytes(engine.downloadBytes)}).',
      ),
      trailing: busy
          ? const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : engine.installed
          ? OutlinedButton(
              onPressed: _c.activeCount > 0 ? null : () => _removeEngine(engine),
              style: _buttonStyle,
              child: const Text('Remove'),
            )
          : OutlinedButton(
              onPressed: _installEngine,
              style: _buttonStyle,
              child: const Text('Download'),
            ),
    );
  }

  static final _buttonStyle = OutlinedButton.styleFrom(
    minimumSize: const Size(0, 36),
    padding: const EdgeInsets.symmetric(horizontal: 12),
  );

  Widget _section(BuildContext context, String title) =>
      SectionLabel(title, padding: const EdgeInsets.fromLTRB(4, 24, 4, 8));

  /// Bordered group; rows separated by hairlines.
  Widget _card(List<Widget> children) => SurfaceCard(
    padding: const EdgeInsets.symmetric(vertical: 4),
    clip: true,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && children[i] is! Align) const Divider(height: 1),
          children[i],
        ],
      ],
    ),
  );

  Widget _dropdown<T>({
    required IconData icon,
    required String title,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T>? onChanged,
  }) {
    final enabled = onChanged != null;
    // A Row, not a ListTile: the menu's width depends on its longest item
    // and must shrink on narrow phones.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
      child: Row(
        children: [
          Icon(icon, size: 20, color: enabled ? null : context.colors.mutedForeground),
          const SizedBox(width: 16),
          Expanded(
            flex: 4,
            child: Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: enabled ? null : context.colors.mutedForeground,
                  ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(8),
              dropdownColor: context.colors.popover,
              icon: Icon(
                LucideIcons.chevronsUpDown,
                size: 16,
                color: context.colors.mutedForeground,
              ),
              style: Theme.of(context).textTheme.bodyMedium,
              items: [
                for (final e in items.entries)
                  DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: onChanged == null
                  ? null
                  : (v) {
                      if (v != null) onChanged(v);
                    },
            ),
          ),
        ],
      ),
    );
  }
}
