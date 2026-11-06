import 'package:folders/core/services/video_downloader/ytdlp_models.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

import 'downloader_text.dart';

/// Lets the user pick one exact format; returns it, or null.
Future<VideoFormat?> showFormatPicker(
  BuildContext context, {
  required VideoInfo info,
  required bool hasFfmpeg,
  VideoFormat? selected,
}) {
  if (!AppSheet.usesBottomSheet(context)) {
    return AppSheet.showRaw<VideoFormat>(
      context,
      builder: (_) => _FormatList(info: info, hasFfmpeg: hasFfmpeg, selected: selected),
    );
  }
  return showModalBottomSheet<VideoFormat>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => _FormatList(
        info: info,
        hasFfmpeg: hasFfmpeg,
        selected: selected,
        scrollController: scroll,
      ),
    ),
  );
}

class _FormatList extends StatelessWidget {
  const _FormatList({
    required this.info,
    required this.hasFfmpeg,
    required this.selected,
    this.scrollController,
  });

  final VideoInfo info;
  final bool hasFfmpeg;
  final VideoFormat? selected;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final formats = info.pickableFormats;
    final groups = <String, List<VideoFormat>>{
      'Video and audio': formats.where((f) => !f.isAudioOnly && !f.isVideoOnly).toList(),
      'Video only': formats.where((f) => f.isVideoOnly).toList(),
      'Audio only': formats.where((f) => f.isAudioOnly).toList(),
    }..removeWhere((_, list) => list.isEmpty);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Text('Choose a format', style: text.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Text(
            hasFfmpeg
                ? 'Video-only formats are combined with the best audio.'
                : 'Without FFmpeg, video-only formats are saved without sound.',
            style: text.bodySmall,
          ),
        ),
        for (final group in groups.entries) ...[
          SectionLabel(
            group.key,
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
            trailing: CountPill('${group.value.length}'),
          ),
          for (final f in group.value)
            ListRow(
              selected: selected?.id == f.id,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              leading: IconBox(
                f.isAudioOnly
                    ? LucideIcons.music
                    : f.isVideoOnly
                        ? LucideIcons.videoOff
                        : LucideIcons.film,
                size: 36,
              ),
              title: f.shortLabel,
              subtitle: [
                ?f.codecLabel,
                if (f.filesize != null)
                  '${f.filesizeApprox ? '≈' : ''}${DownloaderText.bytes(f.filesize)}',
                if (f.tbr != null) '${f.tbr!.round()} kbit/s',
                if (f.note != null && f.note!.isNotEmpty) f.note!,
              ].join(' · '),
              trailing: Text(
                '#${f.id}',
                style: CodeFont.style(fontSize: 11, color: colors.mutedForeground),
              ),
              onTap: () => Navigator.pop(context, f),
            ),
        ],
      ],
    );
  }
}
