import 'dart:async';

import 'package:folder/core/build_features.dart';
import 'package:folder/core/services/background_tasks.dart';
import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folder/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:folder/features/video_downloader/widgets/downloader_text.dart';
import 'package:folder/shared/ui/app_ui.dart';
import 'package:folder/shared/widgets/progress_card.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// A running task shown in the [ProgressDock].
class DockTask {
  const DockTask({
    required this.title,
    required this.message,
    this.progress,
    this.onCancel,
    this.onTap,
  });

  final String title;
  final String message;

  /// 0–1, or null when it can't be measured.
  final double? progress;
  final VoidCallback? onCancel;
  final VoidCallback? onTap;
}

/// Running tasks at the bottom right (full width on phones): the file
/// operation in [fileTask] and the video downloads. A small button above
/// them tucks them into a floating ring with their overall progress; hovering
/// over the ring (or tapping it) shows them again.
///
/// Returns a [Positioned]: place it directly in a [Stack].
class ProgressDock extends StatefulWidget {
  const ProgressDock({super.key, this.fileTask});

  final DockTask? fileTask;

  @override
  State<ProgressDock> createState() => _ProgressDockState();
}

class _ProgressDockState extends State<ProgressDock> {
  /// Kept while tasks run, also when the screen is rebuilt or reopened.
  static bool _hidden = false;
  bool _peek = false;

  /// Shows a finished task a little longer (errors longer), then rebuilds
  /// without it.
  Timer? _expiry;

  static Duration _shownFor(BackgroundTask t) =>
      t.status == TaskStatus.failed ? const Duration(seconds: 20) : const Duration(seconds: 6);

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  VideoDownloaderController? get _downloads =>
      kVideoDownloaderEnabled && VideoDownloaderController.instance.isStarted
          ? VideoDownloaderController.instance
          : null;

  List<DockTask> _tasks(BuildContext context) {
    final downloads = _downloads;
    final now = DateTime.now();
    Duration? nextExpiry;
    final background = <DockTask>[];
    for (final t in BackgroundTasks.instance.all) {
      if (!t.isRunning) {
        final left = _shownFor(t) - now.difference(t.finished!);
        if (left <= Duration.zero) continue;
        if (nextExpiry == null || left < nextExpiry) nextExpiry = left;
      }
      background.add(DockTask(
        title: t.title,
        message: t.message,
        progress: t.isRunning ? t.progress : (t.status == TaskStatus.done ? 1 : null),
        onCancel: t.canCancel ? t.cancel : null,
      ));
    }
    _expiry?.cancel();
    if (nextExpiry != null) {
      _expiry = Timer(nextExpiry, () {
        if (mounted) setState(() {});
      });
    }
    return [
      ?widget.fileTask,
      ...background,
      if (downloads != null) ...[
        if (downloads.engineState == EngineState.preparing)
          DockTask(
            title: 'Video engine',
            message: downloads.engineMessage ?? 'Downloading…',
            progress: downloads.engineProgress,
            onCancel: downloads.engineMissing
                ? downloads.cancelEngineInstall
                : null,
            onTap: () => _openDownloader(context),
          ),
        for (final job in downloads.jobs.where((j) => j.isActive))
          DockTask(
            title: job.title ?? job.url,
            message: job.status.name == 'queued'
                ? 'Waiting to start'
                : [
                    if (job.percent != null) '${job.percent!.round()}%',
                    if (job.speed != null && job.speed! > 0)
                      '${DownloaderText.bytes(job.speed)}/s',
                    if (job.isPostProcessing) 'Finishing',
                  ].join(' · '),
            progress: job.percent == null ? null : job.percent! / 100,
            onCancel: () => downloads.cancel(job.id),
            onTap: () => _openDownloader(context),
          ),
      ],
    ];
  }

  void _openDownloader(BuildContext context) => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const VideoDownloaderScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final downloads = _downloads;
    final content = ListenableBuilder(
      listenable: Listenable.merge([BackgroundTasks.instance, ?downloads]),
      builder: (context, _) => _build(context),
    );
    return Positioned(
      left: 16,
      right: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 16,
      child: Align(alignment: Alignment.bottomRight, child: content),
    );
  }

  Widget _build(BuildContext context) {
    final tasks = _tasks(context);
    if (tasks.isEmpty) {
      // Nothing running: the next task shows its tile again.
      _hidden = false;
      _peek = false;
      return const SizedBox.shrink();
    }
    final showTiles = !_hidden || _peek;
    final measured = [for (final t in tasks) ?t.progress];
    final overall = measured.isEmpty
        ? null
        : measured.reduce((a, b) => a + b) / measured.length;

    return MouseRegion(
      onEnter: (_) {
        if (_hidden) setState(() => _peek = true);
      },
      onExit: (_) {
        if (_peek) setState(() => _peek = false);
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (showTiles) ...[
              if (!_hidden)
                _SmallButton(
                  icon: LucideIcons.chevronDown,
                  tooltip: 'Hide',
                  onTap: () => setState(() => _hidden = true),
                ),
              for (final (index, task) in tasks.indexed) ...[
                if (index > 0) const SizedBox(height: 8),
                ProgressTile(
                  title: task.title,
                  message: task.message,
                  progress: task.progress ?? double.nan,
                  onCancel: task.onCancel,
                  onTap: task.onTap,
                ),
              ],
            ],
            if (_hidden) ...[
              if (showTiles) const SizedBox(height: 8),
              _FloatingRing(
                progress: overall,
                count: tasks.length,
                onTap: () => setState(() {
                  _hidden = false;
                  _peek = false;
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The minimal "hide" button above the tiles.
class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: colors.popover,
          shape: StadiumBorder(side: BorderSide(color: colors.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 32,
              height: 22,
              child: Icon(icon, size: 14, color: colors.mutedForeground),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tucked-away tasks: a round button with their overall progress and
/// how many there are.
class _FloatingRing extends StatelessWidget {
  const _FloatingRing({
    required this.progress,
    required this.count,
    required this.onTap,
  });

  final double? progress;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Tooltip(
      message: count == 1 ? '1 task running' : '$count tasks running',
      child: Material(
        color: colors.popover,
        shape: CircleBorder(side: BorderSide(color: colors.border)),
        elevation: 3,
        shadowColor: Colors.black26,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.square(
            dimension: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: 36,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 3,
                    color: colors.primary,
                    backgroundColor: colors.muted,
                  ),
                ),
                Text(
                  progress == null ? '$count' : '${(progress! * 100).round()}',
                  style: text.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
