import 'dart:async';
import 'dart:io';

import 'package:folder/core/services/video_downloader/downloader_backend.dart';
import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folder/core/services/video_downloader/ytdlp_models.dart';
import 'package:folder/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:folder/features/video_downloader/screens/video_downloader_settings_screen.dart';
import 'package:folder/features/video_downloader/widgets/history_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

const _info = '''
{"id": "abc", "title": "Test clip", "uploader": "Someone", "duration": 75, "_type": "video",
 "webpage_url": "https://example.com/watch/abc", "extractor_key": "Example",
 "formats": [
  {"format_id": "a1", "ext": "m4a", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128, "filesize": 1000000},
  {"format_id": "v360", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "height": 360, "width": 640, "filesize": 3000000},
  {"format_id": "v720", "ext": "mp4", "vcodec": "avc1", "acodec": "none", "height": 720, "width": 1280, "filesize": 9000000}
 ]}
''';

const _playlist = '''
{"_type": "playlist", "id": "pl", "title": "A playlist", "webpage_url": "https://example.com/pl",
 "entries": [
  {"_type": "url", "url": "https://example.com/watch/1", "title": "First", "duration": 10},
  {"_type": "url", "url": "https://example.com/watch/2", "title": "Second", "duration": 20},
  {"_type": "playlist", "webpage_url": "https://example.com/pl/tab", "title": "Nested", "extractor_key": "ExampleTab"}
 ]}
''';

/// In-memory backend: jobs "download" when told to.
class FakeBackend extends VideoDownloaderBackend {
  final _events = StreamController<BackendEvent>.broadcast();
  final jobsById = <String, DownloadJob>{};
  final specs = <JobSpec>[];

  /// Android's downloaded engine; null like desktop.
  EngineInfo? engine;
  int engineDownloads = 0;

  /// Holds the engine download until completed (or cancelled).
  Completer<void>? holdDownload;

  /// Whether FFmpeg is found.
  bool ffmpeg = true;

  /// Holds the next status: what it says is what was found when asked.
  Completer<void>? holdStatus;

  @override
  Future<BackendStatus> status() async {
    final found = BackendStatus(
      ready: engine?.installed ?? true,
      needsSetup: !(engine?.installed ?? true),
      hasFfmpeg: ffmpeg,
      engine: engine,
    );
    final hold = holdStatus;
    holdStatus = null;
    await hold?.future;
    return found;
  }

  @override
  Future<void> prepare({void Function(double? progress, String message)? onProgress}) async {
    final e = engine;
    if (e == null || e.installed) return;
    engineDownloads++;
    onProgress?.call(0.25, 'Downloading the video engine: 12 of 50 MB');
    await holdDownload?.future;
    engine = EngineInfo(installed: true, downloadBytes: e.downloadBytes, diskBytes: e.diskBytes);
  }

  @override
  Future<void> cancelPrepare() async =>
      holdDownload?.completeError(const DownloaderException('Cancelled', cancelled: true));

  @override
  Future<void> removeEngine() async {
    final e = engine!;
    engine = EngineInfo(installed: false, downloadBytes: e.downloadBytes, diskBytes: e.diskBytes);
  }

  @override
  Future<String?> version() async => '2026.08.19';

  /// Holds yt-dlp updates until completed.
  Completer<void>? holdUpdate;
  bool updateRunning = false;

  /// For each fetch, whether an update was running.
  final fetchedDuringUpdate = <bool>[];

  @override
  Future<UpdateResult> update() async {
    updateRunning = true;
    await holdUpdate?.future;
    updateRunning = false;
    return const UpdateResult(updated: false, version: '2026.08.19');
  }

  @override
  Future<BackendPaths> paths() async =>
      const BackendPaths(defaultOutputDir: '/downloads/Folder Videos', workRoot: '/tmp/work');

  @override
  Future<bool> canWrite(String dir) async => true;

  @override
  Future<String> fetchInfoJson(String url, {required String requestId}) async {
    fetchedDuringUpdate.add(updateRunning);
    return url.contains('/pl') ? _playlist : _info;
  }

  @override
  Future<void> cancelFetch(String requestId) async {}

  @override
  Stream<BackendEvent> get events => _events.stream;

  void emit(DownloadJob job) {
    jobsById[job.id] = job;
    _events.add(JobChanged(job));
  }

  @override
  Future<void> enqueue(JobSpec spec) async {
    specs.add(spec);
    emit(DownloadJob(
      id: spec.id,
      url: spec.url,
      title: spec.title,
      status: JobStatus.running,
      createdAt: DateTime.now(),
      percent: 42,
      downloaded: 4200000,
      total: 10000000,
      speed: 1500000,
      eta: 4,
      stage: 'download',
      part: 1,
      meta: spec.meta,
    ));
  }

  @override
  Future<void> cancel(String id) async {
    final j = jobsById[id]!;
    emit(DownloadJob(id: id, url: j.url, title: j.title, status: JobStatus.cancelled, createdAt: j.createdAt));
  }

  @override
  Future<void> retry(String id) async {}

  @override
  Future<void> remove(String id) async {
    jobsById.remove(id);
    _events.add(JobRemoved(id));
  }

  @override
  Future<List<DownloadJob>> jobs() async => jobsById.values.toList();
}

Widget _app(Widget home) => themedApp(home);

void main() {
  late FakeBackend backend;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakeBackend();
    VideoDownloaderController.instance = VideoDownloaderController(backend);
  });

  Future<void> pumpScreen(WidgetTester tester, Size size, {String? url}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(VideoDownloaderScreen(initialUrl: url)));
    await tester.pumpAndSettle();
  }

  testWidgets('phone: notice, fetch shared link, download, queue', (tester) async {
    await pumpScreen(tester, const Size(390, 844), url: 'Look https://example.com/watch/abc');
    expect(find.text('Before you download'), findsOneWidget);
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    // The shared link was fetched right away.
    expect(find.text('Test clip'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('1080p'), findsNothing, reason: 'no format that tall');
    await tester.tap(find.text('720p'));
    await tester.pumpAndSettle();
    expect(find.textContaining('About 10 MB'), findsOneWidget);

    final panel = find
        .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first;
    final download = find.widgetWithText(FilledButton, 'Download');
    await tester.scrollUntilVisible(download, 100, scrollable: panel);
    await tester.ensureVisible(download);
    await tester.pumpAndSettle();
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(backend.specs, hasLength(1));
    expect(backend.specs.single.args, containsAllInOrder(['--format-sort', 'res:720,fps,vcodec:h264,acodec:aac']));
    expect(backend.specs.single.outputDir, '/downloads/Folder Videos');
    // Ready for the next link.
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.text('Test clip'), findsNothing);

    await tester.tap(find.text('Downloads (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.textContaining('1.5 MB/s'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cancelled'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('No downloads yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet: playlist selection and side pane', (tester) async {
    await pumpScreen(tester, const Size(1280, 800));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'https://example.com/pl');
    await tester.pump(); // the Fetch button enables on the next frame
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(find.text('A playlist'), findsOneWidget);
    expect(find.text('2 of 2 selected'), findsOneWidget);
    final panel = find
        .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('Open'), 100, scrollable: panel);
    expect(find.text('Open'), findsOneWidget, reason: 'nested playlist');

    await tester.tap(find.text('1. First'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 selected'), findsOneWidget);
    await tester.ensureVisible(find.text('Download 1 item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download 1 item'));
    await tester.pumpAndSettle();
    expect(backend.specs.single.url, 'https://example.com/watch/2');
    expect(backend.specs.single.outputDir, p.join('/downloads/Folder Videos', 'A playlist'));
    // The queue is visible beside the panel.
    expect(find.textContaining('42%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a copied link is put in the field, once', (tester) async {
    var clipboard = 'Watch this: https://example.com/watch/copied';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    String field() => tester.widget<TextField>(find.byType(TextField)).controller!.text;

    await pumpScreen(tester, const Size(1280, 800));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    expect(field(), 'https://example.com/watch/copied');
    expect(find.text('Test clip'), findsNothing, reason: 'filled in, not fetched');

    // Cleared: coming back to the app doesn't put the same link back.
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(field(), isEmpty);

    // A new link copied meanwhile is.
    clipboard = 'https://example.com/watch/abc';
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(field(), 'https://example.com/watch/abc');
    expect(tester.takeException(), isNull);
  });

  const missingEngine = EngineInfo(installed: false, downloadBytes: 49930835, diskBytes: 119773698);

  testWidgets('engine: asks before downloading it; nothing works without it', (tester) async {
    backend.engine = missingEngine;
    await pumpScreen(tester, const Size(390, 844));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    expect(find.text('Download the video engine?'), findsOneWidget);
    expect(find.textContaining('50 MB, Wi-Fi recommended'), findsOneWidget);
    expect(find.text('120 MB'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(backend.engineDownloads, 0);
    expect(find.text('Download the video engine to start'), findsOneWidget);

    // Fetching asks again; agreeing downloads it, then the fetch goes on.
    await tester.enterText(find.byType(TextField), 'https://example.com/watch/abc');
    await tester.pump();
    await tester.tap(find.text('Fetch'));
    await tester.pumpAndSettle();
    expect(find.text('Download the video engine?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    await tester.pumpAndSettle();
    expect(backend.engineDownloads, 1);
    expect(find.text('Download the video engine to start'), findsNothing);
    expect(find.text('Test clip'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('engine: the download can be cancelled', (tester) async {
    backend.engine = missingEngine;
    backend.holdDownload = Completer<void>();
    await pumpScreen(tester, const Size(390, 844));
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    // A spinner runs while downloading, so no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Downloading the video engine: 12 of 50 MB'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Download the video engine to start'), findsOneWidget);
    expect(find.textContaining("couldn't"), findsNothing, reason: 'cancelling is no error');

    // The card's button downloads without asking again.
    backend.holdDownload = null;
    await tester.ensureVisible(find.text('Download (50 MB)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download (50 MB)'));
    await tester.pumpAndSettle();
    expect(find.text('Download the video engine?'), findsNothing);
    expect(find.text('Download the video engine to start'), findsNothing);
    expect(backend.engine!.installed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: the engine can be removed', (tester) async {
    backend.engine = const EngineInfo(installed: true, downloadBytes: 49930835, diskBytes: 119773698);
    final controller = VideoDownloaderController.instance;
    await controller.start();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(VideoDownloaderSettingsScreen(controller: controller)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Video engine'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Python and FFmpeg, 120 MB'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove the video engine?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(backend.engine!.installed, isFalse);
    expect(find.textContaining('Not downloaded'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Download'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the first fetch waits for the automatic yt-dlp update', () async {
    // yt-dlp can't run while the update replaces its file.
    backend.holdUpdate = Completer<void>();
    final fetch = VideoDownloaderController.instance.fetchInfo('https://example.com/watch/abc');
    await pumpEventQueue();
    expect(backend.updateRunning, isTrue);
    expect(backend.fetchedDuringUpdate, isEmpty);
    backend.holdUpdate!.complete();
    expect((await fetch).title, 'Test clip');
    expect(backend.fetchedDuringUpdate, [false]);
  });

  testWidgets('history: a playlist\'s downloads are in a folder named after it', (tester) async {
    await pumpScreen(tester, const Size(390, 844), url: 'https://example.com/pl');
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    final panel = find
        .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first;
    final download = find.text('Download 2 items');
    await tester.scrollUntilVisible(download, 100, scrollable: panel);
    await tester.ensureVisible(download);
    await tester.pumpAndSettle();
    await tester.tap(download);
    await tester.pumpAndSettle();
    expect(backend.specs, hasLength(2));

    // Both finish. Moving them to the history reads the files (real I/O),
    // so let real time pass between frames.
    for (final spec in backend.specs) {
      backend.emit(DownloadJob(
        id: spec.id,
        url: spec.url,
        title: spec.title,
        status: JobStatus.done,
        createdAt: DateTime.now(),
        filePath: p.join(spec.outputDir, '${spec.title}.mp4'),
        meta: spec.meta,
      ));
    }
    final controller = VideoDownloaderController.instance;
    for (var i = 0; i < 40 && controller.history.length < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controller.history, hasLength(2));
    await tester.pumpAndSettle();

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('A playlist'), findsOneWidget);
    expect(find.textContaining('2 downloads ·'), findsOneWidget);
    expect(find.text('First'), findsNothing, reason: 'inside the folder');

    await tester.tap(find.text('A playlist'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(VideoDownloaderController.instance.history.map((h) => h.playlist),
        everyElement('A playlist'));

    await tester.tap(find.text('Remove from history'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('No downloads yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('groupHistory', () {
    HistoryEntry entry(String id, String path, {String? playlist}) => HistoryEntry(
          id: id,
          title: id,
          url: 'https://example.com/$id',
          filePath: path,
          completedAt: DateTime(2026, 10, 23),
          playlist: playlist,
        );
    final out = p.join('downloads', 'Folder Videos');

    test('gathers a playlist where its newest download is', () {
      final items = groupHistory([
        entry('single', p.join(out, 'single.mp4')),
        entry('b2', p.join(out, 'B', 'b2.mp4'), playlist: 'B'),
        entry('a2', p.join(out, 'A', 'a2.mp4'), playlist: 'A'),
        entry('b1', p.join(out, 'B', 'b1.mp4'), playlist: 'B'),
        entry('old', p.join(out, 'old.mp4')),
      ], out);
      expect(items, hasLength(4));
      expect((items[0] as HistoryEntry).id, 'single');
      expect((items[1] as HistoryFolder).name, 'B');
      expect([for (final e in (items[1] as HistoryFolder).entries) e.id], ['b2', 'b1']);
      expect((items[2] as HistoryFolder).name, 'A');
      expect((items[3] as HistoryEntry).id, 'old');
    });

    test('earlier downloads in a playlist folder count as the playlist', () {
      final items = groupHistory([
        entry('x', p.join(out, 'Mix', 'x.mp4')),
        entry('y', p.join(out, 'Mix', 'y.mp4')),
        entry('elsewhere', p.join('somewhere', 'Else', 'z.mp4')),
      ], out);
      expect(items, hasLength(2));
      expect((items[0] as HistoryFolder).name, 'Mix');
      expect((items[0] as HistoryFolder).entries, hasLength(2));
      expect((items[1] as HistoryEntry).id, 'elsewhere');
    });
  });

  testWidgets('macOS: reopening the downloader finds FFmpeg installed since', (tester) async {
    SharedPreferences.setMockInitialValues({'video_downloader.rights_accepted': true});
    backend.ffmpeg = false;
    await pumpScreen(tester, const Size(390, 844));
    final controller = VideoDownloaderController.instance;
    expect(controller.hasFfmpeg, isFalse);

    await tester.pumpWidget(const SizedBox());
    backend.ffmpeg = true; // brew install ffmpeg
    await pumpScreen(tester, const Size(390, 844));
    expect(controller.hasFfmpeg, isTrue);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isMacOS);

  testWidgets('macOS: reopening asks for less once FFmpeg is installed', (tester) async {
    SharedPreferences.setMockInitialValues({'video_downloader.rights_accepted': true});
    backend
      ..engine = missingEngine
      ..ffmpeg = false;
    await pumpScreen(tester, const Size(390, 844));
    expect(find.textContaining('50 MB, Wi-Fi recommended'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    backend
      ..ffmpeg = true // brew install ffmpeg: the engine needs no FFmpeg now
      ..engine = const EngineInfo(installed: false, downloadBytes: 36000000, diskBytes: 60000000);
    await pumpScreen(tester, const Size(390, 844));
    expect(find.textContaining('36 MB, Wi-Fi recommended'), findsOneWidget);
    expect(VideoDownloaderController.instance.hasFfmpeg, isTrue);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isMacOS);

  testWidgets('macOS: an engine download that ends while reopening stays done', (tester) async {
    SharedPreferences.setMockInitialValues({'video_downloader.rights_accepted': true});
    backend
      ..engine = missingEngine
      ..ffmpeg = false
      ..holdDownload = Completer<void>();
    await pumpScreen(tester, const Size(390, 844));
    await tester.tap(find.widgetWithText(FilledButton, 'Download'));
    // A spinner runs while downloading, so no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final controller = VideoDownloaderController.instance;
    expect(controller.engineState, EngineState.preparing);

    // Reopened while downloading; the download ends while FFmpeg is
    // looked for again.
    await tester.pumpWidget(const SizedBox());
    backend.ffmpeg = true;
    final status = backend.holdStatus = Completer<void>();
    await tester.pumpWidget(_app(const VideoDownloaderScreen()));
    await tester.pump();
    backend.holdDownload!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.engineState, EngineState.ready);
    status.complete();
    await tester.pumpAndSettle();
    expect(controller.engine!.installed, isTrue);
    expect(controller.hasFfmpeg, isTrue);
    expect(find.text('Download the video engine to start'), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isMacOS);

  testWidgets('settings screen builds', (tester) async {
    final controller = VideoDownloaderController.instance;
    await controller.start();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(VideoDownloaderSettingsScreen(controller: controller)));
    await tester.pumpAndSettle();
    expect(find.text('Downloader settings'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Licenses'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Licenses'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
