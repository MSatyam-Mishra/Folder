import 'dart:io';

import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'downloader_text.dart';
import 'empty_state.dart';
import 'media_thumbnail.dart';

/// Running, waiting, failed and cancelled downloads.
class QueueList extends StatelessWidget {
  const QueueList({super.key, required this.controller, this.padding = EdgeInsets.zero});

  final VideoDownloaderController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final jobs = controller.jobs;
        if (jobs.isEmpty) {
          return EmptyState(
            icon: LucideIcons.download,
            title: 'No downloads in progress',
            message: 'Downloads you start appear here. They keep going when '
                'you leave this screen${_backgroundNote()}.',
            padding: padding,
          );
        }
        final finished = jobs.where((j) => !j.isActive).length;
        final active = jobs.length - finished;
        return ListView.builder(
          padding: padding,
          itemCount: jobs.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return SectionLabel(
                active == 0
                    ? 'Nothing running'
                    : '$active active · up to ${controller.backend.maxConcurrent} at a time',
                padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
                trailing: finished > 0
                    ? TextButton(
                        onPressed: controller.clearFinishedJobs,
                        child: const Text('Clear finished'),
                      )
                    : null,
              );
            }
            final job = jobs[i - 1];
            return _JobTile(key: ValueKey(job.id), job: job, controller: controller);
          },
        );
      },
    );
  }

  static String _backgroundNote() => Platform.isAndroid
      ? ' or the app (with a notification showing progress)'
      : ' (as long as Folder is open)';
}

class _JobTile extends StatelessWidget {
  const _JobTile({super.key, required this.job, required this.controller});

  final DownloadJob job;
  final VideoDownloaderController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final failed = job.status == JobStatus.failed;
    final status = DownloaderText.jobStatus(job);
    final audio = job.meta['kind'] == 'audio';
    final label = job.meta['label'] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: failed ? () => _showError(context) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MediaThumbnail(
                      url: job.thumbnail,
                      width: 80,
                      height: 45,
                      radius: 6,
                      icon: audio ? LucideIcons.music : LucideIcons.film,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.displayTitle,
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            [
                              if (label != null && job.status != JobStatus.running) label,
                              status,
                            ].join(' · '),
                            style: text.bodySmall?.copyWith(
                              color: failed
                                  ? colors.destructive
                                  : job.status == JobStatus.done
                                  ? context.toneColor(Tone.success)
                                  : null,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    ..._actions(context),
                  ],
                ),
                if (job.status == JobStatus.running)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 12, 6, 0),
                    child: LinearProgressIndicator(
                      value: job.isPostProcessing || job.percent == null ? null : job.percent! / 100,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    if (job.isActive) {
      return [
        ToolButton(
          tooltip: 'Cancel',
          icon: LucideIcons.x,
          onPressed: () => controller.cancel(job.id),
        ),
      ];
    }
    return [
      if (job.status == JobStatus.failed || job.status == JobStatus.cancelled)
        ToolButton(
          tooltip: 'Retry',
          icon: LucideIcons.refreshCw,
          onPressed: () => controller.retry(job.id),
        ),
      ToolButton(
        tooltip: 'Remove',
        icon: LucideIcons.trash2,
        onPressed: () => controller.dismiss(job.id),
      ),
    ];
  }

  void _showError(BuildContext context) {
    final details = [
      job.url,
      if (job.error != null) 'Error: ${job.error}',
      if (job.log != null && job.log!.isNotEmpty) '\n${job.log}',
    ].join('\n');
    showDialog<void>(
      context: context,
      builder: (context) {
        final colors = context.colors;
        return AlertDialog(
          title: Row(
            children: [
              Icon(LucideIcons.circleAlert, size: 18, color: colors.destructive),
              const SizedBox(width: 10),
              const Text('Download failed'),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    job.error == null
                        ? 'yt-dlp stopped with an error.'
                        : DownloaderText.error(job.error!),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Sites change often. If a link that used to work fails, '
                    'update yt-dlp in the downloader settings and try again.',
                  ),
                  if (job.log != null && job.log!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.muted,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        job.log!,
                        style: CodeFont.style(
                          fontSize: 11,
                          color: colors.foreground,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: details));
                Navigator.pop(context);
              },
              child: const Text('Copy details'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                controller.retry(job.id);
              },
              child: const Text('Retry'),
            ),
          ],
        );
      },
    );
  }
}
