import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/toolbox/junk_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The junk cleaner's kinds, found in a made-up storage, home and app data.
void main() {
  late Directory root;
  final now = DateTime.now();

  String at(String path) => p.joinAll([root.path, ...path.split('/')]);

  File save(String path, [List<int> bytes = const [0x78], int? daysOld]) {
    final file = File(at(path))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
    if (daysOld != null) file.setLastModifiedSync(now.subtract(Duration(days: daysOld)));
    return file;
  }

  bool exists(String path) => FileSystemEntity.typeSync(at(path), followLinks: false) != FileSystemEntityType.notFound;

  const ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0];
  const dsStore = [0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31, 0, 0];
  const appleDouble = [0x00, 0x05, 0x16, 0x07, 0, 2];

  JunkGroup? found(List<JunkGroup> groups, JunkKind kind) => groups.where((g) => g.kind == kind).firstOrNull;
  List<String> names(List<JunkGroup> groups, JunkKind kind) =>
      [for (final item in found(groups, kind)?.items ?? const <JunkItem>[]) p.basename(item.path)]..sort();
  List<String> everything(List<JunkGroup> groups) => [
        for (final g in groups)
          for (final item in g.items) item.path,
      ];

  setUp(() => root = Directory.systemTemp.createTempSync('explorer_junk'));
  tearDown(() {
    JunkScanner.scanOverride = null;
    root.deleteSync(recursive: true);
  });

  group('what is ticked at first', () {
    test('only what is certainly safe', () {
      for (final kind in [JunkKind.temporary, JunkKind.thumbnails, JunkKind.appCache, JunkKind.shaderCaches, JunkKind.systemLeftovers]) {
        expect(kind.selectedAtFirst, isTrue, reason: kind.label);
      }
      for (final kind in [
        JunkKind.partialDownloads,
        JunkKind.crashDumps,
        JunkKind.logs,
        JunkKind.caches,
        JunkKind.browserCaches,
        JunkKind.devCaches,
        JunkKind.statuses,
        JunkKind.trash,
        JunkKind.emptyFolders,
        JunkKind.emptyFiles,
        JunkKind.backups,
        JunkKind.installers,
      ]) {
        expect(kind.selectedAtFirst, isFalse, reason: kind.label);
      }
    });

    test('big and old files are for review, never ticked, and come last', () {
      final review = [for (final kind in JunkKind.values) if (kind.review) kind];
      expect(review, [JunkKind.oldDownloads, JunkKind.largeFiles]);
      expect(review.any((kind) => kind.selectedAtFirst), isFalse);
      expect(JunkKind.values.skip(JunkKind.values.length - 2), review);
      expect(JunkKind.largeFiles.description, contains('MB or more'));
      expect(JunkKind.browserCaches.description, contains('Close your browsers first'));
    });
  });

  group('on a phone', () {
    test('unfinished downloads only once they have stopped for a day', () {
      save('Download/movie.mp4.part', [1, 2, 3], 3);
      save('Download/setup.crdownload', [1], 2);
      save('Download/song.!ut', [1], 2);
      save('Download/running.crdownload', [1]);
      final groups = JunkScanner.scanStorage(root.path, now: now);
      expect(names(groups, JunkKind.partialDownloads), ['movie.mp4.part', 'setup.crdownload', 'song.!ut']);
      expect(found(groups, JunkKind.partialDownloads)!.size, 5);
    });

    test("system leftovers by name, but only if they're really those files", () {
      save('Pictures/Thumbs.db', ole);
      save('Pictures/Holiday/.DS_Store', dsStore);
      save('Music/._song.mp3', appleDouble);
      save('Docs/thumbs.db', [1, 2, 3]);
      save('Docs/._notes', [0x68, 0x69]);
      save('Docs/desktop.ini', [0x5B]);
      final groups = JunkScanner.scanStorage(root.path, now: now);
      expect(names(groups, JunkKind.systemLeftovers), ['.DS_Store', '._song.mp3', 'Thumbs.db']);
      expect(everything(groups).where((path) => path.contains('Docs')), isEmpty);
    });

    test("an archive's __MACOSX folder, if all it holds is Finder's", () {
      save('Download/photos/__MACOSX/._a.jpg', appleDouble);
      save('Download/photos/__MACOSX/sub/._b.jpg', appleDouble);
      save('Download/other/__MACOSX/real.txt', [1]);
      save('Download/other/__MACOSX/old.log');
      final groups = JunkScanner.scanStorage(root.path, now: now);
      final leftovers = found(groups, JunkKind.systemLeftovers)!;
      expect([for (final item in leftovers.items) item.path], [at('Download/photos/__MACOSX')]);
      expect(leftovers.items.single.isFolder, isTrue);
      expect(leftovers.size, appleDouble.length * 2);
      expect(found(groups, JunkKind.logs), isNull, reason: 'a __MACOSX with more in it is left alone');
    });

    test('empty files a day old, but not markers or hidden files', () {
      save('Docs/empty.txt', [], 2);
      save('Docs/just made.txt', []);
      save('Docs/code/__init__.py', [], 2);
      save('Docs/.nomedia', [], 2);
      save('Docs/.keep', [], 2);
      save('Docs/app.lock', [], 2);
      final groups = JunkScanner.scanStorage(root.path, now: now);
      expect(names(groups, JunkKind.emptyFiles), ['empty.txt']);
    });

    test('backup copies', () {
      save('Docs/report.docx.bak');
      save('Docs/notes.txt~');
      save('Docs/config.old');
      save('Docs/old.txt');
      expect(names(JunkScanner.scanStorage(root.path, now: now), JunkKind.backups), ['config.old', 'notes.txt~', 'report.docx.bak']);
    });

    test('crash dumps, and the existing kinds still', () {
      save('Download/crash.dmp');
      save('Download/session.tmp');
      save('Docs/app.log');
      save('Download/app.apk');
      final groups = JunkScanner.scanStorage(root.path, now: now);
      expect(names(groups, JunkKind.crashDumps), ['crash.dmp']);
      expect(names(groups, JunkKind.temporary), ['session.tmp']);
      expect(names(groups, JunkKind.logs), ['app.log']);
      expect(names(groups, JunkKind.installers), ['app.apk']);
    });

    test("WhatsApp's viewed statuses, old place and new, leaving its .nomedia", () {
      save('Android/media/com.whatsapp/WhatsApp/Media/.Statuses/a.jpg', [1, 2]);
      save('Android/media/com.whatsapp/WhatsApp/Media/.Statuses/.nomedia', []);
      save('WhatsApp/Media/.Statuses/b.mp4', [1, 2, 3]);
      save('Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/photo.jpg');
      final groups = JunkScanner.scanStorage(root.path, now: now);
      expect(names(groups, JunkKind.statuses), ['a.jpg', 'b.mp4']);
      expect(found(groups, JunkKind.statuses)!.size, 5);
      expect(everything(groups).where((path) => path.contains('WhatsApp Images')), isEmpty);
    });

    test('old downloads and large files are listed for review, each once', () {
      save('Download/manual.pdf', [1], 100);
      save('Download/recent.pdf', [1], 10);
      save('Docs/ancient.pdf', [1], 400);
      save('DCIM/long.mp4', List.filled(64, 1));
      save('Download/old.apk', [1], 100);
      save('Download/huge.part', List.filled(64, 1), 100);
      save('Download/big and old.mkv', List.filled(64, 1), 100);
      final groups = JunkScanner.scanStorage(root.path, now: now, largeAt: 64);
      expect(names(groups, JunkKind.oldDownloads), ['big and old.mkv', 'manual.pdf']);
      expect(names(groups, JunkKind.largeFiles), ['long.mp4']);
      expect(names(groups, JunkKind.installers), ['old.apk'], reason: 'junk before review');
      expect(names(groups, JunkKind.partialDownloads), ['huge.part']);
      final paths = everything(groups);
      expect(paths.toSet().length, paths.length, reason: 'nothing twice');
    });

    test('code projects, hidden folders and macOS packages are left alone', () {
      save('Projects/app/.git/HEAD');
      save('Projects/app/build.log');
      save('Projects/app/src/empty.txt', [], 5);
      save('.hidden/a.tmp');
      save('Docs/Book.pages/empty', [], 5);
      save('Docs/node_modules/x/readme.bak');
      expect(JunkScanner.scanStorage(root.path, now: now), isEmpty);
    });
  });

  group('on a computer', () {
    String home() => at('home');
    String local() => at('home/AppData/Local');

    test("Windows: shader caches, crash reports, browsers' and developers' caches, each in its place", () {
      save('home/AppData/Local/D3DSCache/abc/data', [1, 2]);
      save('home/AppData/Local/NVIDIA/DXCache/x.bin');
      save('home/AppData/LocalLow/NVIDIA/PerDriverVersion/DXCache/y.bin');
      save('home/AppData/Local/CrashDumps/app.exe.123.dmp');
      save('home/AppData/Local/Microsoft/Windows/WER/ReportArchive/AppCrash_app/Report.wer');
      final chrome = 'home/AppData/Local/Google/Chrome/User Data';
      save('$chrome/Default/Preferences');
      save('$chrome/Default/Cache/Cache_Data/f_000001', [1, 2, 3, 4]);
      save('$chrome/Default/Code Cache/js/index');
      save('$chrome/Default/History', [1]);
      save('$chrome/Profile 1/Preferences');
      save('$chrome/Profile 1/GPUCache/data_0');
      save('$chrome/Crashpad/Cache/not a profile');
      save('$chrome/ShaderCache/data_1');
      save('home/AppData/Local/Mozilla/Firefox/Profiles/abc.default/cache2/entries/E1');
      save('home/AppData/Local/npm-cache/_cacache/index-v5/aa');
      save('home/.gradle/caches/modules-2/jar');
      final folders = JunkScanner.computerFolders(system: 'windows', home: home(), local: local());
      final groups = JunkScanner.scanComputer(at('temp'), folders: folders, now: now);
      expect(names(groups, JunkKind.shaderCaches), ['abc', 'x.bin', 'y.bin']);
      expect(names(groups, JunkKind.crashDumps), ['AppCrash_app', 'app.exe.123.dmp']);
      expect(names(groups, JunkKind.browserCaches), ['Cache_Data', 'data_0', 'data_1', 'entries', 'js']);
      final cacheData = found(groups, JunkKind.browserCaches)!.items.firstWhere((item) => p.basename(item.path) == 'Cache_Data');
      expect(cacheData.isFolder, isTrue);
      expect(cacheData.size, 4, reason: "a folder's size is all that's in it");
      expect(names(groups, JunkKind.devCaches), ['index-v5', 'modules-2']);
      expect(everything(groups).where((path) => path.contains('History') || path.contains('Crashpad')), isEmpty);
      expect(found(groups, JunkKind.caches), isNull, reason: 'nothing else in AppData is touched');
    });

    test("Linux: the cache folder's known parts under their kinds, the rest as App caches", () {
      save('home/.cache/thumbnails/normal/a.png');
      save('home/.cache/google-chrome/Default/Cache/x');
      save('home/.cache/mozilla/firefox/p/cache2/y');
      save('home/.cache/mesa_shader_cache/ab/cd');
      save('home/.cache/pip/http/z');
      save('home/.cache/someapp/blob');
      save('home/.var/app/org.mozilla.firefox/cache/fontconfig/f');
      save('home/.local/share/Trash/files/gone.txt');
      final folders = JunkScanner.computerFolders(system: 'linux', home: home(), cache: at('home/.cache'), uid: 1000);
      final groups = JunkScanner.scanComputer(at('temp'), folders: folders, now: now);
      expect(names(groups, JunkKind.thumbnails), ['normal']);
      expect(names(groups, JunkKind.browserCaches), ['Default', 'firefox', 'fontconfig']);
      expect(names(groups, JunkKind.shaderCaches), ['ab']);
      expect(names(groups, JunkKind.devCaches), ['http']);
      expect(names(groups, JunkKind.caches), ['someapp']);
      expect(names(groups, JunkKind.trash), ['gone.txt']);

      final crashes = folders.singleWhere((folder) => folder.kind == JunkKind.crashDumps);
      expect(crashes.path, '/var/crash');
      expect(crashes.match!('_usr_bin_gedit.1000.crash'), isTrue);
      expect(crashes.match!('_usr_bin_gedit.0.crash'), isFalse, reason: "another user's, which can't be deleted");
      expect(crashes.match!('_usr_bin_gedit.1000.upload'), isFalse);
    });

    test('macOS: crash reports apart from the other logs', () {
      save('home/Library/Logs/DiagnosticReports/App-2026.ips');
      save('home/Library/Logs/App/app.log');
      save('home/Library/Caches/com.app/data');
      final folders = JunkScanner.computerFolders(system: 'macos', home: home());
      final groups = JunkScanner.scanComputer(at('temp'), folders: folders, now: now);
      expect(names(groups, JunkKind.crashDumps), ['App-2026.ips']);
      expect(names(groups, JunkKind.logs), ['App']);
      expect(names(groups, JunkKind.caches), ['com.app']);
    });

    test("the user's folders: junk by name only, old downloads only from Downloads", () {
      save('home/Downloads/setup.exe.crdownload', [1], 2);
      save('home/Downloads/manual.pdf', [1], 120);
      save('home/Downloads/Thumbs.db', ole);
      save('home/Downloads/photos/__MACOSX/._a.jpg', appleDouble);
      save('home/Documents/report.log', [1], 30);
      save('home/Documents/notes.tmp', [1], 30);
      save('home/Documents/thesis.pdf', [1], 400);
      save('home/Documents/thesis.docx.bak', [1], 30);
      save('home/Documents/blank.txt', [], 30);
      save('home/Desktop/video.mkv', List.filled(32, 1));
      Directory(at('home/Documents/Empty/Inside')).createSync(recursive: true);
      final groups = JunkScanner.scanComputer(
        at('temp'),
        userFolders: [at('home/Downloads'), at('home/Desktop'), at('home/Documents')],
        downloads: [at('home/Downloads')],
        largeAt: 32,
        now: now,
        macOS: false,
      );
      expect(names(groups, JunkKind.partialDownloads), ['setup.exe.crdownload']);
      expect(names(groups, JunkKind.systemLeftovers), ['Thumbs.db', '__MACOSX']);
      expect(names(groups, JunkKind.backups), ['thesis.docx.bak']);
      expect(names(groups, JunkKind.emptyFiles), ['blank.txt']);
      expect(names(groups, JunkKind.oldDownloads), ['manual.pdf']);
      expect(names(groups, JunkKind.largeFiles), ['video.mkv']);
      for (final kind in [JunkKind.logs, JunkKind.temporary, JunkKind.emptyFolders]) {
        expect(found(groups, kind), isNull, reason: 'on a computer an odd ${kind.label} may matter');
      }
    });

    test("on a Mac, Finder's own files stay, and an unfinished Safari download goes", () {
      save('home/Downloads/.DS_Store', dsStore);
      save('home/Downloads/._a.jpg', appleDouble);
      save('home/Downloads/Thumbs.db', ole);
      save('home/Downloads/movie.mp4.download/Info.plist', [1]);
      save('home/Downloads/movie.mp4.download/movie.mp4', [1, 2, 3]);
      save('home/Documents/Library.photoslibrary/database/empty', []);
      final groups = JunkScanner.scanComputer(
        at('temp'),
        userFolders: [at('home/Downloads'), at('home/Documents')],
        downloads: [at('home/Downloads')],
        // Three days on, as Dart can't date a folder back.
        now: now.add(const Duration(days: 3)),
        macOS: true,
      );
      expect(names(groups, JunkKind.systemLeftovers), ['Thumbs.db']);
      expect(names(groups, JunkKind.partialDownloads), ['movie.mp4.download']);
      expect(found(groups, JunkKind.partialDownloads)!.size, 4);
      expect(found(groups, JunkKind.emptyFiles), isNull, reason: 'a package is a file to the user');
    });
  });

  group('each thing once, and nothing past a link', () {
    test('the first kind to find something keeps it; what a listed folder holds goes with it', () {
      save('a/b/c.log', [1, 2, 3]);
      save('a/d.txt', [1]);
      final groups = JunkScanner.scanComputer(
        at('temp'),
        folders: [
          JunkFolder(JunkKind.logs, at('a/b')),
          JunkFolder(JunkKind.caches, at('a')),
          JunkFolder(JunkKind.trash, at('a')),
        ],
        now: now,
      );
      expect(found(groups, JunkKind.logs), isNull, reason: 'c.log is inside b, which App caches lists');
      expect(names(groups, JunkKind.caches), ['b', 'd.txt']);
      expect(found(groups, JunkKind.caches)!.size, 4);
      expect(found(groups, JunkKind.trash), isNull);
    });

    test('links and junctions are neither listed, nor followed, nor deleted through', () async {
      save('outside/keep.txt', List.filled(100, 1), 400);
      save('cache/real/data', [1, 2]);
      save('home/Downloads/inside.txt', [1], 200);
      final made = <String>[];
      for (final (name, folder) in [('link', 'cache/real'), ('downloads link', 'home/Downloads')]) {
        try {
          Link(at('$folder/$name')).createSync(at('outside'));
          made.add('$folder/$name');
        } on FileSystemException {
          // No right to make links here.
        }
      }
      if (Platform.isWindows) {
        final junction = at('cache/real/junction');
        if (Process.runSync('cmd', ['/c', 'mklink', '/J', junction, at('outside')]).exitCode == 0) made.add('cache/real/junction');
      }
      if (made.isEmpty) {
        markTestSkipped("can't make links here");
        return;
      }
      final groups = JunkScanner.scanComputer(
        at('temp'),
        folders: [JunkFolder(JunkKind.caches, at('cache'))],
        userFolders: [at('home/Downloads')],
        downloads: [at('home/Downloads')],
        largeAt: 50,
        now: now,
      );
      expect(found(groups, JunkKind.caches)!.size, 2, reason: "what's past a link isn't counted");
      expect(names(groups, JunkKind.oldDownloads), ['inside.txt']);
      expect(everything(groups).where((path) => path.contains('outside') || path.contains('link')), isEmpty);

      final result = await JunkScanner.clean(found(groups, JunkKind.caches)!.items);
      expect(result.removed, 1);
      expect(exists('cache/real'), isFalse);
      expect(exists('outside/keep.txt'), isTrue, reason: 'deleting a folder never goes through a link in it');
    });
  });

  group('how far it has come, and stopping', () {
    void junk() {
      save('temp/old.tmp', [1, 2, 3], 3);
      save('temp/new.tmp', [1]);
      save('cache/app/data', [1, 2, 3, 4, 5]);
      save('home/Downloads/movie.part', [1, 2], 3);
      save('home/Downloads/keep.txt', [1]);
    }

    List<JunkGroup> scan({JunkReport? onProgress}) => _scanOf(root.path, now)(onProgress ?? (_) {});

    test('a scan tells where it is looking, and at the end all it found', () {
      junk();
      final told = <JunkScanProgress>[];
      final groups = scan(onProgress: told.add);
      expect(told, isNotEmpty);
      expect(told.first.place, at('temp'));
      expect(told.first.kind, JunkKind.temporary);
      final items = groups.fold(0, (sum, group) => sum + group.items.length);
      final bytes = groups.fold(0, (sum, group) => sum + group.size);
      expect(items, 3, reason: 'the old temporary file, the cache and the unfinished download');
      expect(told.last.items, items);
      expect(told.last.bytes, bytes);
      expect(everything(groups), everything(scan()), reason: 'telling changes nothing it finds');
    });

    test('in the background it finds the same, telling as it goes', () async {
      junk();
      JunkScanner.scanOverride = _scanOf(root.path, now);
      final told = <JunkScanProgress>[];
      final groups = await JunkScan(onProgress: told.add).start();
      expect(everything(groups!), everything(scan()));
      expect(told, isNotEmpty);
    });

    test('Stop stops it at once, and it gives nothing', () async {
      JunkScanner.scanOverride = _slowScan(at('somewhere'));
      final told = Completer<JunkScanProgress>();
      final scan = JunkScan(onProgress: (progress) {
        if (!told.isCompleted) told.complete(progress);
      });
      final result = scan.start();
      expect((await told.future.timeout(const Duration(seconds: 20))).kind, JunkKind.browserCaches);
      final clock = Stopwatch()..start();
      scan.stop();
      expect(await result, isNull);
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a scan that fails says so', () async {
      JunkScanner.scanOverride = _failingScan();
      await expectLater(JunkScan().start(), throwsStateError);
    });

    test('cleaning tells how far it has come, and lists what it could not delete', () async {
      save('a.tmp', [1, 2, 3]);
      save('folder/b.tmp', [1, 2, 3, 4]);
      final told = <JunkCleanProgress>[];
      final result = await JunkScanner.clean(
        [
          JunkItem(at('a.tmp'), 3),
          JunkItem(at('gone.tmp'), 9),
          JunkItem(at('folder'), 4, isFolder: true),
        ],
        onProgress: told.add,
      );
      expect(result.freed, 7);
      expect(result.removed, 2);
      expect(result.failed, 1);
      expect([for (final item in result.notDeleted) p.basename(item.path)], ['gone.tmp']);
      expect(told, isNotEmpty);
      expect(told.first.total, 3);
      expect(exists('a.tmp'), isFalse);
      expect(exists('folder'), isFalse);
    });
  });
}

// Scans in an isolate of their own: made here, they hold only what they're given.

/// A temporary folder, a cache and Downloads in [root].
List<JunkGroup> Function(JunkReport report) _scanOf(String root, DateTime now) => (report) {
      final downloads = p.join(root, 'home', 'Downloads');
      return JunkScanner.scanComputer(
        p.join(root, 'temp'),
        folders: [JunkFolder(JunkKind.caches, p.join(root, 'cache'))],
        userFolders: [downloads],
        downloads: [downloads],
        now: now,
        onProgress: report,
      );
    };

List<JunkGroup> Function(JunkReport report) _slowScan(String place) => (report) {
      report(JunkScanProgress(place: place, kind: JunkKind.browserCaches, items: 1, bytes: 1));
      for (var i = 0; i < 400; i++) {
        sleep(const Duration(milliseconds: 50));
      }
      return const [];
    };

List<JunkGroup> Function(JunkReport report) _failingScan() => (_) => throw const FileSystemException('No');
