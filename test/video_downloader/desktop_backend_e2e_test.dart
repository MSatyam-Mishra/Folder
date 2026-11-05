// ignore_for_file: avoid_print
// End-to-end check of the desktop backend against the real internet:
// downloads the official yt-dlp release (SHA-256 verified), fetches info and
// downloads small Creative Commons videos (Blender Foundation).
//
// Opt-in, as it downloads ~30 MB:
//   EXPLORER_VIDEO_E2E=1 flutter test test/video_downloader/desktop_backend_e2e_test.dart
// EXPLORER_VIDEO_E2E_DIR=<dir> keeps the files there for inspection.
@TestOn('windows || mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:folder/core/services/video_downloader/desktop_downloader_backend.dart';
import 'package:folder/core/services/video_downloader/downloader_backend.dart';
import 'package:folder/core/services/video_downloader/downloader_settings.dart';
import 'package:folder/core/services/video_downloader/ytdlp_args.dart';
import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:folder/core/services/video_downloader/ytdlp_output.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// Big Buck Bunny trailer (CC-BY 3.0 Blender Foundation), 4.4 MB Ogg Theora.
const _bbbTrailer = 'https://download.blender.org/peach/trailer/trailer_400p.ogg';
// Tears of Steel teaser (CC-BY 3.0 Blender Foundation), 40 s, on the
// project's YouTube channel: separate video and audio streams.
const _tosTeaser = 'https://www.youtube.com/watch?v=WwHux5QZfC8';
// Big Buck Bunny full film on the Internet Archive (332 MB): only started,
// then cancelled.
const _bbbArchive = 'https://archive.org/details/BigBuckBunny_124';

void main() {
  final enabled = Platform.environment['EXPLORER_VIDEO_E2E'] == '1';
  late Directory base;
  late DesktopDownloaderBackend backend;
  late String out;
  late String work;
  final events = <BackendEvent>[];
  final hasFfmpeg = Platform.environment['EXPLORER_VIDEO_E2E_NO_FFMPEG'] != '1';
  const settings = DownloaderSettings();

  setUpAll(() async {
    final keep = Platform.environment['EXPLORER_VIDEO_E2E_DIR'];
    base = keep != null
        ? (Directory(keep)..createSync(recursive: true))
        : Directory.systemTemp.createTempSync('explorer_video_e2e');
    backend = DesktopDownloaderBackend(
      supportDirectory: Directory(p.join(base.path, 'support')),
      tempDirectory: Directory(p.join(base.path, 'tmp')),
    );
    backend.events.listen(events.add);
    out = p.join(base.path, 'out');
    work = p.join(base.path, 'work');
  });

  Future<DownloadJob> waitFor(String id, bool Function(DownloadJob) done,
      {Duration timeout = const Duration(minutes: 4)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final job = (await backend.jobs()).where((j) => j.id == id).firstOrNull;
      if (job != null && done(job)) return job;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('job $id');
  }

  JobSpec spec(String id, String url, DownloadOptions options) => JobSpec(
        id: id,
        url: url,
        outputDir: out,
        workDir: p.join(work, id),
        args: YtDlpArgs.download(
          options: options,
          settings: settings,
          hasFfmpeg: hasFfmpeg,
          outputDir: out,
          workDir: p.join(work, id),
        ),
      );

  test('installs yt-dlp with a verified checksum', () async {
    final status = await backend.status();
    printOnFailure('ffmpeg: ${status.ffmpegNote}');
    final progress = <double?>[];
    await backend.prepare(onProgress: (v, _) => progress.add(v));
    final version = await backend.version();
    print('yt-dlp $version, ffmpeg: ${status.hasFfmpeg}; ${status.ffmpegNote}');
    expect(version, matches(RegExp(r'^\d{4}\.\d\d\.\d\d')));
    expect((await backend.status()).ready, isTrue);
    final update = await backend.update();
    expect(update.updated, isFalse, reason: 'just installed the latest');
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 5)));

  test('fetches info: direct file and YouTube', () async {
    final direct = YtDlpOutputParser.parseInfo(
        await backend.fetchInfoJson(_bbbTrailer, requestId: 'i1'),
        url: _bbbTrailer);
    expect(direct.title, 'trailer_400p');
    expect(direct.isPlaylist, isFalse);

    final yt = YtDlpOutputParser.parseInfo(
        await backend.fetchInfoJson(_tosTeaser, requestId: 'i2'),
        url: _tosTeaser);
    print('YouTube: ${yt.title}, ${yt.formats.length} formats, heights ${yt.videoHeights}');
    expect(yt.title, contains('Tears of Steel'));
    expect(yt.duration, closeTo(40, 3));
    expect(yt.formats.any((f) => f.isVideoOnly), isTrue);
    expect(yt.formats.any((f) => f.isAudioOnly), isTrue);
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 3)));

  test('a fetch can be cancelled', () async {
    final expectation = expectLater(
      backend.fetchInfoJson(_bbbArchive, requestId: 'c1'),
      throwsA(isA<DownloaderException>().having((e) => e.cancelled, 'cancelled', isTrue)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await backend.cancelFetch('c1');
    await expectation;
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 1)));

  test('downloads three jobs, at most two at a time', () async {
    events.clear();
    await backend.enqueue(spec('merge', _tosTeaser,
        const DownloadOptions(quality: VideoQuality.p360)));
    await backend.enqueue(spec('mp3', _bbbTrailer,
        const DownloadOptions(kind: DownloadKind.audio, audioFormat: AudioFormat.mp3)));
    await backend.enqueue(spec('plain', _bbbTrailer, const DownloadOptions()));

    var maxRunning = 0;
    final sub = backend.events.listen((_) async {
      final running = (await backend.jobs()).where((j) => j.status == JobStatus.running).length;
      if (running > maxRunning) maxRunning = running;
    });
    final done = <DownloadJob>[];
    for (final id in ['merge', 'mp3', 'plain']) {
      done.add(await waitFor(id, (j) => !j.isActive));
    }
    await sub.cancel();
    for (final job in done) {
      print('${job.id}: ${job.status.name} ${job.filePath} ${job.error ?? ''}\n${job.log ?? ''}');
    }
    expect(done.map((j) => j.status), everyElement(JobStatus.done));
    expect(maxRunning, lessThanOrEqualTo(2));

    final merged = File(done[0].filePath!);
    expect(merged.existsSync(), isTrue);
    expect(p.extension(merged.path), hasFfmpeg ? '.mp4' : isNotEmpty);
    expect(done[0].title, contains('Tears of Steel'));
    final mp3 = File(done[1].filePath!);
    expect(p.extension(mp3.path), hasFfmpeg ? '.mp3' : isNotEmpty);
    expect(mp3.lengthSync(), greaterThan(100000));
    expect(File(done[2].filePath!).lengthSync(), greaterThan(4000000));

    // Progress was reported along the way.
    final progress = events
        .whereType<JobChanged>()
        .where((e) => e.job.id == 'plain' && e.job.percent != null);
    expect(progress, isNotEmpty);

    if (hasFfmpeg) {
      final probe = await Process.run('ffprobe', [
        '-v', 'error', '-show_entries', 'stream=codec_type,codec_name',
        '-of', 'csv=p=0', merged.path,
      ]);
      print('ffprobe ${p.basename(merged.path)}:\n${probe.stdout}');
      expect('${probe.stdout}', allOf(contains('video'), contains('audio')));
    }
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 8)));

  test('cancel, retry and remove', () async {
    await backend.enqueue(spec('big', _bbbArchive, const DownloadOptions()));
    await waitFor('big', (j) => (j.downloaded ?? 0) > 0, timeout: const Duration(minutes: 2));
    await backend.cancel('big');
    final cancelled = await waitFor('big', (j) => !j.isActive);
    expect(cancelled.status, JobStatus.cancelled);
    expect(cancelled.filePath, isNull);
    expect(Directory(p.join(work, 'big')).existsSync(), isTrue, reason: 'partial file kept for retry');

    await backend.retry('big');
    await waitFor('big', (j) => j.status == JobStatus.running);
    await backend.remove('big');
    await pumpEventQueue();
    expect(events.whereType<JobRemoved>().map((e) => e.id), contains('big'));
    expect((await backend.jobs()).map((j) => j.id), isNot(contains('big')));
    // The folder of partial files goes once the process has stopped.
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (Directory(p.join(work, 'big')).existsSync() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(Directory(p.join(work, 'big')).existsSync(), isFalse);
    expect(Directory(out).listSync().where((f) => f.path.contains('Big Buck Bunny')), isEmpty);
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 4)));
}
