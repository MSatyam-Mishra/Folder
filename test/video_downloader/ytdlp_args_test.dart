import 'package:folder/core/services/video_downloader/downloader_settings.dart';
import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folder/core/services/video_downloader/ytdlp_args.dart';
import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The value following [option] (its last occurrence).
String? _value(List<String> args, String option) {
  final i = args.lastIndexOf(option);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

List<String> _values(List<String> args, String option) => [
      for (var i = 0; i < args.length - 1; i++)
        if (args[i] == option) args[i + 1],
    ];

void main() {
  const settings = DownloaderSettings();

  List<String> build(
    DownloadOptions options, {
    DownloaderSettings s = settings,
    bool ffmpeg = true,
  }) =>
      YtDlpArgs.download(
        options: options,
        settings: s,
        hasFfmpeg: ffmpeg,
        outputDir: '/out',
        workDir: '/work/job1',
      );

  test('common options and machine-readable output', () {
    final args = build(const DownloadOptions());
    for (final flag in ['--newline', '--progress', '--no-playlist', '--no-mtime', '--no-update']) {
      expect(args, contains(flag));
    }
    expect(_values(args, '--paths'), ['home:/out', 'temp:/work/job1']);
    expect(_value(args, '--output'), DownloaderSettings.defaultFilenameTemplate);
    expect(_values(args, '--progress-template'),
        [YtDlpArgs.progressTemplate, YtDlpArgs.postprocessTemplate]);
    expect(_values(args, '--print'), [
      'video:__EXPL_TITLE__%(title)s',
      'video:__EXPL_THUMB__%(thumbnail)s',
      'after_move:__EXPL_FILE__%(filepath)s',
    ]);
    expect(args, isNot(contains('--')), reason: 'the backend adds -- and the URL');
  });

  test('video presets merge with FFmpeg, compatible codecs first', () {
    final best = build(const DownloadOptions());
    expect(_value(best, '--format'), 'bestvideo*+bestaudio/best');
    expect(_value(best, '--format-sort'), 'res,fps,vcodec:h264,acodec:aac');
    expect(_value(best, '--merge-output-format'), 'mp4/mkv');
    expect(best, containsAll(['--embed-metadata', '--embed-thumbnail', '--embed-chapters']));

    final p720 = build(const DownloadOptions(quality: VideoQuality.p720),
        s: settings.copyWith(preferCompatible: false, container: VideoContainer.mkv));
    expect(_value(p720, '--format-sort'), 'res:720');
    expect(_value(p720, '--merge-output-format'), 'mkv');
  });

  test('without FFmpeg: single-file formats, nothing to embed', () {
    final args = build(const DownloadOptions(quality: VideoQuality.p1080), ffmpeg: false);
    expect(_value(args, '--format'), 'best');
    expect(_value(args, '--format-sort'), 'res:1080,fps,vcodec:h264,acodec:aac,ext:mp4:m4a');
    expect(args, isNot(contains('--merge-output-format')));
    expect(args, isNot(contains('--embed-thumbnail')));
    expect(args, isNot(contains('--embed-metadata')));

    final audio = build(const DownloadOptions(kind: DownloadKind.audio, audioFormat: AudioFormat.mp3),
        ffmpeg: false);
    expect(_value(audio, '--format'), 'bestaudio[ext=m4a]/bestaudio/best');
    expect(audio, isNot(contains('--extract-audio')));
  });

  test('audio extraction', () {
    final mp3 = build(const DownloadOptions(kind: DownloadKind.audio, audioFormat: AudioFormat.mp3));
    expect(_value(mp3, '--format'), 'bestaudio/best');
    expect(mp3, contains('--extract-audio'));
    expect(_value(mp3, '--audio-format'), 'mp3');
    expect(_value(mp3, '--audio-quality'), '0');
    expect(mp3, contains('--embed-thumbnail'));
    expect(mp3, isNot(contains('--embed-chapters')));

    final m4a = build(const DownloadOptions(kind: DownloadKind.audio));
    expect(_value(m4a, '--format'), 'bestaudio[ext=m4a]/bestaudio/best');
    expect(_value(m4a, '--audio-format'), 'm4a');
  });

  test('exact formats', () {
    const videoOnly = VideoFormat(id: '137', vcodec: 'avc1', acodec: 'none', height: 1080);
    final v = build(const DownloadOptions(kind: DownloadKind.format, format: videoOnly));
    expect(_value(v, '--format'), '137+bestaudio/137');
    expect(_value(v, '--merge-output-format'), 'mp4/mkv');

    const audioOnly = VideoFormat(id: '251', vcodec: 'none', acodec: 'opus');
    final a = build(const DownloadOptions(kind: DownloadKind.format, format: audioOnly));
    expect(_value(a, '--format'), '251');
    expect(a, isNot(contains('--extract-audio')));

    final noFfmpeg = build(const DownloadOptions(kind: DownloadKind.format, format: videoOnly),
        ffmpeg: false);
    expect(_value(noFfmpeg, '--format'), '137');
  });

  test('subtitles', () {
    final s = settings.copyWith(subtitles: true, subtitleLangs: 'en.*,de', autoSubtitles: true);
    final args = build(const DownloadOptions(), s: s);
    expect(args, containsAll(['--write-subs', '--write-auto-subs', '--embed-subs']));
    expect(_value(args, '--sub-langs'), 'en.*,de');
    final noFfmpeg = build(const DownloadOptions(), s: s, ffmpeg: false);
    expect(noFfmpeg, contains('--write-subs'));
    expect(noFfmpeg, isNot(contains('--embed-subs')));
    final audio = build(const DownloadOptions(kind: DownloadKind.audio), s: s);
    expect(audio, isNot(contains('--write-subs')));
  });

  test('filename template gets an extension', () {
    final s = settings.copyWith(filenameTemplate: '%(uploader)s/%(title)s');
    expect(_value(build(const DownloadOptions(), s: s), '--output'), '%(uploader)s/%(title)s.%(ext)s');
    final empty = settings.copyWith(filenameTemplate: '  ');
    expect(_value(build(const DownloadOptions(), s: empty), '--output'),
        DownloaderSettings.defaultFilenameTemplate);
  });

  test('settings JSON round trip', () {
    final s = settings.copyWith(
      outputDir: '/sdcard/Movies',
      defaultKind: DownloadKind.audio,
      defaultQuality: VideoQuality.p480,
      audioFormat: AudioFormat.mp3,
      container: VideoContainer.mp4,
      subtitles: true,
      autoUpdate: false,
    );
    final back = DownloaderSettings.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
    expect(back.copyWith(resetOutputDir: true).outputDir, isNull);
    expect(DownloaderSettings.fromJson(const {}).toJson(), settings.toJson());
  });

  test('playlist folder names are safe', () {
    expect(VideoDownloaderController.safeFileName('a/b:c*?"<>|d'), 'a_b_c______d');
    expect(VideoDownloaderController.safeFileName('  ..Trailing dots.. '), 'Trailing dots');
    expect(VideoDownloaderController.safeFileName(''), 'Playlist');
    expect(VideoDownloaderController.safeFileName('x' * 300).length, 100);
  });
}
