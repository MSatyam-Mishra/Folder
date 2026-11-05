import 'package:flutter/services.dart';

import 'downloader_backend.dart';
import 'ytdlp_models.dart';
import 'ytdlp_output.dart';

/// Android: youtubedl-android (Python + yt-dlp + FFmpeg) through
/// VideoDownloaderNative.kt; jobs run in a foreground service and outlive
/// this Flutter engine. Python and FFmpeg, the engine, aren't in the APK:
/// the first [prepare] downloads them (VideoEngineInstaller.kt).
class AndroidDownloaderBackend extends VideoDownloaderBackend {
  AndroidDownloaderBackend();

  static const _channel = MethodChannel('explorer/video_downloader');
  static const _events = EventChannel('explorer/video_downloader/events');

  Stream<BackendEvent>? _stream;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw DownloaderException(
        e.code == 'CANCELLED'
            ? 'Cancelled'
            : YtDlpOutputParser.errorMessage(e.message ?? e.code),
        cancelled: e.code == 'CANCELLED',
      );
    }
  }

  @override
  Future<BackendStatus> status() async {
    final m = await _call<Map<dynamic, dynamic>>('status') ?? const {};
    final installed = m['engineInstalled'] == true;
    final download = m['engineDownloadBytes'];
    final disk = m['engineDiskBytes'];
    return BackendStatus(
      ready: m['ready'] == true,
      needsSetup: !installed,
      hasFfmpeg: true,
      ffmpegNote: 'FFmpeg is part of the video engine.',
      setupNote: "A one-time download. Keep Folder open until it's done.",
      engine: download is int && disk is int
          ? EngineInfo(installed: installed, downloadBytes: download, diskBytes: disk)
          : null,
    );
  }

  @override
  Future<void> prepare({void Function(double? progress, String message)? onProgress}) async {
    final m = await _call<Map<dynamic, dynamic>>('status') ?? const {};
    if (m['engineInstalled'] != true) {
      final total = m['engineDownloadBytes'];
      onProgress?.call(0, _downloading(0, total is int ? total : 0));
      final progress = events.listen((e) {
        if (e is SetupProgress) onProgress?.call(e.progress, e.message);
      });
      try {
        await _call<void>('installEngine');
      } finally {
        await progress.cancel();
      }
    }
    onProgress?.call(null, 'Starting the downloader…');
    await _call<void>('prepare');
  }

  @override
  Future<void> cancelPrepare() => _call<void>('cancelEngine');

  @override
  Future<void> removeEngine() => _call<void>('removeEngine');

  static SetupProgress _engineProgress(Map<dynamic, dynamic> event) {
    if (event['phase'] == 'unpack') {
      return const SetupProgress(null, 'Installing the video engine…');
    }
    final done = (event['done'] as num?)?.toInt() ?? 0;
    final total = (event['total'] as num?)?.toInt() ?? 0;
    return SetupProgress(total > 0 ? done / total : null, _downloading(done, total));
  }

  static String _downloading(int done, int total) =>
      'Downloading the video engine: ${(done / 1e6).toStringAsFixed(0)} of '
      '${(total / 1e6).toStringAsFixed(0)} MB';

  @override
  Future<String?> version() => _call<String>('version');

  @override
  Future<UpdateResult> update() async {
    final m = await _call<Map<dynamic, dynamic>>('update') ?? const {};
    return UpdateResult(
      updated: m['status'] == 'updated',
      version: m['version'] as String?,
    );
  }

  @override
  Future<BackendPaths> paths() async {
    final m = await _call<Map<dynamic, dynamic>>('paths') ?? const {};
    return BackendPaths(
      defaultOutputDir: m['defaultOutputDir'] as String,
      workRoot: m['workRoot'] as String,
    );
  }

  @override
  Future<bool> canWrite(String dir) async =>
      await _call<bool>('canWrite', {'path': dir}) ?? false;

  @override
  Future<String> fetchInfoJson(String url, {required String requestId}) async =>
      await _call<String>('fetchInfo', {'url': url, 'requestId': requestId}) ?? '';

  @override
  Future<void> cancelFetch(String requestId) =>
      _call<void>('cancelFetch', {'requestId': requestId});

  @override
  Stream<BackendEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map<BackendEvent?>((event) {
        if (event is! Map) return null;
        return switch (event['event']) {
          'job' => JobChanged(DownloadJob.fromMap(event['job'] as Map)),
          'removed' => JobRemoved('${event['id']}'),
          'engine' => _engineProgress(event),
          _ => null,
        };
      })
      .where((e) => e != null)
      .cast<BackendEvent>()
      .asBroadcastStream();

  @override
  Future<void> enqueue(JobSpec spec) => _call<void>('enqueue', spec.toMap());

  @override
  Future<void> cancel(String id) => _call<void>('cancel', {'id': id});

  @override
  Future<void> retry(String id) => _call<void>('retry', {'id': id});

  @override
  Future<void> remove(String id) => _call<void>('remove', {'id': id});

  @override
  Future<List<DownloadJob>> jobs() async {
    final list = await _call<List<dynamic>>('jobs') ?? const [];
    return [for (final m in list) if (m is Map) DownloadJob.fromMap(m)];
  }

  @override
  Future<List<DownloadJob>> takeFinished() async {
    final list = await _call<List<dynamic>>('takeFinished') ?? const [];
    return [for (final m in list) if (m is Map) DownloadJob.fromMap(m)];
  }

  @override
  Future<void> ackFinished(List<String> ids) =>
      _call<void>('ackFinished', {'ids': ids});

  @override
  Future<void> fileDeleted(String path) => _call<void>('scanFile', {'path': path});
}
