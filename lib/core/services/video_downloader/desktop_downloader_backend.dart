import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'desktop_tools.dart';
import 'downloader_backend.dart';
import 'ytdlp_args.dart';
import 'ytdlp_installer.dart';
import 'ytdlp_models.dart';
import 'ytdlp_output.dart';

/// Windows, macOS and Linux: the official yt-dlp executable, with FFmpeg
/// and a JavaScript runtime (for YouTube) from the system when it has them.
/// What's missing is downloaded into the app support folder once the user
/// agrees (the "video engine": yt-dlp, FFmpeg, Deno). Jobs run in this
/// process, so they continue while the app is open, whichever screen is
/// showing.
class DesktopDownloaderBackend extends VideoDownloaderBackend {
  DesktopDownloaderBackend({Directory? supportDirectory, Directory? tempDirectory})
      : _supportOverride = supportDirectory,
        _tempOverride = tempDirectory;

  final Directory? _supportOverride;
  final Directory? _tempOverride;
  final _events = StreamController<BackendEvent>.broadcast();
  final _jobs = <String, _DesktopJob>{};
  final _fetches = <String, Process>{};
  final _cancelledFetches = <String>{};
  YtDlpInstaller? _installer;
  DesktopTools? _desktopTools;
  _Tools? _tools;
  bool _cancelSetup = false;
  String? _versionCache;
  DateTime? _versionStamp;

  @override
  int get maxConcurrent => 2;

  Future<YtDlpInstaller> _ytDlp() async {
    if (_installer != null) return _installer!;
    final base = _supportOverride ?? await getApplicationSupportDirectory();
    return _installer = YtDlpInstaller(Directory(p.join(base.path, 'video_downloader')));
  }

  Future<DesktopTools> _downloadedTools() async {
    if (_desktopTools != null) return _desktopTools!;
    final installer = await _ytDlp();
    return _desktopTools = DesktopTools(installer.directory);
  }

  Future<_Tools> _findTools() async =>
      _tools ??= _Tools.find(await _downloadedTools());

  /// The engine's parts this computer needs: yt-dlp always, FFmpeg and Deno
  /// unless the system has them (or there's no download for this computer).
  Future<List<_Part>> _parts() async {
    final installer = await _ytDlp();
    final downloaded = await _downloadedTools();
    final tools = await _findTools();
    return [
      _Part(
        'yt-dlp',
        installed: installer.isInstalled,
        downloadBytes: Platform.isWindows ? 18000000 : 36000000,
        diskBytes: Platform.isWindows ? 18000000 : 36000000,
        install: (progress, cancelled) =>
            installer.install(onProgress: progress, isCancelled: cancelled),
      ),
      if (DesktopTools.ffmpegAsset() != null &&
          (downloaded.hasFfmpeg || tools.ffmpeg == null))
        _Part(
          'FFmpeg',
          site: DesktopTools.ffmpegSite,
          installed: downloaded.hasFfmpeg,
          downloadBytes: DesktopTools.ffmpegDownloadBytes,
          diskBytes: DesktopTools.ffmpegDiskBytes,
          install: (progress, cancelled) =>
              downloaded.installFfmpeg(onProgress: progress, isCancelled: cancelled),
        ),
      if (DesktopTools.denoAsset() != null &&
          (downloaded.hasDeno || tools.jsRuntime == null))
        _Part(
          'Deno',
          installed: downloaded.hasDeno,
          downloadBytes: DesktopTools.denoDownloadBytes,
          diskBytes: DesktopTools.denoDiskBytes,
          install: (progress, cancelled) =>
              downloaded.installDeno(onProgress: progress, isCancelled: cancelled),
        ),
    ];
  }

  static String _list(List<String> names) => names.length < 2
      ? names.join()
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

  /// Where [parts] come from.
  static String _source(List<_Part> parts) => sourceText(
        [for (final part in parts) if (part.site == null) part.name],
        [for (final part in parts) ?part.site],
      );

  /// "the GitHub pages of yt-dlp and Deno", then other [sites] (FFmpeg's on
  /// macOS) after a comma, so they don't read as GitHub pages.
  @visibleForTesting
  static String sourceText(List<String> fromGitHub, List<String> sites) {
    if (fromGitHub.isEmpty) return _list(sites);
    final pages = 'the GitHub pages of ${_list(fromGitHub)}';
    return sites.isEmpty ? pages : '$pages, and from ${_list(sites)}';
  }

  @override
  Future<BackendStatus> status() async {
    final installer = await _ytDlp();
    // Looked for again each time: FFmpeg may have been installed since
    // (on a Mac, with Homebrew).
    final tools = _tools = _Tools.find(await _downloadedTools());
    final parts = await _parts();
    final missing = parts.where((part) => !part.installed).toList();
    return BackendStatus(
      ready: installer.isInstalled,
      needsSetup: missing.isNotEmpty,
      hasFfmpeg: tools.ffmpeg != null,
      ffmpegNote: tools.ffmpeg != null
          ? (tools.ffmpegDownloaded
              ? 'FFmpeg is part of the video engine.'
              : 'Using FFmpeg at ${tools.ffmpeg}.')
          : 'FFmpeg was not found. Without it Folder can only download '
              'formats that already contain both video and audio (often '
              'lower quality), and cannot convert to MP3 or embed '
              'thumbnails. Install FFmpeg (on a Mac: brew install ffmpeg), '
              'then reopen the downloader.',
      setupNote: 'A one-time download. Keep Folder open until it\'s done.',
      engine: EngineInfo(
        installed: missing.isEmpty,
        downloadBytes: missing.fold(0, (sum, part) => sum + part.downloadBytes),
        diskBytes: parts.fold(0, (sum, part) => sum + part.diskBytes),
        contents: _list([for (final part in parts) part.name]),
        source: _source(parts),
      ),
    );
  }

  @override
  Future<void> prepare({void Function(double? progress, String message)? onProgress}) async {
    _cancelSetup = false;
    final missing = (await _parts()).where((part) => !part.installed).toList();
    for (final (index, part) in missing.indexed) {
      final step = missing.length > 1 ? ' (${index + 1} of ${missing.length})' : '';
      onProgress?.call(null, 'Downloading ${part.name}$step…');
      await part.install((received, total) {
        final mb = (received / 1e6).toStringAsFixed(0);
        onProgress?.call(
          total == null ? null : received / total,
          total == null
              ? 'Downloading ${part.name}$step: $mb MB'
              : 'Downloading ${part.name}$step: $mb of ${(total / 1e6).toStringAsFixed(0)} MB',
        );
      }, () => _cancelSetup);
    }
    _tools = null;
  }

  @override
  Future<void> cancelPrepare() async => _cancelSetup = true;

  @override
  Future<void> removeEngine() async {
    if (_jobs.values.any((j) => j.isActive) || _fetches.isNotEmpty) {
      throw const DownloaderException(
          'Wait for the downloads to finish, then remove the video engine.');
    }
    final installer = await _ytDlp();
    await (await _downloadedTools()).remove();
    if (await installer.binary.exists()) await installer.binary.delete();
    _tools = null;
    _versionCache = null;
  }

  @override
  Future<String?> version() async {
    final installer = await _ytDlp();
    if (!installer.isInstalled) return null;
    final modified = await installer.binary.lastModified();
    if (_versionCache != null && _versionStamp == modified) return _versionCache;
    final result = await Process.run(installer.binary.path, ['--version'],
        environment: _env, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (result.exitCode != 0) return null;
    _versionStamp = modified;
    return _versionCache = (result.stdout as String).trim();
  }

  @override
  Future<UpdateResult> update() async {
    if (_jobs.values.any((j) => j.isActive) || _fetches.isNotEmpty) {
      throw const DownloaderException(
          'Wait for the downloads to finish, then update yt-dlp.');
    }
    final installer = await _ytDlp();
    final latest = await installer.latestTag();
    final current = await version();
    if (current == latest) return UpdateResult(updated: false, version: current);
    await installer.install(tag: latest);
    _versionCache = null;
    return UpdateResult(updated: true, version: await version() ?? latest);
  }

  @override
  Future<BackendPaths> paths() async {
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {}
    downloads ??= await getApplicationDocumentsDirectory();
    final temp = _tempOverride ?? await getTemporaryDirectory();
    return BackendPaths(
      defaultOutputDir: p.join(downloads.path, 'Folder Videos'),
      workRoot: p.join(temp.path, 'explorer_video_work'),
    );
  }

  @override
  Future<bool> canWrite(String dir) async {
    try {
      await Directory(dir).create(recursive: true);
      final probe = File(p.join(dir, '.explorer-write-test'));
      await probe.writeAsString('');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _env = {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'};

  Future<List<String>> _commonArgs() async {
    final tools = await _findTools();
    return [
      if (tools.ffmpeg != null) ...['--ffmpeg-location', tools.ffmpeg!],
      if (tools.jsRuntime != null) ...['--js-runtimes', tools.jsRuntime!],
    ];
  }

  @override
  Future<String> fetchInfoJson(String url, {required String requestId}) async {
    final installer = await _ytDlp();
    final args = [...YtDlpArgs.info(), ...await _commonArgs(), '--', url];
    final process = await Process.start(installer.binary.path, args, environment: _env);
    _fetches[requestId] = process;
    try {
      final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
      final err = process.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
      final code = await process.exitCode;
      final stdout = await out;
      final stderr = await err;
      if (_cancelledFetches.remove(requestId)) {
        throw const DownloaderException('Cancelled', cancelled: true);
      }
      if (code != 0 && !stdout.trimLeft().startsWith('{')) {
        throw DownloaderException(YtDlpOutputParser.errorMessage(stderr));
      }
      return stdout;
    } finally {
      _fetches.remove(requestId);
    }
  }

  @override
  Future<void> cancelFetch(String requestId) async {
    final process = _fetches[requestId];
    if (process == null) return;
    _cancelledFetches.add(requestId);
    await _kill(process);
  }

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  Future<void> enqueue(JobSpec spec) async {
    if (_jobs.containsKey(spec.id)) return;
    final job = _DesktopJob(spec);
    _jobs[spec.id] = job;
    _emit(job);
    _pump();
  }

  @override
  Future<void> cancel(String id) async {
    final job = _jobs[id];
    if (job != null) await _cancel(job);
  }

  Future<void> _cancel(_DesktopJob job) async {
    if (!job.isActive) return;
    job.cancelRequested = true;
    if (job.status == JobStatus.queued) {
      job.status = JobStatus.cancelled;
      job.finishedAt = DateTime.now();
      _emit(job);
      return;
    }
    final process = job.process;
    if (process != null) await _kill(process);
  }

  @override
  Future<void> retry(String id) async {
    final job = _jobs[id];
    if (job == null ||
        (job.status != JobStatus.failed && job.status != JobStatus.cancelled)) {
      return;
    }
    job.reset();
    _emit(job);
    _pump();
  }

  @override
  Future<void> remove(String id) async {
    final job = _jobs.remove(id);
    if (job == null) return;
    job.removed = true;
    final running = job.status == JobStatus.running;
    await _cancel(job);
    if (!running) await _deleteDir(job.spec.workDir);
    _events.add(JobRemoved(id));
    _pump();
  }

  @override
  Future<List<DownloadJob>> jobs() async => [for (final j in _jobs.values) j.snapshot()];

  void _pump() {
    var running = _jobs.values.where((j) => j.status == JobStatus.running).length;
    for (final job in _jobs.values.toList()) {
      if (running >= maxConcurrent) break;
      if (job.status == JobStatus.queued && !job.cancelRequested) {
        job.status = JobStatus.running;
        running++;
        _emit(job);
        unawaited(_run(job));
      }
    }
  }

  Future<void> _run(_DesktopJob job) async {
    final spec = job.spec;
    try {
      final installer = await _ytDlp();
      if (!installer.isInstalled) await prepare();
      await Directory(spec.outputDir).create(recursive: true);
      await Directory(spec.workDir).create(recursive: true);
      final args = [...spec.args, ...await _commonArgs(), '--', spec.url];
      if (job.cancelRequested) throw const DownloaderException('Cancelled', cancelled: true);
      final process = await Process.start(installer.binary.path, args,
          workingDirectory: spec.workDir, environment: _env);
      job.process = process;
      if (job.cancelRequested) await _kill(process);
      void onLine(String line) {
        final urgent = job.tracker.apply(line);
        _emit(job, throttle: !urgent);
      }

      final out = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine)
          .asFuture<void>();
      final err = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine)
          .asFuture<void>();
      final code = await process.exitCode;
      await Future.wait([out, err]).catchError((Object _) => <void>[]);
      if (job.cancelRequested) {
        job.status = JobStatus.cancelled;
      } else if (code == 0) {
        job.status = JobStatus.done;
        job.tracker.percent = 100;
        job.tracker.stage = null;
      } else {
        job.status = JobStatus.failed;
        var error = job.tracker.failureMessage('yt-dlp exited with code $code');
        if (_tools?.ffmpeg == null && error.contains('Requested format is not available')) {
          error = 'This video is only offered as separate video and audio '
              'streams, which need FFmpeg to be combined. Install FFmpeg, make '
              'sure it is on your PATH, reopen the downloader and retry.';
        }
        job.error = error;
      }
    } on DownloaderException catch (e) {
      job.status = e.cancelled || job.cancelRequested ? JobStatus.cancelled : JobStatus.failed;
      job.error = e.cancelled ? null : e.message;
    } catch (e) {
      job.status = job.cancelRequested ? JobStatus.cancelled : JobStatus.failed;
      job.error = job.cancelRequested ? null : '$e';
    } finally {
      job.process = null;
      job.finishedAt = DateTime.now();
    }
    if (job.removed || job.status == JobStatus.done) {
      // Nothing to resume.
      await _deleteDir(spec.workDir);
    }
    if (!job.removed) _emit(job);
    _pump();
  }

  void _emit(_DesktopJob job, {bool throttle = false}) {
    if (job.removed) return;
    final now = DateTime.now();
    if (throttle && now.difference(job.lastEmit) < const Duration(milliseconds: 300)) {
      return;
    }
    job.lastEmit = now;
    _events.add(JobChanged(job.snapshot()));
  }

  Future<void> _kill(Process process) async {
    if (Platform.isWindows) {
      // yt-dlp.exe is a PyInstaller bootloader with a child process, which
      // may have started FFmpeg: end the whole tree.
      final r = await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      if (r.exitCode != 0) process.kill();
      return;
    }
    // SIGINT lets yt-dlp stop FFmpeg and clean up; force it if it lingers.
    process.kill(ProcessSignal.sigint);
    unawaited(process.exitCode.timeout(const Duration(seconds: 4), onTimeout: () {
      Process.run('pkill', ['-KILL', '-P', '${process.pid}']).ignore();
      process.kill(ProcessSignal.sigkill);
      return -1;
    }));
  }

  Future<void> _deleteDir(String path) async {
    try {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

class _DesktopJob {
  _DesktopJob(this.spec) : createdAt = DateTime.now();

  final JobSpec spec;
  final DateTime createdAt;
  JobStatus status = JobStatus.queued;
  JobProgressTracker tracker = JobProgressTracker();
  bool cancelRequested = false;
  bool removed = false;
  Process? process;
  String? error;
  DateTime? finishedAt;
  DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isActive => status == JobStatus.queued || status == JobStatus.running;

  void reset() {
    status = JobStatus.queued;
    tracker = JobProgressTracker();
    cancelRequested = false;
    error = null;
    finishedAt = null;
  }

  DownloadJob snapshot() => DownloadJob(
        id: spec.id,
        url: spec.url,
        status: status,
        createdAt: createdAt,
        title: tracker.title ?? spec.title,
        thumbnail: spec.thumbnail ?? tracker.thumbnail,
        outputDir: spec.outputDir,
        workDir: spec.workDir,
        meta: spec.meta,
        percent: tracker.percent,
        downloaded: tracker.downloaded,
        total: tracker.total,
        speed: tracker.speed,
        eta: tracker.eta,
        stage: tracker.stage,
        part: tracker.part,
        filePath: tracker.filePath,
        error: error,
        log: status == JobStatus.failed ? tracker.log.join('\n') : null,
        finishedAt: finishedAt,
      );
}

/// A part of the desktop video engine.
class _Part {
  _Part(
    this.name, {
    this.site,
    required this.installed,
    required this.downloadBytes,
    required this.diskBytes,
    required this.install,
  });

  final String name;

  /// Where it's downloaded from when that isn't its GitHub page.
  final String? site;
  final bool installed;
  final int downloadBytes;
  final int diskBytes;
  final Future<void> Function(
    void Function(int received, int? total) onProgress,
    bool Function() isCancelled,
  ) install;
}

/// FFmpeg and a JavaScript runtime (yt-dlp needs one for YouTube), looked
/// up on PATH and in the usual install folders: apps started from the
/// macOS Finder don't get the shell's PATH.
class _Tools {
  const _Tools({this.ffmpeg, this.jsRuntime, this.ffmpegDownloaded = false});

  final String? ffmpeg;

  /// [ffmpeg] is the engine's, not the system's.
  final bool ffmpegDownloaded;

  /// yt-dlp `--js-runtimes` value, e.g. "node:/usr/bin/node". Null when
  /// none was found, or deno is on PATH (yt-dlp's default).
  final String? jsRuntime;

  /// The system's FFmpeg and JavaScript runtime, else the ones in
  /// [downloaded].
  static _Tools find(DesktopTools downloaded) {
    var ffmpeg = which('ffmpeg');
    var ffmpegDownloaded = false;
    if (ffmpeg == null && downloaded.hasFfmpeg) {
      ffmpeg = downloaded.ffmpeg.path;
      ffmpegDownloaded = true;
    }
    String? js;
    for (final runtime in const ['deno', 'node', 'bun']) {
      final path = which(runtime);
      if (path != null) {
        js = '$runtime:$path';
        break;
      }
    }
    if (js == null && downloaded.hasDeno) js = 'deno:${downloaded.deno.path}';
    return _Tools(ffmpeg: ffmpeg, jsRuntime: js, ffmpegDownloaded: ffmpegDownloaded);
  }

  /// [name] on PATH (and Homebrew's folders on macOS), else where Linux
  /// packages and WinGet put programs.
  static String? which(String name) {
    final local = Platform.environment['LOCALAPPDATA'];
    return DesktopTools.which(name, alsoIn: [
      if (Platform.isLinux) ...['/usr/local/bin', '/usr/bin', '/snap/bin'],
      if (Platform.isWindows && local != null) p.join(local, 'Microsoft', 'WinGet', 'Links'),
    ]);
  }
}
