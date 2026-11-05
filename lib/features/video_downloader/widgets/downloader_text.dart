import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:folder/core/services/video_downloader/ytdlp_output.dart';

/// Text helpers for the video downloader screens.
abstract final class DownloaderText {
  static String bytes(num? value) {
    if (value == null || value < 0) return '';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = value.toDouble();
    var unit = 0;
    while (v >= 1000 && unit < units.length - 1) {
      v /= 1000;
      unit++;
    }
    if (unit == 0) return '${v.round()} B';
    return '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[unit]}';
  }

  static String duration(num? seconds) {
    if (seconds == null || seconds < 0) return '';
    final s = seconds.round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
  }

  /// "youtube.com" from an extractor key or URL.
  static String site(String? extractor, String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isNotEmpty) return host.replaceFirst(RegExp(r'^(www|m)\.'), '');
    return extractor ?? '';
  }

  /// What a post-processing stage is doing. yt-dlp names them without
  /// the "FFmpeg" prefix ("Merger", "Metadata", "ExtractAudio"…).
  static String stage(String? stage) {
    if (stage == null || !stage.startsWith('pp:')) return 'Downloading';
    final name = stage.substring(3).replaceFirst(RegExp('^FFmpeg'), '');
    if (name.startsWith('Fixup')) return 'Fixing up the file';
    return switch (name) {
      'Merger' => 'Merging video and audio',
      'ExtractAudio' => 'Converting audio',
      'EmbedThumbnail' => 'Adding cover image',
      'Metadata' => 'Writing metadata',
      'EmbedSubtitle' => 'Adding subtitles',
      'SubtitlesConvertor' => 'Converting subtitles',
      'ThumbnailsConvertor' => 'Converting thumbnail',
      'VideoConvertor' || 'VideoRemuxer' => 'Converting video',
      'MoveFiles' => 'Saving',
      _ => 'Processing',
    };
  }

  /// One line describing a job's state.
  static String jobStatus(DownloadJob job) {
    switch (job.status) {
      case JobStatus.queued:
        return 'Waiting';
      case JobStatus.cancelled:
        return 'Cancelled';
      case JobStatus.done:
        return 'Finished';
      case JobStatus.failed:
        return job.error == null ? 'Failed' : error(job.error!);
      case JobStatus.running:
        if (job.isPostProcessing) return '${stage(job.stage)}…';
        if (job.percent == null && job.downloaded == null) return 'Starting…';
        final parts = <String>[
          if (job.part > 1) 'Part ${job.part}',
          if (job.percent != null) '${job.percent!.toStringAsFixed(job.percent! < 10 ? 1 : 0)}%',
          if (job.total != null)
            '${bytes(job.downloaded)} of ${bytes(job.total)}'
          else if (job.downloaded != null)
            bytes(job.downloaded),
          if (job.speed != null && job.speed! > 0) '${bytes(job.speed)}/s',
          if (job.eta != null && job.eta! > 0) '${duration(job.eta)} left',
        ];
        return parts.join(' · ');
    }
  }

  /// A yt-dlp error made readable.
  static String error(String message) =>
      YtDlpOutputParser.errorMessage('ERROR: $message');

  /// Web links in [text], in order, without duplicates.
  static List<String> extractUrls(String text) {
    final found = <String>[];
    for (final m in RegExp(r'''https?://[^\s<>"'`]+''', caseSensitive: false)
        .allMatches(text)) {
      var url = m.group(0)!;
      // Drop punctuation that ends a sentence rather than the link.
      while (url.isNotEmpty && '.,;:!?)]}>'.contains(url[url.length - 1])) {
        if (url.endsWith(')') && url.contains('(')) break;
        url = url.substring(0, url.length - 1);
      }
      if (url.length > 8 && !found.contains(url)) found.add(url);
    }
    if (found.isEmpty) {
      final t = text.trim();
      // "youtube.com/watch?v=…" typed without a scheme.
      if (t.isNotEmpty &&
          !t.contains(RegExp(r'\s')) &&
          RegExp(r'^[\w-]+(\.[\w-]+)+(/|$)').hasMatch(t)) {
        found.add('https://$t');
      }
    }
    return found;
  }
}
