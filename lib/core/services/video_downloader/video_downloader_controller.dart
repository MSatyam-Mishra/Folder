import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cookie_store.dart';
import 'downloader_backend.dart';
import 'downloader_log.dart';
import 'downloader_settings.dart';
import 'netscape_cookies.dart';
import 'ytdlp_args.dart';
import 'ytdlp_models.dart';
import 'ytdlp_output.dart';

enum EngineState { idle, preparing, ready, failed, unsupported }

/// App-wide state of the video downloader: settings, history, the job queue
/// and the yt-dlp engine. One instance for the app's lifetime, so screens
/// can come and go while downloads run.
class VideoDownloaderController extends ChangeNotifier {
  /// [dataDirectory] gives the folder for cookies and the log; without it
  /// (tests) they're kept in memory only.
  VideoDownloaderController(this.backend, {Future<Directory?> Function()? dataDirectory})
      : _dataDirectory = dataDirectory;

  static VideoDownloaderController? _instance;

  static VideoDownloaderController get instance => _instance ??= VideoDownloaderController(
        VideoDownloaderBackend.forPlatform(),
        dataDirectory: appDataDirectory,
      );

  /// The downloader's folder in app-private storage.
  static Future<Directory?> appDataDirectory() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'video_downloader'));

  @visibleForTesting
  static set instance(VideoDownloaderController value) => _instance = value;

  static const _kSettings = 'video_downloader.settings.v1';
  static const _kHistory = 'video_downloader.history.v1';
  static const _kRights = 'video_downloader.rights_accepted';
  static const _kLastUpdate = 'video_downloader.last_update_check';
  static const _kNotificationsAsked = 'video_downloader.notifications_asked';
  static const _maxHistory = 500;

  final VideoDownloaderBackend backend;
  final Future<Directory?> Function()? _dataDirectory;

  /// Imported cookies and site sign-ins, passed to yt-dlp.
  final cookies = CookieStore();

  /// What the downloader did; cookie values are hidden.
  late final log = DownloaderLog(redact: cookies.redact);
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
    Directory? data;
    try {
      data = await _dataDirectory?.call();
    } catch (e) {
      debugPrint('Video downloader: no app storage ($e)');
    }
    await cookies.open(data == null ? null : Directory(p.join(data.path, 'cookies')));
    await log.open(data == null ? null : File(p.join(data.path, 'logs', 'downloader_log.json')));
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
        _logJob(job);
        if (job.status == JobStatus.done) unawaited(_complete(job));
      }
      await _configure();
    } catch (e) {
      engineError = '$e';
    }
    notifyListeners();
  }

  /// Tells the backend how many jobs may run and whether to notify.
  Future<void> _configure() async {
    try {
      await backend.configure(
        maxConcurrent: settings.maxConcurrent,
        notifications: settings.notifications,
      );
    } catch (e) {
      debugPrint('Video downloader: settings not applied ($e)');
    }
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
    log.add('Removed the video engine', category: LogCategory.engine);
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
      if (firstTime) log.add('The video engine is set up', category: LogCategory.engine);
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
      if (!cancelled) {
        log.add(
          "The video engine couldn't start",
          level: LogLevel.error,
          category: LogCategory.engine,
          details: engineError,
        );
      }
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
      final json = await backend.fetchInfoJson(
        url,
        requestId: id,
        args: YtDlpArgs.info(settings),
        cookieFile: cookies.cookieFilePath,
      );
      final info = await _parseInfo(json, url);
      log.add(
        '${info.isPlaylist ? 'Read a playlist' : 'Read a link'}: ${info.title ?? url}',
        category: LogCategory.link,
        details: [
          'Link: $url',
          if (info.extractor != null) 'Site: ${info.extractor}',
          info.isPlaylist ? '${info.entries.length} items' : '${info.formats.length} formats',
          if (cookies.hasCookies) 'Sent the saved cookies',
        ].join('\n'),
      );
      return info;
    } on FormatException catch (e) {
      final message = "yt-dlp's answer couldn't be read (${e.message}).";
      _logFetchError(url, message);
      throw DownloaderException(message);
    } on DownloaderException catch (e) {
      if (!e.cancelled) _logFetchError(url, e.message);
      rethrow;
    } finally {
      if (_fetchId == id) _fetchId = null;
    }
  }

  void _logFetchError(String url, String message) => log.add(
        "Couldn't read a link",
        level: LogLevel.error,
        category: LogCategory.link,
        details: 'Link: $url\nError: $message',
      );

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
    if (settings.notifications) await _askNotificationPermission();
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
      cookieFile: cookies.cookieFilePath,
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
        _logJob(job);
        if (job.status == JobStatus.done) unawaited(_complete(job));
      case JobRemoved(:final id):
        _jobs.remove(id);
      case SetupProgress():
        return; // [_prepare] gets it through prepare's onProgress.
    }
    notifyListeners();
  }

  /// Logs a job that has ended, once.
  void _logJob(DownloadJob job) {
    if (job.isActive) return;
    final ref = 'job:${job.id}:${job.finishedAt?.millisecondsSinceEpoch ?? 0}';
    if (log.hasRef(ref)) return;
    final title = job.displayTitle;
    final (level, head) = switch (job.status) {
      JobStatus.done => (LogLevel.info, 'Downloaded: $title'),
      JobStatus.failed => (LogLevel.error, 'Download failed: $title'),
      _ => (LogLevel.warning, 'Download cancelled: $title'),
    };
    final output = job.output ?? job.log;
    log.add(
      head,
      level: level,
      category: LogCategory.download,
      ref: ref,
      time: job.finishedAt,
      details: [
        'Link: ${job.url}',
        if (job.meta['label'] != null) 'Options: ${job.meta['label']}',
        if (job.filePath != null)
          'File: ${job.filePath}'
        else if (job.outputDir != null)
          'Folder: ${job.outputDir}',
        if (job.error != null) 'Error: ${job.error}',
        if (output != null && output.trim().isNotEmpty) ...['', 'yt-dlp:', output.trimRight()],
      ].join('\n'),
    );
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
    final old = settings;
    settings = value;
    notifyListeners();
    await _prefs?.setString(_kSettings, jsonEncode(value.toJson()));
    if (isStarted &&
        isSupported &&
        (old.maxConcurrent != value.maxConcurrent || old.notifications != value.notifications)) {
      await _configure();
    }
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
      log.add(
        result.updated
            ? 'Updated yt-dlp to ${result.version}'
            : 'yt-dlp is up to date (${result.version ?? 'unknown version'})',
        category: LogCategory.engine,
      );
      return result;
    } catch (e) {
      log.add(
        "yt-dlp couldn't be updated",
        level: LogLevel.error,
        category: LogCategory.engine,
        details: '$e',
      );
      rethrow;
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

  // Maintenance -----------------------------------------------------------

  /// Deletes partial downloads of jobs that aren't running or waiting, and
  /// yt-dlp's cache. Finished downloads stay. Returns the bytes freed.
  Future<int> clearCache() async {
    await start();
    var freed = 0;
    if (isSupported) {
      final keep = {
        for (final j in _jobs.values)
          if (j.isActive && j.workDir != null) j.workDir!,
      };
      freed = await backend.clearCache(
        keepWorkDirs: keep,
        outputDirs: {
          if (outputDir.isNotEmpty) outputDir,
          ?backendPaths?.defaultOutputDir,
        },
      );
    }
    log.add('Cleared the cache: ${formatBytes(freed)} freed', category: LogCategory.maintenance);
    return freed;
  }

  /// "12 MB".
  static String formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var unit = 0;
    while (v >= 1000 && unit < units.length - 1) {
      v /= 1000;
      unit++;
    }
    return unit == 0 ? '$bytes B' : '${v.toStringAsFixed(v >= 10 ? 0 : 1)} ${units[unit]}';
  }

  // Permissions (Android) ---------------------------------------------------

  Future<DownloaderPermissions?> permissions() async {
    try {
      return await backend.permissions();
    } catch (_) {
      return null;
    }
  }

  /// Asks for access to every folder: Android 11 and newer open the "All
  /// files access" page.
  Future<void> requestStorageAccess() async {
    final state = await permissions();
    if (state == null || state.storage) return;
    try {
      if (state.sdk >= 30) {
        await Permission.manageExternalStorage.request();
      } else if (!(await Permission.storage.request()).isGranted) {
        await openAppSettings();
      }
    } catch (_) {}
  }

  /// Asks to show notifications (Android 13 and newer), else opens the
  /// app's notification settings.
  Future<void> allowNotifications() async {
    try {
      final status = await Permission.notification.request();
      if (status.isGranted && ((await permissions())?.notifications ?? true)) return;
    } catch (_) {}
    await openNotificationSettings();
  }

  Future<void> openNotificationSettings() async {
    try {
      await backend.openNotificationSettings();
    } catch (_) {}
  }

  // Cookies -----------------------------------------------------------------

  /// Imports a cookies.txt file. Throws [CookieFormatException].
  Future<ImportResult> importCookies(File file) async {
    await start();
    final result = await cookies.importFile(file);
    log.add(
      'Imported cookies from ${p.basename(file.path)}',
      category: LogCategory.cookies,
      details: [
        result.summary,
        if (result.invalidLines > 0) '${result.invalidLines} lines skipped (not cookies)',
        if (result.expired > 0) '${result.expired} expired',
      ].join('\n'),
    );
    return result;
  }

  Future<void> removeImportedCookies() async {
    await cookies.removeImported();
    log.add('Removed the imported cookies', category: LogCategory.cookies);
  }

  /// Keeps the cookies a sign-in left for [site]; returns how many.
  Future<int> saveSignIn(CookieSite site, List<NetscapeCookie> found) async {
    await start();
    final count = await cookies.setSiteCookies(site, found, source: CookieSource.login);
    log.add(
      count == 0
          ? 'No cookies found after signing in to ${site.name}'
          : 'Saved the cookies of signing in to ${site.name} ($count)',
      level: count == 0 ? LogLevel.warning : LogLevel.info,
      category: LogCategory.cookies,
      details: count == 0 ? null : cookies.status(site).label,
    );
    return count;
  }

  /// Keeps cookies the user pasted for [site]. Throws [CookieFormatException].
  Future<int> pasteCookies(CookieSite site, String text) async {
    await start();
    final count = await cookies.paste(site, text);
    log.add(
      'Saved pasted cookies for ${site.name} ($count)',
      category: LogCategory.cookies,
      details: cookies.status(site).label,
    );
    return count;
  }

  Future<void> signOut(CookieSite site) async {
    await cookies.signOut(site);
    log.add('Signed out of ${site.name}', category: LogCategory.cookies);
  }

  Future<void> addCookieSite(CookieSite site) async {
    await start();
    await cookies.addSite(site);
  }

  Future<void> removeCookieSite(CookieSite site) async {
    await cookies.removeSite(site);
    log.add('Removed ${site.name} and its cookies', category: LogCategory.cookies);
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
    unawaited(log.save());
    log.dispose();
    cookies.dispose();
    super.dispose();
  }
}
