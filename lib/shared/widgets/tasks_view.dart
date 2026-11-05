import 'dart:io';

import 'package:folder/core/build_features.dart';
import 'package:folder/core/platform/background_mode.dart';
import 'package:folder/core/platform/desktop.dart';
import 'package:folder/core/services/background_tasks.dart';
import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folder/features/viewer_office/common/viewer_ui.dart' show showViewerConfirm;
import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Only the tasks: what's left of the app while work goes on after its
/// window was closed (see [BackgroundMode]).
class TasksView extends StatelessWidget {
  const TasksView({super.key});

  @override
  Widget build(BuildContext context) {
    // macOS: Quit anyway asks first in a dialog. The view sits above the
    // app's navigator (hidden behind it), so it gets one of its own.
    if (Platform.isMacOS) {
      return HeroControllerScope.none(
        child: Navigator(
          onGenerateRoute: (settings) => PageRouteBuilder<void>(
            settings: settings,
            pageBuilder: (context, _, _) => const _TasksPage(),
          ),
        ),
      );
    }
    return const _TasksPage();
  }
}

class _TasksPage extends StatelessWidget {
  const _TasksPage();

  /// macOS: quits once the user agrees to stop what's still running.
  Future<void> _quitAnyway(BuildContext context, int running) async {
    final quit = await showViewerConfirm(
      context,
      title: running == 1 ? 'Quit and stop 1 task?' : 'Quit and stop $running tasks?',
      message: "Copies, conversions and downloads that haven't finished stop where they are.",
      confirmLabel: 'Quit',
      destructive: true,
    );
    if (quit) await BackgroundMode.instance.quit();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final downloads = kVideoDownloaderEnabled && VideoDownloaderController.instance.isStarted
        ? VideoDownloaderController.instance
        : null;
    return Material(
      color: colors.background,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([BackgroundTasks.instance, ?downloads]),
          builder: (context, _) {
            final tasks = BackgroundTasks.instance.all;
            final jobs = downloads?.jobs.where((j) => j.isActive).toList() ?? const [];
            final running = tasks.where((t) => t.isRunning).length + jobs.length;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                  child: Row(
                    children: [
                      Icon(LucideIcons.listChecks, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Folder tasks', style: text.titleMedium),
                            Text(
                              running == 0
                                  ? 'All done'
                                  : running == 1
                                      ? '1 running'
                                      : '$running running',
                              style: text.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (tasks.any((t) => !t.isRunning))
                        TextButton(
                          onPressed: BackgroundTasks.instance.clearFinished,
                          child: const Text('Clear finished'),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: tasks.isEmpty && jobs.isEmpty
                      ? Center(child: Text('Nothing is running.', style: text.bodyMedium))
                      : ListView(
                          padding: const EdgeInsets.all(12),
                          children: [
                            for (final job in jobs)
                              _TaskCard(
                                status: TaskStatus.running,
                                title: job.title ?? job.url,
                                message: job.percent == null ? 'Downloading' : '${job.percent!.round()}%',
                                progress: job.percent == null ? null : job.percent! / 100,
                                onCancel: () => downloads!.cancel(job.id),
                              ),
                            for (final task in tasks)
                              _TaskCard(
                                status: task.status,
                                title: task.title,
                                message: task.message,
                                progress: task.progress,
                                onCancel: task.canCancel ? task.cancel : null,
                                onShow: !task.isRunning && task.outputs.isNotEmpty && Desktop.isDesktop
                                    ? () => Desktop.openWindow(folder: p.dirname(task.outputs.first))
                                    : null,
                              ),
                          ],
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        // macOS: Close would only show this view again
                        // (as the first Cmd+Q does), so it quits instead.
                        child: Platform.isMacOS && running > 0
                            ? OutlinedButton.icon(
                                onPressed: () => _quitAnyway(context, running),
                                icon: const Icon(LucideIcons.power, size: 16),
                                label: const Text('Quit anyway'),
                              )
                            : OutlinedButton(
                                onPressed: BackgroundMode.instance.close,
                                child: Text(running == 0 ? 'Quit' : (Platform.isWindows ? 'Hide' : 'Close')),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: BackgroundMode.instance.openExplorer,
                          child: const Text('Open Folder'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.status,
    required this.title,
    required this.message,
    required this.progress,
    this.onCancel,
    this.onShow,
  });

  final TaskStatus status;
  final String title;
  final String message;
  final double? progress;
  final VoidCallback? onCancel;
  final VoidCallback? onShow;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final icon = switch (status) {
      TaskStatus.running => SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
        ),
      TaskStatus.done => Icon(LucideIcons.circleCheck, size: 18, color: colors.primary),
      TaskStatus.failed => Icon(LucideIcons.circleAlert, size: 18, color: colors.destructive),
      TaskStatus.cancelled => Icon(LucideIcons.circleSlash, size: 18, color: colors.mutedForeground),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AppPanel(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                ),
                if (onShow != null) TextButton(onPressed: onShow, child: const Text('Show in folder')),
                if (onCancel != null) TextButton(onPressed: onCancel, child: const Text('Cancel')),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 28, right: 6, top: 2),
              child: Text(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: status == TaskStatus.failed ? colors.destructive : null),
              ),
            ),
            if (status == TaskStatus.running)
              Padding(
                padding: const EdgeInsets.only(left: 28, right: 6, top: 8),
                child: LinearProgressIndicator(value: progress, minHeight: 5),
              ),
          ],
        ),
      ),
    );
  }
}
