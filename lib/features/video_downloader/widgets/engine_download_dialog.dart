import 'package:folders/core/services/video_downloader/downloader_backend.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

import 'downloader_text.dart';

/// Asks to download the video engine before the first download; true when
/// the user agreed.
Future<bool> showEngineDownloadDialog(BuildContext context, EngineInfo engine) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return AlertDialog(
        title: const Row(
          children: [
            Icon(LucideIcons.download, size: 18),
            SizedBox(width: 10),
            Expanded(child: Text('Download the video engine?')),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The video downloader needs its engine (${engine.contents}) '
                  "before it can download anything. It isn't part of the app, "
                  'to keep the app small; you only download it once.',
                ),
                const SizedBox(height: 16),
                _Fact(
                  icon: LucideIcons.cloudDownload,
                  label: 'Download',
                  value: '${DownloaderText.bytes(engine.downloadBytes)}, Wi-Fi recommended',
                ),
                const SizedBox(height: 8),
                _Fact(
                  icon: LucideIcons.hardDrive,
                  label: 'Storage',
                  value: DownloaderText.bytes(engine.diskBytes),
                ),
                const SizedBox(height: 16),
                Text(
                  'It comes from ${engine.source} and is checked before it is '
                  'installed. You can remove it in the downloader settings.',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 16, color: colors.mutedForeground),
        const SizedBox(width: 10),
        SizedBox(width: 72, child: Text(label, style: text.bodySmall)),
        Expanded(child: Text(value, style: text.bodyMedium)),
      ],
    );
  }
}
