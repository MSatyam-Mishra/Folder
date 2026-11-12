import 'ytdlp_models.dart';

/// The User-Agent yt-dlp sends (`--user-agent`): yt-dlp's own, a few common
/// browsers, or the user's text.
enum UserAgentPreset {
  system('System default', null),
  chromeDesktop(
    'Chrome on a computer',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36',
  ),
  chromeMobile(
    'Chrome on a phone',
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
  ),
  firefox(
    'Firefox on a computer',
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:143.0) Gecko/20100101 '
        'Firefox/143.0',
  ),
  custom('Custom', null);

  const UserAgentPreset(this.label, this.value);

  final String label;

  /// The header's text; null for [system] and [custom].
  final String? value;

  static UserAgentPreset fromName(String? name) => values
      .firstWhere((v) => v.name == name, orElse: () => UserAgentPreset.system);
}

/// User preferences for the video downloader.
class DownloaderSettings {
  const DownloaderSettings({
    this.outputDir,
    this.defaultKind = DownloadKind.video,
    this.defaultQuality = VideoQuality.best,
    this.audioFormat = AudioFormat.m4a,
    this.audioQuality = AudioQuality.best,
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
    this.maxConcurrent = defaultConcurrent,
    this.notifications = true,
    this.userAgent = UserAgentPreset.system,
    this.customUserAgent = '',
  });

  /// yt-dlp output template for file names. `.150B` caps the title at 150
  /// bytes so names stay under the 255-byte limit of most file systems.
  static const defaultFilenameTemplate = '%(title).150B [%(id)s].%(ext)s';

  static const defaultConcurrent = 2;
  static const minConcurrent = 1;
  static const maxConcurrentLimit = 5;

  /// Null: the platform default (Download/Folders Videos).
  final String? outputDir;
  final DownloadKind defaultKind;
  final VideoQuality defaultQuality;
  final AudioFormat audioFormat;

  /// Bitrate of audio-only downloads.
  final AudioQuality audioQuality;
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

  /// Most downloads that run at once ([minConcurrent]–[maxConcurrentLimit]).
  final int maxConcurrent;

  /// Android: progress and finished downloads in the notification shade.
  /// Computers: the message when a download finishes.
  final bool notifications;

  final UserAgentPreset userAgent;

  /// With [UserAgentPreset.custom].
  final String customUserAgent;

  /// The template to pass to yt-dlp, with an extension if it lacks one.
  String get effectiveTemplate {
    final t = filenameTemplate.trim();
    if (t.isEmpty) return defaultFilenameTemplate;
    return t.contains('%(ext)') ? t : '$t.%(ext)s';
  }

  /// The User-Agent to send, or null for yt-dlp's own. A custom one loses
  /// line breaks and other control characters, which would end the header.
  String? get effectiveUserAgent {
    if (userAgent != UserAgentPreset.custom) return userAgent.value;
    final text = customUserAgent
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
    return text.isEmpty ? null : text;
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
    AudioQuality? audioQuality,
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
    int? maxConcurrent,
    bool? notifications,
    UserAgentPreset? userAgent,
    String? customUserAgent,
  }) =>
      DownloaderSettings(
        outputDir: resetOutputDir ? null : (outputDir ?? this.outputDir),
        defaultKind: defaultKind ?? this.defaultKind,
        defaultQuality: defaultQuality ?? this.defaultQuality,
        audioFormat: audioFormat ?? this.audioFormat,
        audioQuality: audioQuality ?? this.audioQuality,
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
        maxConcurrent: _concurrent(maxConcurrent ?? this.maxConcurrent),
        notifications: notifications ?? this.notifications,
        userAgent: userAgent ?? this.userAgent,
        customUserAgent: customUserAgent ?? this.customUserAgent,
      );

  static int _concurrent(int value) =>
      value.clamp(minConcurrent, maxConcurrentLimit);

  /// Settings saved by an older version lack the newer keys: those get
  /// their defaults.
  factory DownloaderSettings.fromJson(Map<String, dynamic> j) {
    const d = DownloaderSettings();
    bool b(String key, bool fallback) => j[key] is bool ? j[key] as bool : fallback;
    String s(String key, String fallback) => j[key] is String ? j[key] as String : fallback;
    final concurrent = j['maxConcurrent'];
    return DownloaderSettings(
      outputDir: j['outputDir'] is String && (j['outputDir'] as String).isNotEmpty
          ? j['outputDir'] as String
          : null,
      defaultKind: DownloadKind.fromName(j['defaultKind'] as String?),
      defaultQuality: VideoQuality.fromName(j['defaultQuality'] as String?),
      audioFormat: AudioFormat.fromName(j['audioFormat'] as String?),
      audioQuality: AudioQuality.fromName(j['audioQuality'] as String?),
      container: VideoContainer.fromName(j['container'] as String?),
      filenameTemplate: s('filenameTemplate', d.filenameTemplate),
      subtitles: b('subtitles', d.subtitles),
      subtitleLangs: s('subtitleLangs', d.subtitleLangs),
      autoSubtitles: b('autoSubtitles', d.autoSubtitles),
      embedThumbnail: b('embedThumbnail', d.embedThumbnail),
      embedMetadata: b('embedMetadata', d.embedMetadata),
      embedChapters: b('embedChapters', d.embedChapters),
      preferCompatible: b('preferCompatible', d.preferCompatible),
      playlistFolder: b('playlistFolder', d.playlistFolder),
      autoUpdate: b('autoUpdate', d.autoUpdate),
      maxConcurrent: concurrent is num ? _concurrent(concurrent.toInt()) : d.maxConcurrent,
      notifications: b('notifications', d.notifications),
      userAgent: UserAgentPreset.fromName(j['userAgent'] as String?),
      customUserAgent: s('customUserAgent', d.customUserAgent),
    );
  }

  Map<String, Object?> toJson() => {
        'outputDir': outputDir,
        'defaultKind': defaultKind.name,
        'defaultQuality': defaultQuality.name,
        'audioFormat': audioFormat.name,
        'audioQuality': audioQuality.name,
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
        'maxConcurrent': maxConcurrent,
        'notifications': notifications,
        'userAgent': userAgent.name,
        'customUserAgent': customUserAgent,
      };
}
