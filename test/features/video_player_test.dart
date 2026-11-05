import 'dart:math';

import 'package:explorer/core/services/device_files.dart';
import 'package:explorer/features/toolbox/toolbox_menu.dart';
import 'package:explorer/features/video_player/play_queue.dart';
import 'package:explorer/features/video_player/video_library.dart';
import 'package:explorer/features/video_player/video_library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The video player's library and what it decides by itself. The player needs
/// a real libmpv, so it's tried on a device.
void main() {
  final history = VideoHistory.instance;
  final lists = VideoPlaylists.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    history.reset();
    lists.reset();
    VideoLibrary.findOverride = null;
  });

  group('the queue', () {
    test('goes through in order, and stops at the end', () {
      final queue = PlayQueue(['a', 'b', 'c'], index: 1);
      expect(queue.current, 'b');
      expect(queue.hasPrevious, isTrue);
      expect(queue.afterFinished(), 'c');
      expect(queue.hasNext, isFalse);
      expect(queue.afterFinished(), isNull, reason: 'all over');
      expect(queue.current, 'c', reason: 'stays on the last');
    });

    test('Previous returns the way it came', () {
      final queue = PlayQueue(['a', 'b', 'c']);
      queue.moveNext();
      queue.moveNext();
      expect(queue.movePrevious(), isTrue);
      expect(queue.current, 'b');
      expect(queue.movePrevious(), isTrue);
      expect(queue.current, 'a');
      expect(queue.movePrevious(), isFalse);
    });

    test('repeats one, or all', () {
      final one = PlayQueue(['a', 'b'])..repeat = VideoRepeat.one;
      expect(one.afterFinished(), 'a');
      final all = PlayQueue(['a', 'b'], index: 1)..repeat = VideoRepeat.all;
      expect(all.hasNext, isTrue);
      expect(all.afterFinished(), 'a');
    });

    test('a single video repeats only when told to', () {
      expect(PlayQueue(['a'])..repeat = VideoRepeat.all, isA<PlayQueue>().having((q) => q.afterFinished(), 'next', isNull));
      expect((PlayQueue(['a'])..repeat = VideoRepeat.one).afterFinished(), 'a');
    });

    test('shuffle never plays the same one twice in a row, and Previous undoes it', () {
      final queue = PlayQueue(['a', 'b', 'c', 'd'], random: Random(7))..shuffle = true;
      final order = <String>['a'];
      for (var i = 0; i < 40; i++) {
        final before = queue.current;
        expect(queue.moveNext(), isTrue);
        expect(queue.current, isNot(before));
        order.add(queue.current);
      }
      expect(order.toSet(), hasLength(4), reason: 'gets to all of them');
      queue.movePrevious();
      expect(queue.current, order[order.length - 2]);
    });

    test("the folder joining in keeps what's playing", () {
      final queue = PlayQueue(['b.mp4']);
      queue.replaceAll(['a.mp4', 'b.mp4', 'c.mp4']);
      expect(queue.current, 'b.mp4');
      expect(queue.index, 1);
      expect(queue.hasNext && queue.hasPrevious, isTrue);
    });
  });

  test('subtitles beside a video are its own, the plain name first', () {
    final found = subtitlesBeside('/v/Movie.2024.mkv', [
      '/v/Movie.2024.en.srt',
      '/v/movie.2024.SRT',
      '/v/Movie.2024.mkv',
      '/v/Other.srt',
      '/v/Movie.2024.txt',
      '/v/Movie.2024.fr.ass',
    ]);
    expect(found, ['/v/movie.2024.SRT', '/v/Movie.2024.en.srt', '/v/Movie.2024.fr.ass']);
  });

  test('times, titles and addresses', () {
    expect(formatVideoTime(const Duration(seconds: 65)), '01:05');
    expect(formatVideoTime(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');

    expect(videoTitle(p.join('v', 'Movie.mkv')), 'Movie.mkv');
    expect(videoTitle('https://example.com/live/stream%201.m3u8?token=x'), 'stream 1.m3u8');
    expect(videoTitle('rtsp://camera.local'), 'camera.local');

    expect(cleanStreamAddress('  https://example.com/a.m3u8 '), 'https://example.com/a.m3u8');
    expect(cleanStreamAddress('rtsp://10.0.0.5:554/cam'), 'rtsp://10.0.0.5:554/cam');
    expect(cleanStreamAddress('example.com/live'), 'https://example.com/live');
    expect(cleanStreamAddress(''), isNull);
    expect(cleanStreamAddress('not an address'), isNull);
  });

  group('the library', () {
    DeviceFile video(String path, {int size = 10, DateTime? modified}) =>
        DeviceFile(path, size, modified ?? DateTime(2020));

    test('by folder, the folders by name whatever their case', () {
      final folders = VideoLibrary.foldersOf([
        video('/m/zoo/a.mp4'),
        video('/m/Beach/b.mp4'),
        video('/m/zoo/c.mp4'),
        video('/m/alpha/d.mp4'),
      ]);
      expect([for (final f in folders) f.name], ['alpha', 'Beach', 'zoo']);
      expect(folders.last.videos, hasLength(2));
    });

    test('new is recent and never played', () async {
      final now = DateTime(2026, 11, 5);
      final fresh = video('/m/a.mp4', modified: now.subtract(const Duration(days: 2)));
      final old = video('/m/b.mp4', modified: now.subtract(const Duration(days: 30)));
      expect(history.isNew(fresh, now: now), isTrue);
      expect(history.isNew(old, now: now), isFalse);
      await history.record(fresh.path, const Duration(seconds: 1), const Duration(minutes: 1));
      expect(history.isNew(fresh, now: now), isFalse);
    });

    test('remembers where it stopped, and what came last, across runs', () async {
      await history.record('/m/a.mp4', const Duration(minutes: 1), const Duration(minutes: 2));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await history.record('/x/b.mp4', const Duration(minutes: 9), const Duration(minutes: 10));

      history.reset();
      await history.load();
      expect(history.progressOf('/m/a.mp4')?.fraction, 0.5);
      expect(history.progressOf('/m/a.mp4')?.finished, isFalse);
      expect(history.progressOf('/x/b.mp4')?.position, const Duration(minutes: 9));
      expect(history.lastPlayed, '/x/b.mp4');
      expect(history.lastFolder, p.dirname('/x/b.mp4'));
      expect(history.recent, ['/x/b.mp4', '/m/a.mp4']);
    });

    test('near the end counts as seen', () async {
      await history.record('/m/a.mp4', const Duration(seconds: 97), const Duration(seconds: 100));
      expect(history.progressOf('/m/a.mp4')?.finished, isTrue);
    });

    test('a stream is no folder, and addresses are kept newest first', () async {
      await history.record('https://x.org/a.m3u8', const Duration(seconds: 1), Duration.zero);
      expect(history.lastFolder, isNull);
      expect(history.recent, isEmpty);
      await history.addStream('a');
      await history.addStream('b');
      await history.addStream('a');
      expect(history.streams, ['a', 'b']);
    });

    test('playlists: each video once, and they last', () async {
      await lists.create('Trips');
      await lists.add('Trips', '/m/a.mp4');
      await lists.add('Trips', '/m/a.mp4');
      await lists.add('Trips', '/m/b.mp4');
      await lists.remove('Trips', '/m/a.mp4');
      lists.reset();
      await lists.load();
      expect(lists.names, ['Trips']);
      expect(lists.videosOf('Trips'), ['/m/b.mp4']);
      await lists.delete('Trips');
      expect(lists.names, isEmpty);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<void> openLibrary(WidgetTester tester, List<DeviceFile> videos) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      VideoLibrary.findOverride = () async => videos;
      await tester.pumpWidget(themedApp(const VideoLibraryScreen()));
      await settle(tester);
    }

    testWidgets('folders, how many videos, how many new, and the last played marked', (tester) async {
      final recent = DateTime.now().subtract(const Duration(days: 1));
      await history.load();
      await history.record('/m/Beach/seen.mp4', const Duration(seconds: 5), const Duration(minutes: 1));
      await openLibrary(tester, [
        video('/m/Beach/seen.mp4', modified: recent),
        video('/m/Beach/fresh1.mp4', modified: recent),
        video('/m/Beach/fresh2.mp4', modified: recent),
        video('/m/Work/old.mp4'),
      ]);
      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Beach'), findsOneWidget);
      expect(find.text('3 videos'), findsOneWidget);
      expect(find.text('1 video'), findsOneWidget);
      expect(find.text('2'), findsOneWidget, reason: 'two new in Beach, none in Work');

      Color? colorOf(String name) => tester.widget<Text>(find.text(name)).style?.color;
      expect(colorOf('Beach'), isNot(colorOf('Work')), reason: 'where playing was last');
      for (final chip in ['Network stream', 'Playlists', 'Recent']) {
        expect(find.text(chip), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a folder lists its videos, the new ones marked', (tester) async {
      await openLibrary(tester, [
        video('/m/Beach/fresh.mp4', modified: DateTime.now().subtract(const Duration(days: 1))),
        video('/m/Beach/old.mp4'),
      ]);
      await tester.tap(find.text('Beach'));
      await settle(tester);
      expect(find.text('fresh.mp4'), findsOneWidget);
      expect(find.text('old.mp4'), findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('search finds videos across the folders', (tester) async {
      await openLibrary(tester, [video('/m/Beach/Sunset.mp4'), video('/m/Work/report.mp4')]);
      await tester.tap(find.byTooltip('Search'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'sun');
      await settle(tester);
      expect(find.text('Sunset.mp4'), findsOneWidget);
      expect(find.text('report.mp4'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a grid is a tap away, and stays', (tester) async {
      await openLibrary(tester, [video('/m/Beach/a.mp4')]);
      await tester.tap(find.byTooltip('Grid'));
      await settle(tester);
      expect(find.byTooltip('List'), findsOneWidget);
      expect((await SharedPreferences.getInstance()).getBool('video_library_grid'), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("a stream's address is asked for, and a bad one said so", (tester) async {
      await openLibrary(tester, const []);
      expect(find.text('No videos yet'), findsOneWidget);
      await tester.tap(find.text('Network stream'));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'not an address');
      await tester.tap(find.text('Play'));
      await settle(tester);
      expect(find.text("That doesn't look like an address"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('the Toolbox finds the player', () {
    expect(Tool.fromRoute('tool/video_player'), Tool.videoPlayer);
    expect(Tool.videoPlayer.screen, isA<VideoLibraryScreen>());
    expect(Tool.videoPlayer.shortcut.arguments, ['--route=tool/video_player']);
  });
}
