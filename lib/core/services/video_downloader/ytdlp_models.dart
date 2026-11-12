import 'dart:convert';

/// Video quality presets: the best stream no taller than [height] (or the
/// smallest one above it when nothing is that small).
enum VideoQuality {
  best(null),
  p2160(2160),
  p1440(1440),
  p1080(1080),
  p720(720),
  p480(480),
  p360(360);

  const VideoQuality(this.height);

  final int? height;

  String get label => height == null ? 'Best' : '${height}p';

  static VideoQuality fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => VideoQuality.best);
}

enum AudioFormat {
  m4a('M4A (AAC)'),
  mp3('MP3');

  const AudioFormat(this.label);

  final String label;

  static AudioFormat fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => AudioFormat.m4a);
}

/// Bitrate of audio-only downloads that FFmpeg converts (`--audio-quality`).
/// [best] keeps the best the site offers, without converting an M4A stream.
enum AudioQuality {
  best(null),
  k320(320),
  k256(256),
  k192(192),
  k160(160),
  k128(128);

  const AudioQuality(this.kbps);

  final int? kbps;

  String get label => kbps == null ? 'Best' : '$kbps kbps';

  static AudioQuality fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => AudioQuality.best);
}

/// Container for merged video+audio.
enum VideoContainer {
  auto('Auto (MP4, else MKV)'),
  mp4('MP4'),
  mkv('MKV');

  const VideoContainer(this.label);

  final String label;

  static VideoContainer fromName(String? name) => values
      .firstWhere((v) => v.name == name, orElse: () => VideoContainer.auto);
}

enum DownloadKind {
  video,
  audio,

  /// An exact format picked from the list.
  format;

  static DownloadKind fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => DownloadKind.video);
}

/// What to download for one item.
class DownloadOptions {
  const DownloadOptions({
    this.kind = DownloadKind.video,
    this.quality = VideoQuality.best,
    this.audioFormat = AudioFormat.m4a,
    this.format,
  });

  final DownloadKind kind;
  final VideoQuality quality;
  final AudioFormat audioFormat;

  /// With [DownloadKind.format].
  final VideoFormat? format;

  DownloadOptions copyWith({
    DownloadKind? kind,
    VideoQuality? quality,
    AudioFormat? audioFormat,
    VideoFormat? format,
  }) =>
      DownloadOptions(
        kind: kind ?? this.kind,
        quality: quality ?? this.quality,
        audioFormat: audioFormat ?? this.audioFormat,
        format: format ?? this.format,
      );

  /// Short description, e.g. "1080p video", "MP3 audio", "Format 137".
  String get label => switch (kind) {
        DownloadKind.video => quality == VideoQuality.best
            ? 'Best video'
            : '${quality.label} video',
        DownloadKind.audio => '${audioFormat.name.toUpperCase()} audio',
        DownloadKind.format => format == null
            ? 'Custom format'
            : 'Format ${format!.id} (${format!.shortLabel})',
      };
}

/// One downloadable format from yt-dlp's `formats` list.
class VideoFormat {
  const VideoFormat({
    required this.id,
    this.ext,
    this.width,
    this.height,
    this.fps,
    this.vcodec,
    this.acodec,
    this.filesize,
    this.filesizeApprox = false,
    this.tbr,
    this.abr,
    this.note,
    this.resolution,
    this.protocol,
    this.videoExt,
    this.audioExt,
  });

  final String id;
  final String? ext;
  final int? width;
  final int? height;
  final double? fps;
  final String? vcodec;
  final String? acodec;

  /// Bytes; an estimate when [filesizeApprox].
  final int? filesize;
  final bool filesizeApprox;

  /// Total bitrate in kbit/s.
  final double? tbr;
  final double? abr;
  final String? note;
  final String? resolution;
  final String? protocol;
  final String? videoExt;
  final String? audioExt;

  factory VideoFormat.fromJson(Map<String, dynamic> j) {
    final size = _int(j['filesize']);
    final approx = _int(j['filesize_approx']);
    return VideoFormat(
      id: '${j['format_id'] ?? ''}',
      ext: _str(j['ext']),
      width: _int(j['width']),
      height: _int(j['height']),
      fps: _double(j['fps']),
      vcodec: _str(j['vcodec']),
      acodec: _str(j['acodec']),
      filesize: size ?? approx,
      filesizeApprox: size == null && approx != null,
      tbr: _double(j['tbr']),
      abr: _double(j['abr']),
      note: _str(j['format_note']),
      resolution: _str(j['resolution']),
      protocol: _str(j['protocol']),
      videoExt: _str(j['video_ext']),
      audioExt: _str(j['audio_ext']),
    );
  }

  /// No video stream (yt-dlp says "none").
  bool get isAudioOnly =>
      vcodec == 'none' ||
      (vcodec == null && videoExt == 'none' && audioExt != null && audioExt != 'none');

  /// No audio stream: needs FFmpeg to merge with an audio format. (Not
  /// `audio_ext`: yt-dlp sets it to "none" for muxed formats too.)
  bool get isVideoOnly => !isAudioOnly && acodec == 'none';

  /// Storyboards/thumbnails (`mhtml`) and other non-media entries.
  bool get isStoryboard =>
      ext == 'mhtml' || (note?.toLowerCase().contains('storyboard') ?? false);

  String get kindLabel => isAudioOnly
      ? 'Audio only'
      : isVideoOnly
          ? 'Video only'
          : 'Video + audio';

  String get shortLabel {
    if (isAudioOnly) {
      final rate = abr ?? tbr;
      return [
        ext ?? 'audio',
        if (rate != null) '${rate.round()}k',
      ].join(' · ');
    }
    final res = height != null ? '${height}p' : (resolution ?? '?');
    return [
      res,
      if (fps != null && fps! > 30) '${fps!.round()}fps',
      ?ext,
    ].join(' · ');
  }

  String? get codecLabel {
    final parts = <String>[
      if (!isAudioOnly && vcodec != null && vcodec != 'none') _codec(vcodec!),
      if (!isVideoOnly && acodec != null && acodec != 'none') _codec(acodec!),
    ];
    return parts.isEmpty ? null : parts.join(' + ');
  }

  static String _codec(String c) {
    final lower = c.toLowerCase();
    if (lower.startsWith('avc1') || lower.startsWith('h264')) return 'H.264';
    if (lower.startsWith('hev1') || lower.startsWith('hvc1') || lower == 'h265') {
      return 'H.265';
    }
    if (lower.startsWith('vp09') || lower == 'vp9') return 'VP9';
    if (lower.startsWith('av01')) return 'AV1';
    if (lower.startsWith('mp4a')) return 'AAC';
    if (lower == 'opus') return 'Opus';
    return c.split('.').first;
  }
}

/// An item of a playlist, from `--flat-playlist` (no formats yet).
class PlaylistEntry {
  const PlaylistEntry({
    required this.index,
    required this.url,
    this.id,
    this.title,
    this.duration,
    this.thumbnail,
    this.uploader,
    this.isNested = false,
  });

  final int index;
  final String url;
  final String? id;
  final String? title;
  final double? duration;
  final String? thumbnail;
  final String? uploader;

  /// A playlist inside the playlist (e.g. a channel's "Videos" tab): it has
  /// to be opened on its own.
  final bool isNested;
}

/// What yt-dlp reports for a link: a single video, or a playlist.
class VideoInfo {
  const VideoInfo({
    required this.url,
    this.id,
    this.title,
    this.uploader,
    this.duration,
    this.thumbnail,
    this.webpageUrl,
    this.extractor,
    this.isPlaylist = false,
    this.isLive = false,
    this.entries = const [],
    this.formats = const [],
    this.playlistCount,
  });

  /// The link that was fetched.
  final String url;
  final String? id;
  final String? title;
  final String? uploader;
  final double? duration;
  final String? thumbnail;
  final String? webpageUrl;
  final String? extractor;
  final bool isPlaylist;
  final bool isLive;
  final List<PlaylistEntry> entries;
  final List<VideoFormat> formats;
  final int? playlistCount;

  /// The URL to hand to yt-dlp for the download.
  String get downloadUrl => webpageUrl ?? url;

  /// Heights available among the video formats, tallest first.
  List<int> get videoHeights {
    final heights = <int>{
      for (final f in formats)
        if (!f.isAudioOnly && !f.isStoryboard && f.height != null) f.height!,
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    return heights;
  }

  bool get hasAudioFormats => formats.any((f) => f.isAudioOnly);

  /// Formats worth showing in a picker (no storyboards), best first.
  List<VideoFormat> get pickableFormats =>
      formats.where((f) => !f.isStoryboard).toList().reversed.toList();
}

/// State of a download job.
enum JobStatus {
  queued,
  running,
  done,
  failed,
  cancelled;

  static JobStatus fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => JobStatus.failed);
}

/// A snapshot of a download job, as reported by the platform backend.
class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.url,
    required this.status,
    required this.createdAt,
    this.title,
    this.thumbnail,
    this.outputDir,
    this.workDir,
    this.meta = const {},
    this.percent,
    this.downloaded,
    this.total,
    this.speed,
    this.eta,
    this.stage,
    this.part = 0,
    this.filePath,
    this.error,
    this.log,
    this.output,
    this.finishedAt,
  });

  final String id;
  final String url;
  final JobStatus status;
  final DateTime createdAt;
  final String? title;
  final String? thumbnail;
  final String? outputDir;
  final String? workDir;

  /// Free-form details kept with the job (kind, extractor, duration…).
  final Map<String, dynamic> meta;

  /// 0–100, null when unknown.
  final double? percent;
  final int? downloaded;
  final int? total;

  /// Bytes per second.
  final double? speed;

  /// Seconds left.
  final int? eta;

  /// `download`, or `pp:` plus the post-processor, e.g. `pp:Merger`.
  final String? stage;

  /// Which stream is downloading (video, then audio, for merged formats).
  final int part;
  final String? filePath;
  final String? error;
  final String? log;

  /// What yt-dlp printed, each line with the time it came (once the job has
  /// ended), for the downloader's log.
  final String? output;
  final DateTime? finishedAt;

  bool get isActive => status == JobStatus.queued || status == JobStatus.running;

  bool get isPostProcessing => stage?.startsWith('pp:') ?? false;

  String get displayTitle => (title?.isNotEmpty ?? false) ? title! : url;

  factory DownloadJob.fromMap(Map<dynamic, dynamic> m) {
    final percent = _double(m['percent']);
    final metaRaw = m['meta'];
    Map<String, dynamic> meta = const {};
    if (metaRaw is String && metaRaw.isNotEmpty) {
      try {
        meta = (jsonDecode(metaRaw) as Map).cast<String, dynamic>();
      } catch (_) {}
    } else if (metaRaw is Map) {
      meta = metaRaw.cast<String, dynamic>();
    }
    return DownloadJob(
      id: '${m['id']}',
      url: '${m['url'] ?? ''}',
      status: JobStatus.fromName(m['status'] as String?),
      createdAt: _date(m['createdAt']) ?? DateTime.now(),
      title: _str(m['title']),
      thumbnail: _str(m['thumbnail']),
      outputDir: _str(m['outputDir']),
      workDir: _str(m['workDir']),
      meta: meta,
      percent: percent == null || percent < 0 ? null : percent.clamp(0, 100),
      downloaded: _int(m['downloaded']),
      total: _int(m['total']),
      speed: _double(m['speed']),
      eta: _int(m['eta']),
      stage: _str(m['stage']),
      part: _int(m['part']) ?? 0,
      filePath: _str(m['filePath']),
      error: _str(m['error']),
      log: _str(m['log']),
      output: _str(m['output']),
      finishedAt: _date(m['finishedAt']),
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'url': url,
        'status': status.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'title': title,
        'thumbnail': thumbnail,
        'outputDir': outputDir,
        'workDir': workDir,
        'meta': jsonEncode(meta),
        'percent': percent ?? -1.0,
        'downloaded': downloaded,
        'total': total,
        'speed': speed,
        'eta': eta,
        'stage': stage,
        'part': part,
        'filePath': filePath,
        'error': error,
        'log': log,
        'output': output,
        'finishedAt': finishedAt?.millisecondsSinceEpoch,
      };
}

/// What the platform needs to start a job.
class JobSpec {
  const JobSpec({
    required this.id,
    required this.url,
    required this.args,
    required this.outputDir,
    required this.workDir,
    this.title,
    this.thumbnail,
    this.meta = const {},
    this.cookieFile,
  });

  final String id;
  final String url;

  /// yt-dlp options, without the URL.
  final List<String> args;
  final String outputDir;
  final String workDir;
  final String? title;
  final String? thumbnail;
  final Map<String, dynamic> meta;

  /// The cookies to send (Netscape format), when the user has some. The
  /// backend gives each run its own copy, as yt-dlp writes the file back
  /// when it ends.
  final String? cookieFile;

  Map<String, Object?> toMap() => {
        'id': id,
        'url': url,
        'args': args,
        'cookieFile': cookieFile,
        'outputDir': outputDir,
        'workDir': workDir,
        'title': title,
        'thumbnail': thumbnail,
        'meta': jsonEncode(meta),
      };
}

/// A finished download kept in the history.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.title,
    required this.url,
    required this.filePath,
    required this.completedAt,
    this.thumbnail,
    this.kind,
    this.sizeBytes,
    this.extractor,
    this.duration,
    this.playlist,
  });

  final String id;
  final String title;
  final String url;
  final String filePath;
  final DateTime completedAt;
  final String? thumbnail;

  /// "video" or "audio".
  final String? kind;
  final int? sizeBytes;
  final String? extractor;
  final double? duration;

  /// The playlist it was downloaded from, if any.
  final String? playlist;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        id: '${j['id']}',
        title: '${j['title'] ?? ''}',
        url: '${j['url'] ?? ''}',
        filePath: '${j['filePath'] ?? ''}',
        completedAt: _date(j['completedAt']) ?? DateTime.now(),
        thumbnail: _str(j['thumbnail']),
        kind: _str(j['kind']),
        sizeBytes: _int(j['sizeBytes']),
        extractor: _str(j['extractor']),
        duration: _double(j['duration']),
        playlist: _str(j['playlist']),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'filePath': filePath,
        'completedAt': completedAt.millisecondsSinceEpoch,
        'thumbnail': thumbnail,
        'kind': kind,
        'sizeBytes': sizeBytes,
        'extractor': extractor,
        'duration': duration,
        'playlist': playlist,
      };
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

int? _int(Object? v) => switch (v) {
      int() => v,
      double() => v.isFinite ? v.round() : null,
      String() => int.tryParse(v) ?? double.tryParse(v)?.round(),
      _ => null,
    };

double? _double(Object? v) => switch (v) {
      double() => v.isFinite ? v : null,
      int() => v.toDouble(),
      String() => double.tryParse(v),
      _ => null,
    };

DateTime? _date(Object? v) {
  final ms = _int(v);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}
