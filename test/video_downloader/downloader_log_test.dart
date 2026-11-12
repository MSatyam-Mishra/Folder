import 'dart:io';

import 'package:folders/core/services/video_downloader/downloader_log.dart';
import 'package:folders/core/services/video_downloader/ytdlp_output.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('entries are redacted, capped and kept', () async {
    final dir = await Directory.systemTemp.createTemp('folders_downloader_log_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'logs', 'downloader_log.json'));
    final log = DownloaderLog(
      redact: (s) => s.replaceAll('secret-cookie', '[cookie]'),
      maxBytes: 4000,
      maxDetails: 300,
    );
    await log.open(file);
    log.add('Downloaded: a clip', details: 'line with secret-cookie in it', ref: 'job:1:5',
        time: DateTime(2026, 11, 12, 14, 3, 22));
    expect(log.entries.single.details, 'line with [cookie] in it');
    expect(log.hasRef('job:1:5'), isTrue);
    expect(log.entries.single.toText(),
        '2026-11-12 14:03:22  INFO    [Download] Downloaded: a clip\n    line with [cookie] in it');

    // Long details keep their end.
    log.add('Failed', level: LogLevel.error, details: [for (var i = 0; i < 100; i++) 'line $i'].join('\n'));
    final details = log.entries.last.details!;
    expect(details, startsWith('(earlier lines left out)'));
    expect(details, endsWith('line 99'));
    expect(details.length, lessThan(340));

    // The oldest go once the log is too big.
    for (var i = 0; i < 40; i++) {
      log.add('Entry $i', details: 'x' * 100);
    }
    expect(log.entries.first.title, isNot('Downloaded: a clip'));
    expect(log.entries.last.title, 'Entry 39');

    await log.save();
    final again = DownloaderLog();
    await again.open(file);
    expect(again.entries.map((e) => e.title), log.entries.map((e) => e.title));
    expect(again.toText(), contains('Entry 39'));

    await again.clear();
    final cleared = DownloaderLog();
    await cleared.open(file);
    expect(cleared.isEmpty, isTrue);
    log.dispose();
    again.dispose();
    cleared.dispose();
  });

  test('a job\'s output is readable and time-stamped', () {
    var now = DateTime(2026, 11, 12, 9, 5, 7);
    final tracker = JobProgressTracker(clock: () => now);
    tracker.apply('__EXPL_TITLE__A clip');
    tracker.apply('__EXPL_P__downloading|100|1000|NA|50|10|137|NA|NA');
    tracker.apply('__EXPL_P__downloading|500|1000|NA|50|5|137|NA|NA');
    now = now.add(const Duration(seconds: 3));
    tracker.apply('__EXPL_P__finished|1000|1000|NA|NA|NA|137|NA|NA');
    tracker.apply('__EXPL_P__finished|1000|1000|NA|NA|NA|137|NA|NA');
    tracker.apply('__EXPL_PP__started|Merger');
    tracker.apply('WARNING: something odd');
    tracker.apply('__EXPL_FILE__/out/A clip.mp4');
    expect(tracker.output, [
      '09:05:07 [title] A clip',
      '09:05:07 [download] Format 137',
      '09:05:10 [download] Done, 1000 bytes',
      '09:05:10 [postprocess] Merger',
      '09:05:10 WARNING: something odd',
      '09:05:10 [saved] /out/A clip.mp4',
    ]);
  });
}
