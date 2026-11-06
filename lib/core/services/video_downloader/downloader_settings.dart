import 'ytdlp_models.dart';

/// User preferences for the video downloader.
class DownloaderSettings {
  const DownloaderSettings({
    this.outputDir,
    this.defaultKind = DownloadKind.video,
    this.defaultQuality = VideoQuality.best,
    this.audioFormat = AudioFormat.m4a,
    this.container = VideoContainer.auto,
    this.filenameTemplate = defaultFilenameTemplate,
    this.subtitles = false,
    this.subtitleLangs = 'en.*',
    this.autoSubtitles = false,
    this.embedThumbnail = true,
    this.embedMetadata = true,
    this.embedChapters = true,
    this.preferCompatible = true,
    this.playlistFolder = true,
    this.autoUpdate = true,
  });

  /// yt-dlp output template for file names. `.150B` caps the title at 150
  /// bytes so names stay under the 255-byte limit of most file systems.
  static const defaultFilenameTemplate = '%(title).150B [%(id)s].%(ext)s';

  /// Null: the platform default (Download/Folders Videos).
  final String? outputDir;
  final DownloadKind defaultKind;
  final VideoQuality defaultQuality;
  final AudioFormat audioFormat;
  final VideoContainer container;
  final String filenameTemplate;
  final bool subtitles;

  /// yt-dlp `--sub-langs`, e.g. "en.*,de".
  final String subtitleLangs;

  /// Also take automatic captions.
  final bool autoSubtitles;
  final bool embedThumbnail;
  final bool embedMetadata;
  final bool embedChapters;

  /// Prefer H.264 video and AAC audio, which play everywhere.
  final bool preferCompatible;

  /// Save playlist items in a folder named after the playlist.
  final bool playlistFolder;

  /// Check for a new yt-dlp at most once a day.
  final bool autoUpdate;

  /// The template to pass to yt-dlp, with an extension if it lacks one.
  String get effectiveTemplate {
    final t = filenameTemplate.trim();
    if (t.isEmpty) return defaultFilenameTemplate;
    return t.contains('%(ext)') ? t : '$t.%(ext)s';
  }

  DownloadOptions get defaultOptions => DownloadOptions(
        kind: defaultKind == DownloadKind.format
            ? DownloadKind.video
            : defaultKind,
        quality: defaultQuality,
        audioFormat: audioFormat,
      );

  DownloaderSettings copyWith({
    String? outputDir,
    bool resetOutputDir = false,
    DownloadKind? defaultKind,
    VideoQuality? defaultQuality,
    AudioFormat? audioFormat,
    VideoContainer? container,
    String? filenameTemplate,
    bool? subtitles,
    String? subtitleLangs,
    bool? autoSubtitles,
    bool? embedThumbnail,
    bool? embedMetadata,
    bool? embedChapters,
    bool? preferCompatible,
    bool? playlistFolder,
    bool? autoUpdate,
  }) =>
      DownloaderSettings(
        outputDir: resetOutputDir ? null : (outputDir ?? this.outputDir),
        defaultKind: defaultKind ?? this.defaultKind,
        defaultQuality: defaultQuality ?? this.defaultQuality,
        audioFormat: audioFormat ?? this.audioFormat,
        container: container ?? this.container,
        filenameTemplate: filenameTemplate ?? this.filenameTemplate,
        subtitles: subtitles ?? this.subtitles,
        subtitleLangs: subtitleLangs ?? this.subtitleLangs,
        autoSubtitles: autoSubtitles ?? this.autoSubtitles,
        embedThumbnail: embedThumbnail ?? this.embedThumbnail,
        embedMetadata: embedMetadata ?? this.embedMetadata,
        embedChapters: embedChapters ?? this.embedChapters,
        preferCompatible: preferCompatible ?? this.preferCompatible,
        playlistFolder: playlistFolder ?? this.playlistFolder,
        autoUpdate: autoUpdate ?? this.autoUpdate,
      );

  factory DownloaderSettings.fromJson(Map<String, dynamic> j) {
    const d = DownloaderSettings();
    bool b(String key, bool fallback) => j[key] is bool ? j[key] as bool : fallback;
    return DownloaderSettings(
      outputDir: j['outputDir'] is String && (j['outputDir'] as String).isNotEmpty
          ? j['outputDir'] as String
          : null,
      defaultKind: DownloadKind.fromName(j['defaultKind'] as String?),
      defaultQuality: VideoQuality.fromName(j['defaultQuality'] as String?),
      audioFormat: AudioFormat.fromName(j['audioFormat'] as String?),
      container: VideoContainer.fromName(j['container'] as String?),
      filenameTemplate: j['filenameTemplate'] is String
          ? j['filenameTemplate'] as String
          : d.filenameTemplate,
      subtitles: b('subtitles', d.subtitles),
      subtitleLangs: j['subtitleLangs'] is String
          ? j['subtitleLangs'] as String
          : d.subtitleLangs,
      autoSubtitles: b('autoSubtitles', d.autoSubtitles),
      embedThumbnail: b('embedThumbnail', d.embedThumbnail),
      embedMetadata: b('embedMetadata', d.embedMetadata),
      embedChapters: b('embedChapters', d.embedChapters),
      preferCompatible: b('preferCompatible', d.preferCompatible),
      playlistFolder: b('playlistFolder', d.playlistFolder),
      autoUpdate: b('autoUpdate', d.autoUpdate),
    );
  }

  Map<String, Object?> toJson() => {
        'outputDir': outputDir,
        'defaultKind': defaultKind.name,
        'defaultQuality': defaultQuality.name,
        'audioFormat': audioFormat.name,
        'container': container.name,
        'filenameTemplate': filenameTemplate,
        'subtitles': subtitles,
        'subtitleLangs': subtitleLangs,
        'autoSubtitles': autoSubtitles,
        'embedThumbnail': embedThumbnail,
        'embedMetadata': embedMetadata,
        'embedChapters': embedChapters,
        'preferCompatible': preferCompatible,
        'playlistFolder': playlistFolder,
        'autoUpdate': autoUpdate,
      };
}
