import 'dart:io';

import 'package:folder/core/services/video_downloader/downloader_backend.dart';
import 'package:folder/core/services/video_downloader/downloader_settings.dart';
import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:folder/core/app_licenses.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../widgets/downloader_text.dart';
import '../widgets/rights_notice.dart';

/// Download folder, defaults, file names, extras and yt-dlp updates.
class VideoDownloaderSettingsScreen extends StatefulWidget {
  const VideoDownloaderSettingsScreen({super.key, required this.controller});

  final VideoDownloaderController controller;

  @override
  State<VideoDownloaderSettingsScreen> createState() =>
      _VideoDownloaderSettingsScreenState();
}

class _VideoDownloaderSettingsScreenState
    extends State<VideoDownloaderSettingsScreen> {
  late final _template = TextEditingController(
    text: _c.settings.filenameTemplate,
  );
  late final _langs = TextEditingController(text: _c.settings.subtitleLangs);

  VideoDownloaderController get _c => widget.controller;

  DownloaderSettings get _s => _c.settings;

  void _set(DownloaderSettings s) => _c.updateSettings(s);

  @override
  void initState() {
    super.initState();
    if (_c.engineState == EngineState.ready && _c.ytDlpVersion == null)
      _c.refreshVersion();
  }

  @override
  void dispose() {
    _template.dispose();
    _langs.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Save downloads in',
      initialDirectory: _c.outputDir.isEmpty ? null : _c.outputDir,
    );
    if (path == null || !mounted) return;
    if (!await _c.backend.canWrite(path)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            Platform.isAndroid
                ? "Folder can't write to that folder. Allow Folder to manage all files, or pick another folder."
                : "Folder can't write to that folder.",
          ),
        ),
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

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: 'Downloader settings',
      body: ListenableBuilder(
        listenable: _c,
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
              _section(context, 'Save to'),
              _card([
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
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text('Change'),
                  ),
                ),
                if (_s.outputDir != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 4),
                      child: TextButton(
                        onPressed: () =>
                            _set(_s.copyWith(resetOutputDir: true)),
                        child: const Text('Use the default folder'),
                      ),
                    ),
                  ),
                SwitchListTile(
                  title: const Text('Playlists in their own folder'),
                  subtitle: const Text('A folder named after the playlist'),
                  value: _s.playlistFolder,
                  onChanged: (v) => _set(_s.copyWith(playlistFolder: v)),
                ),
              ]),
              _section(context, 'Defaults'),
              _card([
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: SegmentedButton<DownloadKind>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: DownloadKind.video,
                        label: Text('Video'),
                      ),
                      ButtonSegment(
                        value: DownloadKind.audio,
                        label: Text('Audio only'),
                      ),
                    ],
                    selected: {
                      _s.defaultKind == DownloadKind.audio
                          ? DownloadKind.audio
                          : DownloadKind.video,
                    },
                    onSelectionChanged: (v) =>
                        _set(_s.copyWith(defaultKind: v.first)),
                  ),
                ),
                _dropdown<VideoQuality>(
                  title: 'Video quality',
                  value: _s.defaultQuality,
                  items: {for (final q in VideoQuality.values) q: q.label},
                  onChanged: (v) => _set(_s.copyWith(defaultQuality: v)),
                ),
                _dropdown<AudioFormat>(
                  title: 'Audio format',
                  value: _s.audioFormat,
                  items: {for (final f in AudioFormat.values) f: f.label},
                  onChanged: (v) => _set(_s.copyWith(audioFormat: v)),
                ),
                _dropdown<VideoContainer>(
                  title: 'Video file type',
                  value: _s.container,
                  items: {for (final c in VideoContainer.values) c: c.label},
                  onChanged: (v) => _set(_s.copyWith(container: v)),
                ),
                SwitchListTile(
                  title: const Text('Prefer compatible formats'),
                  subtitle: const Text(
                    'H.264 video and AAC audio, which play on almost any device',
                  ),
                  value: _s.preferCompatible,
                  onChanged: (v) => _set(_s.copyWith(preferCompatible: v)),
                ),
              ]),
              _section(context, 'File names'),
              _card([
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
                      helperText:
                          'yt-dlp output template, e.g. %(uploader)s/%(title)s.%(ext)s',
                      helperMaxLines: 2,
                      suffixIcon: IconButton(
                        tooltip: 'Reset',
                        icon: const Icon(LucideIcons.rotateCcw, size: 16),
                        onPressed: () {
                          _template.text =
                              DownloaderSettings.defaultFilenameTemplate;
                          _set(
                            _s.copyWith(
                              filenameTemplate:
                                  DownloaderSettings.defaultFilenameTemplate,
                            ),
                          );
                        },
                      ),
                    ),
                    onChanged: (v) => _set(_s.copyWith(filenameTemplate: v)),
                  ),
                ),
              ]),
              _section(context, 'Extras'),
              _card([
                if (!_c.hasFfmpeg)
                  const ListTile(
                    leading: Icon(LucideIcons.info),
                    title: Text('Needs FFmpeg'),
                    subtitle: Text(
                      'Embedding thumbnails, metadata, chapters and subtitles needs FFmpeg.',
                    ),
                  ),
                SwitchListTile(
                  title: const Text('Embed thumbnail'),
                  subtitle: const Text('As cover art'),
                  value: _s.embedThumbnail,
                  onChanged: _c.hasFfmpeg
                      ? (v) => _set(_s.copyWith(embedThumbnail: v))
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Embed metadata'),
                  subtitle: const Text('Title, artist, date and description'),
                  value: _s.embedMetadata,
                  onChanged: _c.hasFfmpeg
                      ? (v) => _set(_s.copyWith(embedMetadata: v))
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Embed chapters'),
                  value: _s.embedChapters,
                  onChanged: _c.hasFfmpeg
                      ? (v) => _set(_s.copyWith(embedChapters: v))
                      : null,
                ),
                SwitchListTile(
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
                        helperText:
                            'Comma-separated codes; en.* is every English variant',
                      ),
                      onChanged: (v) => _set(_s.copyWith(subtitleLangs: v)),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Include automatic captions'),
                    value: _s.autoSubtitles,
                    onChanged: (v) => _set(_s.copyWith(autoSubtitles: v)),
                  ),
                ],
              ]),
              _section(context, 'yt-dlp'),
              _card(_engineTiles(context)),
              _section(context, 'About'),
              _card([
                ListTile(
                  leading: const Icon(LucideIcons.scale),
                  title: const Text('Download responsibly'),
                  subtitle: const Text(rightsNoticeText),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.fileText),
                  title: const Text('Licenses'),
                  subtitle: const Text(
                    'yt-dlp, FFmpeg, Python, youtubedl-android and more',
                  ),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'Folder',
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
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('Update'),
              ),
      ),
      SwitchListTile(
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
    final buttonStyle = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
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
              style: buttonStyle,
              child: const Text('Remove'),
            )
          : OutlinedButton(
              onPressed: _installEngine,
              style: buttonStyle,
              child: const Text('Download'),
            ),
    );
  }

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
    required String title,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) =>
      // A Row, not a ListTile: the menu's width depends on its longest item
      // and must shrink on narrow phones.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 12, 2),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
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
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ],
        ),
      );
}
