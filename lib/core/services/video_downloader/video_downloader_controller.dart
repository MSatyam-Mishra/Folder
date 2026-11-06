import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloader_backend.dart';
import 'downloader_settings.dart';
import 'ytdlp_args.dart';
import 'ytdlp_models.dart';
import 'ytdlp_output.dart';

enum EngineState { idle, preparing, ready, failed, unsupported }

/// App-wide state of the video downloader: settings, history, the job queue
/// and the yt-dlp engine. One instance for the app's lifetime, so screens
/// can come and go while downloads run.
class VideoDownloaderController extends ChangeNotifier {
  VideoDownloaderController(this.backend);

  static VideoDownloaderController? _instance;

  static VideoDownloaderController get instance =>
      _instance ??= VideoDownloaderController(VideoDownloaderBackend.forPlatform());

  @visibleForTesting
  static set instance(VideoDownloaderController value) => _instance = value;

  static const _kSettings = 'video_downloader.settings.v1';
  static const _kHistory = 'video_downloader.history.v1';
  static const _kRights = 'video_downloader.rights_accepted';
  static const _kLastUpdate = 'video_downloader.last_update_check';
  static const _kNotificationsAsked = 'video_downloader.notifications_asked';
  static const _maxHistory = 500;

  final VideoDownloaderBackend backend;
  SharedPreferences? _prefs;
  StreamSubscription<BackendEvent>? _events;
  Future<void>? _starting;
  Future<void>? _preparing;
  Future<void>? _updateRun;
  String? _fetchId;
  final _completing = <String>{};
  final _completed = StreamController<HistoryEntry>.broadcast();

  DownloaderSettings settings = const DownloaderSettings();
  List<HistoryEntry> history = [];
  final Map<String, DownloadJob> _jobs = {};

  EngineState engineState = EngineState.idle;
  String? engineMessage;
  double? engineProgress;
  String? engineError;
  BackendStatus? backendStatus;
  BackendPaths? backendPaths;
  String? ytDlpVersion;
  bool updating = false;
  DateTime? lastUpdateCheck;
  bool rightsAccepted = false;
  bool _engineAllowed = false;

  /// Each download that finished, once added to [history].
  Stream<HistoryEntry> get completed => _completed.stream;

  bool get isSupported => backend.unsupportedReason == null;

  String? get unsupportedReason => backend.unsupportedReason;

  bool get hasFfmpeg => backendStatus?.hasFfmpeg ?? false;

  bool get needsSetup => backendStatus?.needsSetup ?? false;

  /// The engine to download first (Android), if the backend has one.
  EngineInfo? get engine => backendStatus?.engine;

  /// Nothing can be downloaded until the engine is: ask the user, then
  /// call [installEngine].
  bool get engineMissing => engine != null && !engine!.installed;

  /// The user agreed to download the engine in this session.
  bool get engineAllowed => _engineAllowed;

  /// Where downloads are saved.
  String get outputDir => settings.outputDir ?? backendPaths?.defaultOutputDir ?? '';

  List<DownloadJob> get jobs =>
      _jobs.values.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  int get activeCount => _jobs.values.where((j) => j.isActive).length;

  Future<void> start() => _starting ??= _start();

  /// [start] ran: the downloader was opened in this session.
  bool get isStarted => _starting != null;

  Future<void> _start() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_kSettings);
      if (raw != null) {
        settings = DownloaderSettings.fromJson((jsonDecode(raw) as Map).cast());
      }
    } catch (_) {}
    try {
      final raw = prefs.getString(_kHistory);
      if (raw != null) {
        history = [
          for (final e in jsonDecode(raw) as List)
            if (e is Map) HistoryEntry.fromJson(e.cast()),
        ];
      }
    } catch (_) {}
    rightsAccepted = prefs.getBool(_kRights) ?? false;
    final last = prefs.getInt(_kLastUpdate);
    lastUpdateCheck = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    if (!isSupported) {
      engineState = EngineState.unsupported;
      notifyListeners();
      return;
    }
    _events = backend.events.listen(_onEvent);
    try {
      backendStatus = await backend.status();
      backendPaths = await backend.paths();
      for (final job in await backend.jobs()) {
        _jobs[job.id] = job;
      }
      // Jobs that finished while the app was closed.
      for (final job in await backend.takeFinished()) {
        _jobs[job.id] = job;
      }
      for (final job in _jobs.values.toList()) {
        if (job.status == JobStatus.done) unawaited(_complete(job));
      }
    } catch (e) {
      engineError = '$e';
    }
    notifyListeners();
  }

  /// Sets up yt-dlp if needed (the first time: unpack or download it).
  /// Throws [EngineMissingException] while the engine is missing and the
  /// user hasn't agreed to download it ([installEngine]).
  Future<void> ensureReady() async {
    await start();
    if (engineState == EngineState.ready) return;
    if (engineState == EngineState.unsupported) {
      throw DownloaderException(unsupportedReason ?? 'Not supported');
    }
    if (engineMissing && !_engineAllowed) throw const EngineMissingException();
    await (_preparing ??= _prepare().whenComplete(() => _preparing = null));
  }

  /// Downloads the engine (the user agreed) and sets the downloader up.
  Future<void> installEngine() async {
    _engineAllowed = true;
    await ensureReady();
  }

  /// Stops the engine download; the next [installEngine] continues it.
  Future<void> cancelEngineInstall() => backend.cancelPrepare();

  /// Deletes the engine to free its storage; it must be downloaded again
  /// before the next download.
  Future<void> removeEngine() async {
    await backend.removeEngine();
    _engineAllowed = false;
    engineState = EngineState.idle;
    engineError = null;
    ytDlpVersion = null;
    backendStatus = await backend.status();
    notifyListeners();
  }

  Future<void> _prepare() async {
    final firstTime = needsSetup;
    engineState = EngineState.preparing;
    engineError = null;
    engineProgress = null;
    engineMessage = engineMissing
        ? 'Downloading the video engine…'
        : firstTime
        ? 'Preparing downloader…'
        : 'Starting downloader…';
    notifyListeners();
    try {
      await backend.prepare(onProgress: (progress, message) {
        engineProgress = progress;
        engineMessage = message;
        notifyListeners();
      });
      backendStatus = await backend.status();
      engineState = EngineState.ready;
      engineMessage = null;
      if (firstTime && !Platform.isAndroid) {
        // Just downloaded the latest release.
        await _setLastUpdateCheck(DateTime.now());
      }
      notifyListeners();
      unawaited(refreshVersion());
      unawaited(_maybeAutoUpdate());
    } catch (e) {
      final cancelled = e is DownloaderException && e.cancelled;
      // Cancelled: back to asking before the next download.
      if (cancelled) _engineAllowed = false;
      engineState = cancelled ? EngineState.idle : EngineState.failed;
      engineError = cancelled ? null : (e is DownloaderException ? e.message : '$e');
      engineMessage = null;
      engineProgress = null;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> refreshVersion() async {
    try {
      ytDlpVersion = await backend.version();
      notifyListeners();
    } catch (_) {}
  }

  /// Fetches what [url] offers. Cancel with [cancelFetch].
  Future<VideoInfo> fetchInfo(String url) async {
    await ensureReady();
    final pendingUpdate = _updateRun;
    if (pendingUpdate != null) await pendingUpdate.catchError((Object _) {});
    final id = 'info-${DateTime.now().microsecondsSinceEpoch}';
    _fetchId = id;
    try {
      final json = await backend.fetchInfoJson(url, requestId: id);
      return await _parseInfo(json, url);
    } on FormatException catch (e) {
      throw DownloaderException("yt-dlp's answer couldn't be read (${e.message}).");
    } finally {
      if (_fetchId == id) _fetchId = null;
    }
  }

  /// Large answers (long playlists, YouTube's ~1 MB of formats) are parsed
  /// in an isolate so the UI doesn't stutter. Static, so the isolate's
  /// closure captures only the two strings.
  static Future<VideoInfo> _parseInfo(String json, String url) async {
    if (json.length < 256 * 1024) return YtDlpOutputParser.parseInfo(json, url: url);
    return Isolate.run(() => YtDlpOutputParser.parseInfo(json, url: url));
  }

  Future<void> cancelFetch() async {
    final id = _fetchId;
    if (id != null) await backend.cancelFetch(id);
  }

  /// Queues [info] (or the chosen playlist [entries]). Returns how many
  /// jobs were added.
  Future<int> download(
    VideoInfo info, {
    required DownloadOptions options,
    List<PlaylistEntry>? entries,
  }) async {
    await _beforeEnqueue();
    if (info.isPlaylist) {
      final picked = entries ?? info.entries.where((e) => !e.isNested).toList();
      final folder = settings.playlistFolder
          ? p.join(outputDir, safeFileName(info.title ?? 'Playlist'))
          : outputDir;
      // An exact format belongs to one video; use the preset for the rest.
      final itemOptions = options.kind == DownloadKind.format
          ? options.copyWith(kind: DownloadKind.video)
          : options;
      for (final entry in picked) {
        await _enqueue(
          url: entry.url,
          title: entry.title,
          thumbnail: entry.thumbnail,
          options: itemOptions,
          outputDir: folder,
          meta: {
            'extractor': info.extractor,
            'duration': entry.duration,
            'playlist': info.title,
          },
        );
      }
      return picked.length;
    }
    await _enqueue(
      url: info.downloadUrl,
      title: info.title,
      thumbnail: info.thumbnail,
      options: options,
      outputDir: outputDir,
      meta: {'extractor': info.extractor, 'duration': info.duration},
    );
    return 1;
  }

  /// Queues several links with the default options, without fetching them
  /// first.
  Future<int> downloadUrls(List<String> urls) async {
    await _beforeEnqueue();
    for (final url in urls) {
      await _enqueue(
        url: url,
        options: settings.defaultOptions,
        outputDir: outputDir,
        meta: const {},
      );
    }
    return urls.length;
  }

  Future<void> _beforeEnqueue() async {
    await ensureReady();
    await _askNotificationPermission();
    if (!await backend.canWrite(outputDir)) {
      throw DownloaderException(
        "Folders can't save files in $outputDir. Choose another folder in "
        'the downloader settings${Platform.isAndroid ? ', or allow Folders to manage all files' : ''}.',
      );
    }
  }

  Future<void> _enqueue({
    required String url,
    required DownloadOptions options,
    required String outputDir,
    required Map<String, dynamic> meta,
    String? title,
    String? thumbnail,
  }) async {
    final id = _newId();
    // Android: partial files next to the output (same file system, so the
    // finished file is renamed, not copied across mounts). Desktop: temp.
    final workDir = Platform.isAndroid
        ? p.join(this.outputDir, androidWorkFolder, id)
        : p.join(
            backendPaths?.workRoot ?? p.join(Directory.systemTemp.path, 'explorer_video_work'),
            id,
          );
    final audio = options.kind == DownloadKind.audio ||
        (options.kind == DownloadKind.format && (options.format?.isAudioOnly ?? false));
    final spec = JobSpec(
      id: id,
      url: url,
      title: title,
      thumbnail: thumbnail,
      outputDir: outputDir,
      workDir: workDir,
      args: YtDlpArgs.download(
        options: options,
        settings: settings,
        hasFfmpeg: hasFfmpeg,
        outputDir: outputDir,
        workDir: workDir,
      ),
      meta: {
        ...meta,
        'kind': audio ? 'audio' : 'video',
        'label': options.label,
      }..removeWhere((_, v) => v == null),
    );
    await backend.enqueue(spec);
  }

  /// Hidden folder (with a .nomedia file) for partial downloads on Android.
  static const androidWorkFolder = '.explorer-tmp';

  static final _random = Random();

  static String _newId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${_random.nextInt(1 << 30).toRadixString(36)}';

  Future<void> cancel(String id) => backend.cancel(id);

  Future<void> retry(String id) async {
    await ensureReady();
    await backend.retry(id);
  }

  /// Removes a job from the queue (cancelling it if it runs).
  Future<void> dismiss(String id) => backend.remove(id);

  Future<void> clearFinishedJobs() async {
    for (final job in jobs.where((j) => !j.isActive)) {
      await backend.remove(job.id);
    }
  }

  void _onEvent(BackendEvent event) {
    switch (event) {
      case JobChanged(:final job):
        _jobs[job.id] = job;
        if (job.status == JobStatus.done) unawaited(_complete(job));
      case JobRemoved(:final id):
        _jobs.remove(id);
      case SetupProgress():
        return; // [_prepare] gets it through prepare's onProgress.
    }
    notifyListeners();
  }

  /// Moves a finished job into the history.
  Future<void> _complete(DownloadJob job) async {
    if (!_completing.add(job.id)) return;
    final path = job.filePath;
    if (path == null) {
      // Nothing to open; leave it in the queue as finished.
      await backend.ackFinished([job.id]);
      return;
    }
    if (!history.any((h) => h.id == job.id)) {
      int? size;
      try {
        size = await File(path).length();
      } catch (_) {}
      final duration = job.meta['duration'];
      final entry = HistoryEntry(
        id: job.id,
        title: job.title ?? p.basenameWithoutExtension(path),
        url: job.url,
        filePath: path,
        completedAt: job.finishedAt ?? DateTime.now(),
        thumbnail: job.thumbnail,
        kind: job.meta['kind'] as String?,
        sizeBytes: size,
        extractor: job.meta['extractor'] as String?,
        duration: duration is num ? duration.toDouble() : null,
        playlist: job.meta['playlist'] as String?,
      );
      history.insert(0, entry);
      if (history.length > _maxHistory) history.removeRange(_maxHistory, history.length);
      await _saveHistory();
      _completed.add(entry);
    }
    await backend.ackFinished([job.id]);
    await backend.remove(job.id);
    _jobs.remove(job.id);
    notifyListeners();
  }

  Future<void> removeHistory(HistoryEntry entry, {bool deleteFile = false}) async {
    history.removeWhere((h) => h.id == entry.id);
    notifyListeners();
    await _saveHistory();
    if (deleteFile) {
      final file = File(entry.filePath);
      if (await file.exists()) await file.delete();
      await backend.fileDeleted(entry.filePath).catchError((Object _) {});
    }
  }

  /// Removes [entries] (e.g. a playlist's) from the history; the files stay.
  Future<void> removeHistoryEntries(Iterable<HistoryEntry> entries) async {
    final ids = {for (final e in entries) e.id};
    history.removeWhere((h) => ids.contains(h.id));
    notifyListeners();
    await _saveHistory();
  }

  Future<void> clearHistory() async {
    history = [];
    notifyListeners();
    await _saveHistory();
  }

  Future<void> _saveHistory() async {
    await _prefs?.setString(
        _kHistory, jsonEncode([for (final h in history) h.toJson()]));
  }

  Future<void> updateSettings(DownloaderSettings value) async {
    settings = value;
    notifyListeners();
    await _prefs?.setString(_kSettings, jsonEncode(value.toJson()));
  }

  Future<void> acceptRights() async {
    rightsAccepted = true;
    notifyListeners();
    await _prefs?.setBool(_kRights, true);
  }

  /// Updates yt-dlp to the latest stable release.
  Future<UpdateResult> updateYtDlp() async {
    final running = _updateRun;
    if (running != null) {
      await running;
      return UpdateResult(updated: false, version: ytDlpVersion);
    }
    // Set before the first await, so a fetch that starts meanwhile waits:
    // yt-dlp fails if its file is replaced while it runs.
    final done = Completer<void>();
    _updateRun = done.future;
    updating = true;
    notifyListeners();
    try {
      await ensureReady();
      final result = await backend.update();
      if (result.version != null) ytDlpVersion = result.version;
      await _setLastUpdateCheck(DateTime.now());
      return result;
    } finally {
      updating = false;
      _updateRun = null;
      done.complete();
      notifyListeners();
    }
  }

  Future<void> _maybeAutoUpdate() async {
    if (!settings.autoUpdate || activeCount > 0) return;
    final last = lastUpdateCheck;
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) {
      return;
    }
    try {
      await updateYtDlp();
    } catch (e) {
      debugPrint('yt-dlp auto-update failed: $e');
    }
  }

  Future<void> _setLastUpdateCheck(DateTime time) async {
    lastUpdateCheck = time;
    await _prefs?.setInt(_kLastUpdate, time.millisecondsSinceEpoch);
  }

  /// Android 13+: ask once to show download progress notifications.
  Future<void> _askNotificationPermission() async {
    if (!Platform.isAndroid || (_prefs?.getBool(_kNotificationsAsked) ?? false)) return;
    await _prefs?.setBool(_kNotificationsAsked, true);
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (_) {}
  }

  /// [name] made safe as a folder name on every platform.
  static String safeFileName(String name) {
    var s = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    s = s.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
    if (s.length > 100) s = s.substring(0, 100).trim();
    return s.isEmpty ? 'Playlist' : s;
  }

  @override
  void dispose() {
    _events?.cancel();
    _completed.close();
    super.dispose();
  }
}
