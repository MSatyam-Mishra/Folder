import 'dart:async';
import 'dart:io';

import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/video_downloader/downloader_backend.dart';
import 'package:folders/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folders/core/services/video_downloader/ytdlp_models.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';

import '../widgets/download_panel.dart';
import '../widgets/empty_state.dart';
import '../widgets/engine_download_dialog.dart';
import '../widgets/history_list.dart';
import '../widgets/queue_list.dart';
import '../widgets/rights_notice.dart';
import 'video_downloader_settings_screen.dart';

/// Downloads videos and audio from web links with yt-dlp.
///
/// [initialUrl] (e.g. a link shared from another app) is fetched right away.
/// Downloads run outside this screen, so leaving it doesn't stop them.
class VideoDownloaderScreen extends StatefulWidget {
  const VideoDownloaderScreen({super.key, this.initialUrl});

  /// A link to fill in, e.g. one shared from another app.
  final String? initialUrl;

  @override
  State<VideoDownloaderScreen> createState() => _VideoDownloaderScreenState();
}

enum _Tab { download, queue, history }

class _VideoDownloaderScreenState extends State<VideoDownloaderScreen> {
  final _controller = VideoDownloaderController.instance;
  final _panelKey = GlobalKey<DownloadPanelState>();
  _Tab _tab = _Tab.download;

  /// Wide layout: the side pane shows the queue or the history.
  _Tab _sideTab = _Tab.queue;
  StreamSubscription<HistoryEntry>? _completed;
  Future<bool>? _rightsPrompt;
  Future<bool>? _enginePrompt;

  @override
  void initState() {
    super.initState();
    _completed = _controller.completed.listen(_onCompleted);
    _init();
  }

  @override
  void dispose() {
    _completed?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final reopened = _controller.isStarted;
    await _controller.start();
    if (!mounted || !_controller.isSupported) return;
    if (reopened && Platform.isMacOS) await _refreshFfmpeg();
    if (!mounted || !await _beforeUse()) return;
    final url = widget.initialUrl?.trim();
    if (url != null && url.isNotEmpty) {
      await _panelKey.currentState?.fetch();
      return;
    }
    // After the notices, so what's behind them doesn't change.
    unawaited(_panelKey.currentState?.fillFromClipboard());
    if (Platform.isAndroid) {
      // Start yt-dlp now so the first fetch is quick.
      unawaited(_controller.ensureReady().catchError((Object _) {}));
    }
  }

  /// Looks for FFmpeg again: it may have been installed (on a Mac, with
  /// Homebrew) since the downloader was last open, so the engine may need
  /// less. Once the engine download was agreed to, it reports the engine
  /// itself: only what's said about FFmpeg changes then.
  Future<void> _refreshFfmpeg() async {
    if (_controller.backendStatus == null) return;
    try {
      final now = await _controller.backend.status();
      // Read after the wait: the engine download may have finished meanwhile.
      final current = _controller.backendStatus;
      if (!mounted || current == null) return;
      setState(() => _controller.backendStatus = _controller.engineAllowed
          ? BackendStatus(
              ready: current.ready,
              needsSetup: current.needsSetup,
              hasFfmpeg: now.hasFfmpeg,
              ffmpegNote: now.ffmpegNote,
              setupNote: current.setupNote,
              engine: current.engine,
            )
          : now);
    } catch (_) {
      // Keep what was found before.
    }
  }

  /// The rights notice, then the engine download; false if the user
  /// declined either.
  Future<bool> _beforeUse() async => await _ensureRights() && await _ensureEngine();

  /// Shows the first-use notice once; false if the user declined it.
  Future<bool> _ensureRights() async {
    if (_controller.rightsAccepted) return true;
    if (!mounted) return false;
    final accepted = await (_rightsPrompt ??= showRightsNotice(context)
        .whenComplete(() => _rightsPrompt = null));
    if (accepted) await _controller.acceptRights();
    return accepted;
  }

  /// Asks to download the engine on first use (Android) and starts the
  /// download; false if the user declined. Nothing downloads without it.
  Future<bool> _ensureEngine() async {
    final engine = _controller.engine;
    if (engine == null || engine.installed || _controller.engineAllowed) return true;
    if (!mounted) return false;
    final accepted = await (_enginePrompt ??= showEngineDownloadDialog(context, engine)
        .whenComplete(() => _enginePrompt = null));
    if (accepted) unawaited(_controller.installEngine().catchError((Object _) {}));
    return accepted;
  }

  void _onCompleted(HistoryEntry entry) {
    if (!mounted) return;
    // Computers have no notification for it: the setting is about this
    // message there. Android's is in the shade, and this one stays.
    if (!Platform.isAndroid && !_controller.settings.notifications) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Downloaded “${entry.title}”', maxLines: 2, overflow: TextOverflow.ellipsis),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () {
          if (mounted) FileOpener.open(context, File(entry.filePath));
        },
      ),
    ));
  }

  void _onQueued(int count, bool wide) {
    if (!mounted) return;
    if (wide) {
      setState(() => _sideTab = _Tab.queue);
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(count == 1 ? 'Added to the downloads' : 'Added $count downloads'),
      action: wide
          ? null
          : SnackBarAction(label: 'View', onPressed: () => setState(() => _tab = _Tab.queue)),
    ));
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoDownloaderSettingsScreen(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: 'Video downloader',
      trailing: _controller.isSupported
          ? Padding(
              padding: const EdgeInsets.only(right: 4),
              child: AppIconButton(
                icon: const Icon(LucideIcons.settings),
                tooltip: 'Downloader settings',
                onPressed: _openSettings,
              ),
            )
          : null,
      body: LayoutBuilder(builder: (context, constraints) {
        final top = DockedGlossyTopBar.contentTopInset(context);
        final bottom = MediaQuery.paddingOf(context).bottom;
        if (!_controller.isSupported) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: EmptyState(
              icon: LucideIcons.ban,
              title: 'Not available on this device',
              message: _controller.unsupportedReason,
            ),
          );
        }
        final wide = constraints.maxWidth >= 840;
        final panel = DownloadPanel(
          key: _panelKey,
          controller: _controller,
          initialUrl: widget.initialUrl,
          onQueued: (n) => _onQueued(n, wide),
          onOpenSettings: _openSettings,
          beforeUse: _beforeUse,
          padding: EdgeInsets.fromLTRB(16, wide ? 16 : 4, 16, bottom),
        );
        final listPadding = EdgeInsets.fromLTRB(16, 4, 16, 24 + bottom);

        if (wide) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 11, child: panel),
                const VerticalDivider(width: 1),
                Expanded(
                  flex: 9,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: _tabs(
                          [_Tab.queue, _Tab.history],
                          _sideTab,
                          (t) => setState(() => _sideTab = t),
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: _sideTab == _Tab.queue ? 0 : 1,
                          children: [
                            QueueList(controller: _controller, padding: listPadding),
                            HistoryList(controller: _controller, padding: listPadding),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return Padding(
          padding: EdgeInsets.only(top: top),
          child: ReadableWidth(
            maxWidth: 760,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: _tabs(_Tab.values, _tab, (t) => setState(() => _tab = t)),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _tab.index,
                    children: [
                      panel,
                      QueueList(controller: _controller, padding: listPadding),
                      HistoryList(controller: _controller, padding: listPadding),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }

  /// shadcn Tabs: a muted track with the selected tab raised.
  Widget _tabs(List<_Tab> tabs, _Tab selected, ValueChanged<_Tab> onChanged) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final colors = context.colors;
        final active = _controller.activeCount;
        // Labels alone on narrow phones, so three tabs fit.
        final icons = MediaQuery.sizeOf(context).width >= 480;
        return Container(
          height: 40,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: colors.muted,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              for (final t in tabs)
                Expanded(
                  child: _TabButton(
                    selected: t == selected,
                    icon: icons
                        ? switch (t) {
                            _Tab.download => LucideIcons.link,
                            _Tab.queue => LucideIcons.download,
                            _Tab.history => LucideIcons.history,
                          }
                        : null,
                    label: switch (t) {
                      _Tab.download => 'New',
                      _Tab.queue => active == 0 ? 'Downloads' : 'Downloads ($active)',
                      _Tab.history => 'History',
                    },
                    onTap: () => onChanged(t),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final bool selected;
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = selected ? colors.foreground : colors.mutedForeground;
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: selected ? colors.background : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: context.isDarkMode ? 0.3 : 0.08,
                    ),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: fg),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: fg,
                          fontSize: 13,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
