import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folder/features/video_player/online_subtitles.dart';
import 'package:folder/features/video_player/video_player_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Finding subtitles online: what a file's name says, what gets asked, and
/// where they land. The real service is tried by hand on a device.
void main() {
  late Directory root;
  final asked = <Uri>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_online_subs');
    asked.clear();
    SubtitleSearch.fetchOverride = null;
  });

  tearDown(() async {
    SubtitleSearch.fetchOverride = null;
    await root.delete(recursive: true);
  });

  group('what a file name says', () {
    void expectGuess(String file, String name, {int? year, int? season, int? episode}) {
      final guess = guessVideoTitle(file);
      expect(guess.name, name, reason: file);
      expect(guess.year, year, reason: file);
      expect(guess.season, season, reason: file);
      expect(guess.episode, episode, reason: file);
    }

    test('films', () {
      expectGuess('Inception.2010.1080p.BluRay.x264-GROUP.mkv', 'Inception', year: 2010);
      expectGuess('Inception (2010) [BluRay].mp4', 'Inception', year: 2010);
      expectGuess('The_Dark_Knight_720p.mkv', 'The Dark Knight');
      expectGuess('[Group] Spirited Away.mkv', 'Spirited Away');
      expectGuess('Home video.mp4', 'Home video');
    });

    test('a film named for a year keeps its name', () {
      expectGuess('2012.2009.720p.mkv', '2012', year: 2009);
      expectGuess('1917.mp4', '1917');
    });

    test('episodes, however they are written', () {
      expectGuess('Backstreet_Rookie_S01_E11.1080p.mkv', 'Backstreet Rookie', season: 1, episode: 11);
      expectGuess('Breaking.Bad.S05E14.Ozymandias.mkv', 'Breaking Bad', season: 5, episode: 14);
      expectGuess('The Office 2x03.mp4', 'The Office', season: 2, episode: 3);
      expectGuess('Dark - S02 E08 - title.mkv', 'Dark', season: 2, episode: 8);
    });

    test('a stream goes by the last part of its address', () {
      expectGuess('https://example.com/films/Inception.2010.m3u8?x=1', 'Inception', year: 2010);
    });
  });

  group('finding titles', () {
    const film = SubtitleTitle(id: 'tt1', name: 'Dark', year: '2005', isSeries: false);
    const series = SubtitleTitle(id: 'tt2', name: 'Dark', year: '2017', isSeries: true);
    const other = SubtitleTitle(id: 'tt3', name: 'The Dark', year: '2017', isSeries: true);

    test('the name asked for first, then the year, then a series for an episode', () {
      expect(
        SubtitleSearch.rankTitles([other, film, series], 'Dark', const GuessedTitle('Dark', season: 1, episode: 1)),
        [series, film, other],
      );
      expect(SubtitleSearch.rankTitles([series, film], 'Dark', const GuessedTitle('Dark', year: 2005)), [film, series]);
    });

    test('an IMDb id needs no search', () async {
      SubtitleSearch.fetchOverride = (uri) async => throw StateError('asked for $uri');
      final titles = await SubtitleSearch.titles('tt1375666');
      expect(titles.single.id, 'tt1375666');
      expect(SubtitleSearch.isSure(titles.single, 'tt1375666'), isTrue);
    });

    test('asks for films and series, by the encoded name', () async {
      SubtitleSearch.fetchOverride = (uri) async {
        asked.add(uri);
        final isSeries = uri.path.contains('/series/');
        return utf8.encode(jsonEncode({
          'metas': [
            {'id': isSeries ? 'tt2' : 'tt1', 'name': isSeries ? 'A Show' : 'A Film', 'releaseInfo': '2001'},
            {'id': 'kitsu:1', 'name': 'Not from IMDb'},
          ],
        }));
      };
      final titles = await SubtitleSearch.titles('a b');
      expect({for (final uri in asked) uri.toString()}, {
        'https://v3-cinemeta.strem.io/catalog/movie/top/search=a%20b.json',
        'https://v3-cinemeta.strem.io/catalog/series/top/search=a%20b.json',
      });
      expect([for (final t in titles) t.id], unorderedEquals(['tt1', 'tt2']));
    });
  });

  group('finding subtitles', () {
    Future<List<int>> respond(Uri uri, List<Map<String, Object?>> rows) async {
      asked.add(uri);
      return utf8.encode(jsonEncode({'subtitles': rows}));
    }

    const film = SubtitleTitle(id: 'tt1', name: 'Film', isSeries: false);
    const series = SubtitleTitle(id: 'tt2', name: 'Show', isSeries: true);

    test('a series asks for its episode', () async {
      SubtitleSearch.fetchOverride = (uri) => respond(uri, const []);
      await SubtitleSearch.search(series, season: 2, episode: 7);
      expect(asked.single.toString(), 'https://opensubtitles-v3.strem.io/subtitles/series/tt2:2:7.json');
    });

    test('a local file sends its hash and size, not its name', () async {
      final video = File(p.join(root.path, 'My private name.mp4'));
      await video.writeAsBytes(Uint8List(200 * 1024));
      SubtitleSearch.fetchOverride = (uri) => respond(uri, const []);
      await SubtitleSearch.search(film, video: video.path);
      final hash = (200 * 1024).toRadixString(16).padLeft(16, '0');
      expect(asked.single.toString(), 'https://opensubtitles-v3.strem.io/subtitles/movie/tt1/videoHash=$hash&videoSize=${200 * 1024}.json');
      expect(asked.single.toString(), isNot(contains('private')));
    });

    test('rows without an address are left out', () async {
      SubtitleSearch.fetchOverride = (uri) => respond(uri, [
            {'lang': 'eng'},
            {'url': 'https://x/1', 'lang': 'hin', 'subtitleFileName': 'a.srt'},
          ]);
      final found = await SubtitleSearch.search(film);
      expect(found.single.language, 'hin');
    });

    test('closest to the file first, an exact match before all', () {
      const exact = OnlineSubtitle(url: 'e', language: 'eng', fileName: 'x.srt', release: 'x', matchesFile: true);
      const near = OnlineSubtitle(url: 'n', language: 'eng', fileName: '', release: 'Movie.2010.BluRay.x265-GRP');
      const far = OnlineSubtitle(url: 'f', language: 'eng', fileName: '', release: 'Movie.2010.CAM');
      expect(SubtitleSearch.ranked([far, near, exact], 'Movie.2010.1080p.BluRay.x265-GRP.mkv'), [exact, near, far]);
    });
  });

  group("a file's hash", () {
    test('is its size plus its words, wrapping at 64 bits', () async {
      final bytes = Uint8List(128 * 1024);
      final words = ByteData.sublistView(bytes);
      words.setUint64(0, 0x0102030405060708, Endian.little);
      words.setUint64(128 * 1024 - 8, 0x1000000000000000, Endian.little);
      final file = await File(p.join(root.path, 'v.bin')).writeAsBytes(bytes);
      expect(await SubtitleSearch.fileHash(file.path), '1102030405080708');
    });

    test("that's negative as a Dart int still comes out as 16 digits", () async {
      final bytes = Uint8List(128 * 1024);
      ByteData.sublistView(bytes).setUint64(0, 0xF000000000000000, Endian.little);
      final file = await File(p.join(root.path, 'v.bin')).writeAsBytes(bytes);
      expect(await SubtitleSearch.fileHash(file.path), 'f000000000020000');
    });

    test('a file too small has none', () async {
      final file = await File(p.join(root.path, 'v.bin')).writeAsBytes(Uint8List(100));
      expect(await SubtitleSearch.fileHash(file.path), isNull);
    });
  });

  group('saving', () {
    const subtitle = OnlineSubtitle(url: 'https://x/1', language: 'eng', fileName: 'Other.name.srt', release: '');

    setUp(() {
      SubtitleSearch.fetchOverride = (uri) async => utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHi\n');
    });

    test('beside the video, under its name, where the player finds it next time', () async {
      final video = p.join(root.path, 'Movie.mkv');
      final path = await SubtitleSearch.download(subtitle, video: video);
      expect(path, p.join(root.path, 'Movie.eng.srt'));
      expect(File(path).readAsStringSync(), contains('Hi'));
    });

    test('never over a file already there', () async {
      final video = p.join(root.path, 'Movie.mkv');
      final mine = File(p.join(root.path, 'Movie.eng.srt'))..writeAsStringSync('mine');
      final path = await SubtitleSearch.download(subtitle, video: video);
      expect(path, p.join(root.path, 'Movie.eng.2.srt'));
      expect(mine.readAsStringSync(), 'mine');
    });

    test('keeps a format it knows, and calls the rest .srt', () async {
      final video = p.join(root.path, 'Movie.mkv');
      const ass = OnlineSubtitle(url: 'u', language: 'hin', fileName: 'x.ASS', release: '');
      const odd = OnlineSubtitle(url: 'u', language: 'tam', fileName: 'x.zip', release: '');
      expect(p.basename(await SubtitleSearch.download(ass, video: video)), 'Movie.hin.ass');
      expect(p.basename(await SubtitleSearch.download(odd, video: video)), 'Movie.tam.srt');
    });

    test('for a stream, or a folder that cannot be written, in a temporary one', () async {
      final temporary = Directory(p.join(root.path, 'tmp'));
      final stream = await SubtitleSearch.download(subtitle, video: 'https://x.org/live/Show.m3u8', temporary: temporary);
      expect(stream, p.join(temporary.path, 'subtitles', 'Show.eng.srt'));

      // A plain file where the folder should be.
      final blocked = File(p.join(root.path, 'blocked'))..writeAsStringSync('');
      final saved = await SubtitleSearch.download(subtitle, video: p.join(blocked.path, 'Movie.mkv'), temporary: temporary);
      expect(saved, p.join(temporary.path, 'subtitles', 'Movie.eng.srt'));
    });
  });

  test('the first language: as picked last, the device, English, the commonest', () {
    const available = {'eng': 2, 'hin': 3, 'fre': 9};
    expect(firstLanguage(available, saved: 'fre', deviceLanguage: 'hi'), 'fre');
    expect(firstLanguage(available, saved: 'kor', deviceLanguage: 'hi'), 'hin');
    expect(firstLanguage(available, deviceLanguage: 'ja'), 'eng');
    expect(firstLanguage(const {'tur': 1, 'ara': 4}, deviceLanguage: 'ja'), 'ara');
    expect(firstLanguage(const {}), isNull);
  });

  test('language names, and an unknown code as it is', () {
    expect(subtitleLanguageName('hin'), 'Hindi');
    expect(subtitleLanguageName('pob'), 'Portuguese (Brazil)');
    expect(subtitleLanguageName('xyz'), 'XYZ');
  });

  group('the sheet', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<List<int>> service(Uri uri) async {
      asked.add(uri);
      final url = uri.toString();
      if (url.contains('cinemeta')) {
        return utf8.encode(jsonEncode({
          'metas': url.contains('/movie/')
              ? [
                  {'id': 'tt1375666', 'name': 'Inception', 'releaseInfo': '2010'},
                  {'id': 'tt6793710', 'name': 'The Crack: Inception', 'releaseInfo': '2019'},
                ]
              : const [],
        }));
      }
      if (url.contains('opensubtitles')) {
        return utf8.encode(jsonEncode({
          'subtitles': [
            {'url': 'https://s/1', 'lang': 'eng', 'subtitleFileName': 'Inception.CAM.srt', 'movieReleaseName': 'Inception.CAM'},
            {'url': 'https://s/2', 'lang': 'eng', 'subtitleFileName': 'Inception.BluRay.srt', 'movieReleaseName': 'Inception.BluRay'},
            {'url': 'https://s/3', 'lang': 'fre', 'subtitleFileName': 'Inception.fr.srt', 'movieReleaseName': 'Inception'},
          ],
        }));
      }
      return utf8.encode('subtitle text');
    }

    Future<String?> Function() openSheet(WidgetTester tester, String video) {
      String? result;
      tester.view.physicalSize = const Size(700, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return () async {
        await tester.pumpWidget(themedApp(Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<String>(
                  context: context,
                  builder: (_) => Dialog(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: OnlineSubtitlesSheet(video: video),
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        )));
        await tester.tap(find.text('Open'));
        await settle(tester);
        return result;
      };
    }

    testWidgets("searches for what the file's name says, opens a sure title, and returns what it saved", (tester) async {
      SubtitleSearch.fetchOverride = service;
      VideoPlayerSettings.instance.subtitleLanguage = null;
      final video = await tester.runAsync(() async {
        final file = File(p.join(root.path, 'Inception.2010.BluRay.mkv'));
        await file.writeAsString('x');
        return file.path;
      });
      await openSheet(tester, video!)();

      expect(find.text('Inception (2010)'), findsOneWidget, reason: 'its name is what was asked for');
      expect(find.text('English 2'), findsOneWidget);
      expect(find.text('French 1'), findsOneWidget);
      // The closest release first.
      final blu = tester.getTopLeft(find.text('Inception.BluRay.srt')).dy;
      final cam = tester.getTopLeft(find.text('Inception.CAM.srt')).dy;
      expect(blu, lessThan(cam));
      expect(find.text('Inception.fr.srt'), findsNothing, reason: 'another language');

      await tester.tap(find.text('French 1'));
      await settle(tester);
      expect(find.text('Inception.fr.srt'), findsOneWidget);

      await tester.tap(find.text('Inception.fr.srt'));
      // Real file writing, which takes longer with other tests running.
      for (var i = 0; i < 100 && find.byType(OnlineSubtitlesSheet).evaluate().isNotEmpty; i++) {
        await settle(tester);
      }
      expect(find.byType(OnlineSubtitlesSheet), findsNothing, reason: 'closes with the file');
      final saved = await tester.runAsync(() async => File(p.join(root.path, 'Inception.2010.BluRay.fre.srt')).readAsString());
      expect(saved, 'subtitle text');
      expect(VideoPlayerSettings.instance.subtitleLanguage, 'fre', reason: 'first next time');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a name that is no exact match asks which title', (tester) async {
      SubtitleSearch.fetchOverride = service;
      await openSheet(tester, p.join(root.path, 'Incept.mkv'))();
      expect(find.text('Inception (2010)'), findsOneWidget);
      expect(find.text('The Crack: Inception (2019)'), findsOneWidget);
      expect(asked.where((uri) => uri.toString().contains('opensubtitles')), isEmpty);

      await tester.tap(find.text('The Crack: Inception (2019)'));
      await settle(tester);
      expect(asked.where((uri) => uri.toString().contains('tt6793710')), hasLength(1));
      expect(find.text('Other titles'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no connection is said, and another search is allowed', (tester) async {
      SubtitleSearch.fetchOverride = (uri) async => throw const SocketException('down');
      await openSheet(tester, p.join(root.path, 'Inception.mkv'))();
      expect(find.textContaining("Couldn't reach"), findsOneWidget);
      SubtitleSearch.fetchOverride = service;
      await tester.tap(find.byTooltip('Search'));
      await settle(tester);
      expect(find.textContaining("Couldn't reach"), findsNothing);
      expect(find.text('Inception (2010)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nothing found says what to try', (tester) async {
      SubtitleSearch.fetchOverride = (uri) async => utf8.encode(jsonEncode({'metas': const <Object>[]}));
      await openSheet(tester, p.join(root.path, 'Holiday clip.mp4'))();
      expect(find.textContaining('No title found'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
