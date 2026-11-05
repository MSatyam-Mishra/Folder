import 'dart:convert';

import 'package:folder/core/services/video_downloader/ytdlp_installer.dart';
import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:folder/core/services/video_downloader/ytdlp_output.dart';
import 'package:folder/features/video_downloader/widgets/downloader_text.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixtures are trimmed from real `yt-dlp -J --flat-playlist` output
// (yt-dlp 2026.07) and real progress lines printed with YtDlpArgs' templates.

const _youtubeVideo = '''
{"id": "39h7ZJbRcsw", "title": "OVERGROWN - Blender Feature Film (Teaser)",
 "uploader": "Blender Studio", "duration": 82, "_type": "video",
 "thumbnail": "https://i.ytimg.com/vi/39h7ZJbRcsw/maxresdefault.jpg",
 "webpage_url": "https://www.youtube.com/watch?v=39h7ZJbRcsw",
 "extractor_key": "Youtube", "live_status": "not_live",
 "formats": [
  {"format_id": "sb0", "ext": "mhtml", "vcodec": "none", "acodec": "none", "format_note": "storyboard", "width": 160, "height": 90},
  {"format_id": "139", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.5", "abr": 48.8, "tbr": 48.8, "filesize": 497000, "audio_ext": "m4a", "video_ext": "none"},
  {"format_id": "251", "ext": "webm", "vcodec": "none", "acodec": "opus", "abr": 130.1, "tbr": 130.1, "filesize": 1300000, "audio_ext": "webm", "video_ext": "none"},
  {"format_id": "140", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 129.5, "tbr": 129.5, "filesize": 1320000, "audio_ext": "m4a", "video_ext": "none"},
  {"format_id": "18", "ext": "mp4", "vcodec": "avc1.42001E", "acodec": "mp4a.40.2", "width": 640, "height": 360, "fps": 24, "tbr": 600, "filesize_approx": 6100000, "audio_ext": "none", "video_ext": "mp4"},
  {"format_id": "136", "ext": "mp4", "vcodec": "avc1.4d401f", "acodec": "none", "width": 1280, "height": 720, "fps": 24, "tbr": 1200, "filesize": 12000000, "audio_ext": "none", "video_ext": "mp4"},
  {"format_id": "137", "ext": "mp4", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080, "fps": 24, "tbr": 2400, "filesize": 24000000, "audio_ext": "none", "video_ext": "mp4"},
  {"format_id": "313", "ext": "webm", "vcodec": "vp9", "acodec": "none", "width": 3840, "height": 2160, "fps": 24, "tbr": 9000, "filesize": 90000000, "audio_ext": "none", "video_ext": "webm"}
 ]}
''';

const _youtubeTab = '''
{"_type": "playlist", "id": "UCz75RVbH8q2jdBJ4SnwuZZQ", "title": "Blender Studio - Videos",
 "uploader": "Blender Studio", "webpage_url": "https://www.youtube.com/@BlenderStudio/videos",
 "extractor_key": "YoutubeTab", "playlist_count": null,
 "entries": [
  {"title": "Raising the Steaks - Blender Studio Log 32", "duration": 855, "ie_key": "Youtube", "id": "Q1fMMYyt0I4", "_type": "url", "url": "https://www.youtube.com/watch?v=Q1fMMYyt0I4",
   "thumbnails": [{"url": "https://i.ytimg.com/vi/Q1fMMYyt0I4/hqdefault.jpg", "height": 202, "width": 360}, {"url": "https://i.ytimg.com/vi/Q1fMMYyt0I4/hq720.jpg", "height": 404, "width": 720}]},
  null,
  {"title": "OVERGROWN - Blender Feature Film (Teaser)", "duration": 82.0, "ie_key": "Youtube", "id": "39h7ZJbRcsw", "_type": "url", "url": "39h7ZJbRcsw"}
 ]}
''';

const _youtubeChannel = '''
{"_type": "playlist", "id": "UCz75RVbH8q2jdBJ4SnwuZZQ", "title": "Blender Studio",
 "extractor_key": "YoutubeTab", "playlist_count": 3,
 "entries": [
  {"_type": "playlist", "title": "Blender Studio - Videos", "webpage_url": "https://www.youtube.com/@BlenderStudio/videos", "extractor_key": "YoutubeTab", "entries": []},
  {"_type": "playlist", "title": "Blender Studio - Shorts", "webpage_url": "https://www.youtube.com/@BlenderStudio/shorts", "extractor_key": "YoutubeTab", "entries": []}
 ]}
''';

/// A direct file link (generic extractor): its one format is at top level.
const _directFile = '''
{"id": "trailer_400p", "title": "trailer_400p", "_type": "video",
 "webpage_url": "https://download.blender.org/peach/trailer/trailer_400p.ogg",
 "extractor_key": "Generic", "format_id": "0", "ext": "ogg", "url": "https://download.blender.org/peach/trailer/trailer_400p.ogg"}
''';

/// stdout + stderr of a real run (generic extractor, FFmpeg present).
const _realRun = r'''
__EXPL_TITLE__trailer_400p
__EXPL_THUMB__NA
__EXPL_P__downloading|1024|4360399|NA|NA|NA|ogg|NA|NA
__EXPL_P__downloading|3072|4360399|NA|2366807.841293167|1|ogg|NA|NA
__EXPL_P__downloading|2096128|4360399|NA|18597769.686360616|0|ogg|NA|NA
__EXPL_P__downloading|4360399|4360399|NA|22844686.20262737|0|ogg|NA|NA
__EXPL_P__finished|4360399|4360399|NA|8030669.9590387875|NA|ogg|NA|NA
__EXPL_PP__started|Metadata
__EXPL_PP__finished|Metadata
__EXPL_PP__started|EmbedThumbnail
__EXPL_PP__finished|EmbedThumbnail
__EXPL_PP__started|MoveFiles
__EXPL_PP__finished|MoveFiles
__EXPL_FILE__C:\Users\me\Downloads\Folder Videos\trailer_400p [trailer_400p].ogg
''';

void main() {
  group('parseInfo', () {
    test('single video with formats', () {
      final info = YtDlpOutputParser.parseInfo(_youtubeVideo, url: 'https://youtu.be/39h7ZJbRcsw');
      expect(info.isPlaylist, isFalse);
      expect(info.title, 'OVERGROWN - Blender Feature Film (Teaser)');
      expect(info.uploader, 'Blender Studio');
      expect(info.duration, 82);
      expect(info.downloadUrl, 'https://www.youtube.com/watch?v=39h7ZJbRcsw');
      expect(info.extractor, 'Youtube');
      expect(info.isLive, isFalse);
      expect(info.formats, hasLength(8));
      expect(info.videoHeights, [2160, 1080, 720, 360]);

      final storyboard = info.formats.firstWhere((f) => f.id == 'sb0');
      expect(storyboard.isStoryboard, isTrue);
      expect(info.pickableFormats.map((f) => f.id), isNot(contains('sb0')));
      expect(info.pickableFormats.first.id, '313', reason: 'best (last listed) first');

      final audio = info.formats.firstWhere((f) => f.id == '140');
      expect(audio.isAudioOnly, isTrue);
      expect(audio.isVideoOnly, isFalse);
      expect(audio.codecLabel, 'AAC');
      expect(audio.shortLabel, 'm4a · 130k');

      final muxed = info.formats.firstWhere((f) => f.id == '18');
      expect(muxed.isAudioOnly || muxed.isVideoOnly, isFalse);
      expect(muxed.filesize, 6100000);
      expect(muxed.filesizeApprox, isTrue);
      expect(muxed.codecLabel, 'H.264 + AAC');

      final videoOnly = info.formats.firstWhere((f) => f.id == '137');
      expect(videoOnly.isVideoOnly, isTrue);
      expect(videoOnly.shortLabel, '1080p · mp4');
      expect(info.formats.firstWhere((f) => f.id == '313').codecLabel, 'VP9');
    });

    test('flat playlist: entries, ID-only URLs, null entries, thumbnails', () {
      final info = YtDlpOutputParser.parseInfo(_youtubeTab, url: 'https://www.youtube.com/@BlenderStudio/videos');
      expect(info.isPlaylist, isTrue);
      expect(info.title, 'Blender Studio - Videos');
      expect(info.entries, hasLength(2));
      expect(info.playlistCount, 2);
      final first = info.entries.first;
      expect(first.index, 1);
      expect(first.url, 'https://www.youtube.com/watch?v=Q1fMMYyt0I4');
      expect(first.duration, 855);
      expect(first.thumbnail, 'https://i.ytimg.com/vi/Q1fMMYyt0I4/hq720.jpg');
      expect(first.isNested, isFalse);
      final second = info.entries[1];
      expect(second.index, 3, reason: 'position in the list, counting the null entry');
      expect(second.url, 'https://www.youtube.com/watch?v=39h7ZJbRcsw');
    });

    test('channel tabs are nested playlists', () {
      final info = YtDlpOutputParser.parseInfo(_youtubeChannel, url: 'https://www.youtube.com/@BlenderStudio');
      expect(info.entries, hasLength(2));
      expect(info.entries.every((e) => e.isNested), isTrue);
      expect(info.entries.first.url, 'https://www.youtube.com/@BlenderStudio/videos');
      expect(info.playlistCount, 3);
    });

    test('direct file: single top-level format', () {
      final info = YtDlpOutputParser.parseInfo(_directFile, url: 'https://download.blender.org/peach/trailer/trailer_400p.ogg');
      expect(info.formats, hasLength(1));
      expect(info.formats.single.ext, 'ogg');
      expect(info.videoHeights, isEmpty);
    });

    test('ignores text before the JSON and rejects non-JSON', () {
      final info = YtDlpOutputParser.parseInfo('WARNING: x\n$_directFile', url: 'u');
      expect(info.title, 'trailer_400p');
      expect(() => YtDlpOutputParser.parseInfo('ERROR: nope', url: 'u'), throwsFormatException);
    });
  });

  group('JobProgressTracker', () {
    test('follows a real run', () {
      final t = JobProgressTracker();
      final lines = const LineSplitter().convert(_realRun);
      var sawPercent = <double?>[];
      for (final line in lines) {
        t.apply(line);
        if (line.startsWith('__EXPL_P__')) sawPercent.add(t.percent);
      }
      expect(t.title, 'trailer_400p');
      expect(t.thumbnail, isNull, reason: 'NA is not a URL');
      expect(sawPercent.first, closeTo(0.0235, 0.001));
      expect(sawPercent.last, 100);
      expect(t.total, 4360399);
      expect(t.downloaded, 4360399);
      expect(t.part, 1);
      expect(t.stage, 'pp:MoveFiles');
      expect(t.filePath, r'C:\Users\me\Downloads\Folder Videos\trailer_400p [trailer_400p].ogg');
      expect(t.errors, isEmpty);
    });

    test('speed, ETA, estimates and fragments', () {
      final t = JobProgressTracker()
        ..apply('__EXPL_P__downloading|500|NA|1000.0|2048.5|7|137|NA|NA');
      expect(t.percent, 50);
      expect(t.total, 1000);
      expect(t.speed, 2048.5);
      expect(t.eta, 7);
      t.apply('__EXPL_P__downloading|123456|NA|NA|NA|NA|hls-720|3|12');
      expect(t.percent, 25, reason: 'fragment 3 of 12');
      expect(t.total, isNull);
      expect(t.speed, isNull);
    });

    test('counts streams of merged formats', () {
      final t = JobProgressTracker()
        ..apply('__EXPL_P__downloading|1|10|NA|NA|NA|137|NA|NA')
        ..apply('__EXPL_P__finished|10|10|NA|NA|NA|137|NA|NA');
      expect(t.part, 1);
      final urgent = t.apply('__EXPL_P__downloading|1|10|NA|NA|NA|140|NA|NA');
      expect(urgent, isFalse);
      expect(t.part, 2);
      expect(t.apply('__EXPL_PP__started|Merger'), isTrue);
      expect(t.stage, 'pp:Merger');
      expect(DownloaderText.stage(t.stage), 'Merging video and audio');
      expect(t.apply('__EXPL_PP__finished|Merger'), isFalse);
    });

    test('collects errors and log', () {
      final t = JobProgressTracker()
        ..apply('WARNING: [youtube] something odd')
        ..apply('ERROR: [youtube] abc123: Video unavailable. This video is private');
      expect(t.errors, ['[youtube] abc123: Video unavailable. This video is private']);
      expect(t.log, hasLength(2));
      expect(t.failureMessage('x'), 'Video unavailable. This video is private');
      expect(JobProgressTracker().failureMessage('exit 1'), 'exit 1');
    });
  });

  group('errorMessage', () {
    test('last ERROR line without the extractor prefix', () {
      const stderr = 'WARNING: [generic] Falling back on generic information extractor\n'
          'ERROR: Unsupported URL: https://example.com/\n';
      expect(YtDlpOutputParser.errorMessage(stderr), 'Unsupported URL: https://example.com/');
      expect(
        YtDlpOutputParser.errorMessage('ERROR: [vimeo] 123: The video is private'),
        'The video is private',
      );
      expect(YtDlpOutputParser.errorMessage('Traceback...\nOSError: boom'), 'OSError: boom');
      expect(YtDlpOutputParser.errorMessage(''), 'yt-dlp failed');
    });
  });

  group('DownloadJob', () {
    test('reads an Android snapshot', () {
      final job = DownloadJob.fromMap({
        'id': 'abc',
        'url': 'https://example.com/v',
        'status': 'running',
        'percent': -1.0,
        'downloaded': 5,
        'total': null,
        'speed': 12.5,
        'eta': 3,
        'stage': 'pp:Merger',
        'part': 2,
        'meta': '{"kind":"audio","label":"MP3 audio"}',
        'createdAt': 1700000000000,
      });
      expect(job.status, JobStatus.running);
      expect(job.percent, isNull);
      expect(job.isPostProcessing, isTrue);
      expect(job.meta['kind'], 'audio');
      expect(job.isActive, isTrue);
      final back = DownloadJob.fromMap(job.toMap());
      expect(back.meta, job.meta);
      expect(back.part, 2);
      expect(back.createdAt, job.createdAt);
    });
  });

  group('DownloaderText', () {
    test('extractUrls', () {
      expect(
        DownloaderText.extractUrls('Watch this: https://youtu.be/abc?t=1. And (https://vimeo.com/1)!'),
        ['https://youtu.be/abc?t=1', 'https://vimeo.com/1'],
      );
      expect(DownloaderText.extractUrls('https://en.wikipedia.org/wiki/Foo_(bar)'),
          ['https://en.wikipedia.org/wiki/Foo_(bar)']);
      expect(DownloaderText.extractUrls('youtube.com/watch?v=x'), ['https://youtube.com/watch?v=x']);
      expect(DownloaderText.extractUrls('just words'), isEmpty);
      expect(DownloaderText.extractUrls('https://a.com/1 https://a.com/1'), ['https://a.com/1']);
    });

    test('formatting', () {
      expect(DownloaderText.bytes(999), '999 B');
      expect(DownloaderText.bytes(4360399), '4.4 MB');
      expect(DownloaderText.bytes(123456789), '123 MB');
      expect(DownloaderText.duration(82), '1:22');
      expect(DownloaderText.duration(3725), '1:02:05');
      expect(DownloaderText.site('Youtube', 'https://www.youtube.com/watch?v=1'), 'youtube.com');
      expect(DownloaderText.stage('pp:FFmpegFixupM3u8'), 'Fixing up the file');
      expect(DownloaderText.stage('pp:ExtractAudio'), 'Converting audio');
    });
  });

  test('SHA2-256SUMS lookup', () {
    const sums = 'aaa111  yt-dlp\n'
        'BBB222  yt-dlp.exe\n'
        'ccc333  yt-dlp_linux\n'
        'ddd444  yt-dlp_linux.zip\n';
    expect(YtDlpInstaller.expectedHash(sums, 'yt-dlp.exe'), 'bbb222');
    expect(YtDlpInstaller.expectedHash(sums, 'yt-dlp_linux'), 'ccc333');
    expect(YtDlpInstaller.expectedHash(sums, 'yt-dlp_macos'), isNull);
  });
}
