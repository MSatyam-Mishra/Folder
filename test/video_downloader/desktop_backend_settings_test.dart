@TestOn('windows || mac-os || linux')
library;

import 'dart:io';

import 'package:folders/core/services/video_downloader/desktop_downloader_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory support;
  late Directory temp;
  late DesktopDownloaderBackend backend;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('folders_dl_support_');
    temp = await Directory.systemTemp.createTemp('folders_dl_temp_');
    backend = DesktopDownloaderBackend(supportDirectory: support, tempDirectory: temp);
  });

  tearDown(() async {
    for (final d in [support, temp]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  Future<File> fill(String path, int bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(bytes, 7));
    return file;
  }

  test('how many downloads run at once follows the setting', () async {
    expect(backend.maxConcurrent, 2);
    await backend.configure(maxConcurrent: 4, notifications: true);
    expect(backend.maxConcurrent, 4);
    await backend.configure(maxConcurrent: 9, notifications: false);
    expect(backend.maxConcurrent, 5);
  });

  test('clearing the cache frees partial downloads and yt-dlp\'s cache, not the rest', () async {
    final work = p.join(temp.path, 'explorer_video_work');
    await fill(p.join(work, 'old-job', 'clip.mp4.part'), 1000);
    final running = await fill(p.join(work, 'running-job', 'clip.mp4.part'), 300);
    await fill(p.join(support.path, 'video_downloader', 'cache', 'youtube-nsig', 'a.json'), 500);
    final engine = await fill(p.join(support.path, 'video_downloader', 'ffmpeg', 'ffmpeg.exe'), 200);

    final freed = await backend.clearCache(keepWorkDirs: {p.join(work, 'running-job')});
    expect(freed, 1500);
    expect(Directory(p.join(work, 'old-job')).existsSync(), isFalse);
    expect(running.existsSync(), isTrue, reason: 'a job still uses it');
    expect(Directory(p.join(support.path, 'video_downloader', 'cache')).existsSync(), isFalse);
    expect(engine.existsSync(), isTrue, reason: 'the engine is not a cache');
    expect(await backend.clearCache(keepWorkDirs: const {}), 300);
  });
}
