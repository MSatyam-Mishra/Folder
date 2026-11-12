import 'dart:convert';

import 'ytdlp_args.dart';
import 'ytdlp_models.dart';

/// Parses what yt-dlp prints: `-J` JSON, the progress lines of
/// [YtDlpArgs.download] and error output.
abstract final class YtDlpOutputParser {
  /// Parses `yt-dlp -J --flat-playlist` output for [url].
  static VideoInfo parseInfo(String json, {required String url}) {
    final start = json.indexOf('{');
    if (start < 0) throw const FormatException('yt-dlp returned no information');
    final decoded = jsonDecode(json.substring(start));
    if (decoded is! Map) throw const FormatException('Unexpected yt-dlp output');
    return infoFromJson(decoded.cast<String, dynamic>(), url: url);
  }

  static VideoInfo infoFromJson(Map<String, dynamic> j, {required String url}) {
    final type = j['_type'] as String?;
    final rawEntries = j['entries'];
    final isPlaylist =
        (type == 'playlist' || type == 'multi_video') && rawEntries is List;
    final entries = <PlaylistEntry>[];
    if (isPlaylist) {
      var index = 0;
      for (final e in rawEntries) {
        index++;
        if (e is! Map) continue;
        final entry = _entry(e.cast<String, dynamic>(), index);
        if (entry != null) entries.add(entry);
      }
    }
    final formats = <VideoFormat>[
      for (final f in (j['formats'] as List?) ?? const [])
        if (f is Map) VideoFormat.fromJson(f.cast<String, dynamic>()),
    ];
    // A single-format result (e.g. a direct file link) may describe its
    // only format at the top level instead of in "formats".
    if (!isPlaylist && formats.isEmpty && j['format_id'] != null) {
      formats.add(VideoFormat.fromJson(j));
    }
    final live = j['is_live'] == true || j['live_status'] == 'is_live';
    return VideoInfo(
      url: url,
      id: _str(j['id']),
      title: _str(j['title']) ?? _str(j['fulltitle']),
      uploader: _str(j['uploader']) ?? _str(j['channel']) ?? _str(j['uploader_id']),
      duration: _num(j['duration'])?.toDouble(),
      thumbnail: _str(j['thumbnail']) ?? _bestThumbnail(j['thumbnails']),
      webpageUrl: _str(j['webpage_url']) ?? _str(j['original_url']),
      extractor: _str(j['extractor_key']) ?? _str(j['extractor']),
      isPlaylist: isPlaylist,
      isLive: live,
      entries: entries,
      formats: formats,
      playlistCount: _num(j['playlist_count'])?.toInt() ?? (isPlaylist ? entries.length : null),
    );
  }

  static PlaylistEntry? _entry(Map<String, dynamic> e, int index) {
    var url = _str(e['url']) ?? _str(e['webpage_url']) ?? _str(e['original_url']);
    final id = _str(e['id']);
    if (url == null || !url.contains('://')) {
      // Some extractors give only an ID; YouTube IDs make a watch URL.
      final key = _str(e['ie_key']) ?? _str(e['extractor_key']);
      if (key == 'Youtube' && (id ?? url) != null) {
        url = 'https://www.youtube.com/watch?v=${id ?? url}';
      } else if (_str(e['webpage_url']) != null) {
        url = _str(e['webpage_url']);
      } else {
        return null;
      }
    }
    final key = _str(e['ie_key']) ?? '';
    final nested = e['_type'] == 'playlist' ||
        key.endsWith('Tab') ||
        key.contains('Playlist') ||
        key.contains('Channel');
    return PlaylistEntry(
      index: _num(e['playlist_index'])?.toInt() ?? index,
      url: url!,
      id: id,
      title: _str(e['title']),
      duration: _num(e['duration'])?.toDouble(),
      thumbnail: _str(e['thumbnail']) ?? _bestThumbnail(e['thumbnails']),
      uploader: _str(e['uploader']) ?? _str(e['channel']),
      isNested: nested,
    );
  }

  /// The largest thumbnail no wider than ~1280px, else the last listed.
  static String? _bestThumbnail(Object? thumbs) {
    if (thumbs is! List || thumbs.isEmpty) return null;
    String? best;
    var bestWidth = -1;
    for (final t in thumbs) {
      if (t is! Map) continue;
      final url = _str(t['url']);
      if (url == null) continue;
      final w = _num(t['width'])?.toInt() ?? 0;
      if (w <= 1280 && w >= bestWidth) {
        best = url;
        bestWidth = w;
      }
    }
    if (best != null) return best;
    final last = thumbs.last;
    return last is Map ? _str(last['url']) : null;
  }

  /// The useful part of yt-dlp's error output: its last "ERROR:" line,
  /// without the prefix, else the last non-empty line.
  static String errorMessage(String output) {
    final lines = const LineSplitter()
        .convert(output)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    for (final line in lines.reversed) {
      if (line.startsWith('ERROR:')) return _tidyError(line.substring(6).trim());
    }
    return lines.isEmpty ? 'yt-dlp failed' : _tidyError(lines.last);
  }

  static String _tidyError(String message) {
    // "[youtube] abc123: Video unavailable" -> "Video unavailable"
    final m = RegExp(r'^\[[^\]]+\]\s+[^:\s]+:\s+(.*)$').firstMatch(message);
    return (m?.group(1) ?? message).trim();
  }
}

/// Follows a running download from yt-dlp's output lines and keeps the
/// job's state. Mirrors VideoDownloadJobs.kt (used on Android).
class JobProgressTracker {
  JobProgressTracker({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// Most lines kept in [output].
  static const maxOutput = 300;

  final DateTime Function() _clock;

  double? percent;
  int? downloaded;
  int? total;
  double? speed;
  int? eta;
  String? stage;
  int part = 0;
  String? formatId;
  String? filePath;
  String? title;
  String? thumbnail;
  final errors = <String>[];
  final log = <String>[];

  /// What yt-dlp printed, readable and time-stamped ("14:03:22 …"), for
  /// the downloader's log: progress lines only when a stream starts or
  /// ends.
  final output = <String>[];
  final _finishedFormats = <String>{};

  void _out(String text) {
    final t = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    final line = text.length > 500 ? text.substring(0, 500) : text;
    output.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $line');
    if (output.length > maxOutput) output.removeAt(0);
  }

  /// Applies one line. Returns true when the change is worth showing right
  /// away (a new stage, title or thumbnail) rather than with the next
  /// throttled progress update.
  bool apply(String raw) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) return false;
    if (line.startsWith(YtDlpArgs.progressMarker)) {
      _progress(line.substring(YtDlpArgs.progressMarker.length));
      return false;
    }
    if (line.startsWith(YtDlpArgs.postprocessMarker)) {
      final f = line.substring(YtDlpArgs.postprocessMarker.length).split('|');
      final name = f.length > 1 ? f[1].trim() : null;
      if (f.first == 'started' && name != null && name.isNotEmpty && name != 'NA') {
        stage = 'pp:$name';
        _out('[postprocess] $name');
        return true;
      }
      return false;
    }
    if (line.startsWith(YtDlpArgs.fileMarker)) {
      filePath = line.substring(YtDlpArgs.fileMarker.length).trim();
      _out('[saved] $filePath');
      return false;
    }
    if (line.startsWith(YtDlpArgs.titleMarker)) {
      final t = line.substring(YtDlpArgs.titleMarker.length).trim();
      if (t.isEmpty || t == 'NA') return false;
      title = t;
      _out('[title] $t');
      return true;
    }
    if (line.startsWith(YtDlpArgs.thumbnailMarker)) {
      final t = line.substring(YtDlpArgs.thumbnailMarker.length).trim();
      if (!t.startsWith('http')) return false;
      thumbnail = t;
      return true;
    }
    if (line.startsWith('ERROR:')) errors.add(line.substring(6).trim());
    _out(line);
    log.add(line.length > 500 ? line.substring(0, 500) : line);
    if (log.length > 40) log.removeAt(0);
    return false;
  }

  void _progress(String data) {
    final f = data.split('|');
    num? n(int i) => i < f.length ? num.tryParse(f[i].trim()) : null;
    final done = n(1)?.toInt();
    final size = (n(2) ?? n(3))?.toInt();
    final format = f.length > 6 ? f[6].trim() : '';
    if (format.isNotEmpty && format != 'NA' && format != formatId) {
      formatId = format;
      part++;
      _out('[download] Format $format');
    }
    final fragment = n(7);
    final fragments = n(8);
    downloaded = done;
    total = size != null && size > 0 ? size : null;
    speed = n(4)?.toDouble();
    eta = n(5)?.toInt();
    stage = 'download';
    if (f.first == 'finished') {
      percent = 100;
      if (_finishedFormats.add(formatId ?? '')) {
        _out('[download] Done${done == null ? '' : ', $done bytes'}');
      }
    } else if (done != null && total != null) {
      percent = (done * 100 / total!).clamp(0, 100).toDouble();
    } else if (fragment != null && fragments != null && fragments > 0) {
      percent = (fragment * 100 / fragments).clamp(0, 100).toDouble();
    } else {
      percent = null;
    }
  }

  /// The error to show for a failed run.
  String failureMessage(String fallback) => errors.isNotEmpty
      ? YtDlpOutputParser.errorMessage('ERROR: ${errors.last}')
      : fallback;
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

num? _num(Object? v) => switch (v) {
      num() => v,
      String() => num.tryParse(v),
      _ => null,
    };
