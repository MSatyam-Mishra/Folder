import 'dart:io';

import 'package:explorer/core/services/toolbox/duplicate_finder.dart';
import 'package:explorer/core/services/toolbox/junk_scanner.dart';
import 'package:explorer/core/services/toolbox/ram_cleaner.dart';
import 'package:explorer/features/toolbox/duplicate_finder_screen.dart';
import 'package:explorer/features/toolbox/memory_cleaner_screen.dart';
import 'package:explorer/features/toolbox/toolbox_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The sidebar's Toolbox.
void main() {
  late Directory root;

  Future<File> save(String path, [String text = 'x']) async {
    final file = File(p.joinAll([root.path, ...path.split('/')]));
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  bool exists(String path) =>
      FileSystemEntity.typeSync(p.joinAll([root.path, ...path.split('/')])) != FileSystemEntityType.notFound;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_toolbox');
  });

  tearDown(() async {
    JunkScanner.scanOverride = null;
    await root.delete(recursive: true);
  });

  group('memory figures', () {
    test("this computer's real figures", () async {
      final stats = await RamCleaner.read();
      expect(stats, isNotNull);
      expect(stats!.total, greaterThan(1024 * 1024 * 1024));
      expect(stats.available, inInclusiveRange(1, stats.total));
    }, skip: Platform.isAndroid);

    test('from Linux', () {
      final stats = RamCleaner.parseMeminfo('MemTotal:       16000000 kB\nMemFree:  1000 kB\nMemAvailable:    4000000 kB\n')!;
      expect(stats.total, 16000000 * 1024);
      expect(stats.available, 4000000 * 1024);
      expect(stats.usedFraction, closeTo(0.75, 0.001));
    });

    test('from a Mac', () {
      const text = 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\n'
          'Pages free:                               100.\n'
          'Pages active:                            5000.\n'
          'Pages inactive:                           200.\n'
          'Pages speculative:                         50.\n';
      expect(RamCleaner.parseVmStat(text, 1000000000)!.available, 350 * 16384);
    });
  });

  group('memory cleaner', () {
    JunkGroup? group(List<JunkGroup> groups, JunkKind kind) => groups.where((g) => g.kind == kind).firstOrNull;
    Iterable<String> names(JunkGroup? g) => [for (final item in g?.items ?? const <JunkItem>[]) p.basename(item.path)];

    test('on a phone it finds junk by kind and leaves real files alone', () async {
      await save('DCIM/photo.jpg');
      await save('Download/app.apk', 'installer');
      await save('Download/session.tmp', 'tmp');
      await save('Documents/report.log', 'log');
      await save('DCIM/.thumbnails/1.jpg', 'thumb');
      await save('Android/media/app/cache.tmp');
      await save('.hidden/secret.tmp');
      await Directory(p.join(root.path, 'Music')).create();
      await Directory(p.join(root.path, 'Old', 'Nothing')).create(recursive: true);

      final groups = JunkScanner.scanStorage(root.path);
      expect(names(group(groups, JunkKind.temporary)), ['session.tmp']);
      expect(names(group(groups, JunkKind.logs)), ['report.log']);
      expect(names(group(groups, JunkKind.installers)), ['app.apk']);
      expect(names(group(groups, JunkKind.thumbnails)), ['.thumbnails']);
      expect(group(groups, JunkKind.thumbnails)!.size, 5, reason: "the folder's contents count");
      expect(names(group(groups, JunkKind.emptyFolders)), ['Nothing'], reason: "the system's own folders stay");
    });

    test("only what's certainly safe is ticked at first", () {
      expect(JunkKind.temporary.selectedAtFirst, isTrue);
      expect(JunkKind.thumbnails.selectedAtFirst, isTrue);
      expect(JunkKind.installers.selectedAtFirst, isFalse);
      expect(JunkKind.logs.selectedAtFirst, isFalse);
      expect(JunkKind.emptyFolders.selectedAtFirst, isFalse);
    });

    test("on a computer only what's stayed in the temporary folder over a day", () async {
      final old = await save('temp/old.dat', 'old');
      await old.setLastModified(DateTime.now().subtract(const Duration(days: 3)));
      await save('temp/new.dat', 'new');
      await save('Documents/report.log', 'log');
      final groups = JunkScanner.scanComputer(p.join(root.path, 'temp'));
      expect(names(group(groups, JunkKind.temporary)), ['old.dat']);
      expect(group(groups, JunkKind.logs), isNull);
    });

    test('each computer place goes under its kind; trash and caches stay unticked', () async {
      await save('logs/crash.dmp', 'dump');
      await save('caches/app/data', 'cache');
      await save('trash/deleted.txt', 'gone');
      await Directory(p.join(root.path, 'temp')).create();
      final groups = JunkScanner.scanComputer(
        p.join(root.path, 'temp'),
        logs: [p.join(root.path, 'logs')],
        caches: [p.join(root.path, 'caches')],
        trash: [p.join(root.path, 'trash'), p.join(root.path, 'not there')],
      );
      expect(names(group(groups, JunkKind.logs)), ['crash.dmp']);
      expect(names(group(groups, JunkKind.caches)), ['app']);
      expect(names(group(groups, JunkKind.trash)), ['deleted.txt']);
      expect(JunkKind.trash.selectedAtFirst, isFalse);
      expect(JunkKind.caches.selectedAtFirst, isFalse);
    });

    test('cleaning deletes exactly what it was given, and counts what it could not', () async {
      await save('a/one.tmp', '123');
      await save('b/two.tmp', '12345');
      await save('b/keep.txt');
      final result = await JunkScanner.clean([
        JunkItem(p.join(root.path, 'a', 'one.tmp'), 3),
        JunkItem(p.join(root.path, 'b', 'two.tmp'), 5),
        JunkItem(p.join(root.path, 'gone.tmp'), 9),
      ]);
      expect(result.freed, 8);
      expect(result.removed, 2);
      expect(result.failed, 1);
      expect(exists('a/one.tmp'), isFalse);
      expect(exists('b/keep.txt'), isTrue);
    });
  });

  group('duplicate finder', () {
    test('finds same contents under any name, in any folder, oldest first', () async {
      final oldest = await save('a/song.mp3', 'same contents');
      await oldest.setLastModified(DateTime(2020));
      await save('b/copy of song.mp3', 'same contents');
      await save('c/different.mp3', 'more contents');
      await save('c/other.txt', 'unique');
      final groups = await DuplicateFinder.find(root.path);
      expect(groups, hasLength(1));
      expect(groups.single.files.first.path, oldest.path);
      expect([for (final f in groups.single.files) p.basename(f.path)], ['song.mp3', 'copy of song.mp3']);
      expect(groups.single.wasted, 'same contents'.length);
    });

    test('big files that differ only after their start are not duplicates', () async {
      final start = 'x' * (70 * 1024);
      await save('one.bin', '${start}A');
      await save('two.bin', '${start}B');
      await save('three.bin', '${start}A');
      final groups = await DuplicateFinder.find(root.path);
      expect(groups, hasLength(1));
      expect([for (final f in groups.single.files) p.basename(f.path)]..sort(), ['one.bin', 'three.bin']);
    });

    test('hidden files, app folders and empty files are left out', () async {
      await save('.hidden/a.txt', 'same');
      await save('.b.txt', 'same');
      await save('Android/data/c.txt', 'same');
      await save('one.txt', '');
      await save('two.txt', '');
      expect(await DuplicateFinder.find(root.path), isEmpty);
    });

    test('runs in the background and reports the same', () async {
      await save('one.txt', 'same');
      await save('two.txt', 'same');
      final groups = await DuplicateSearch(root.path, onProgress: (_) {}).start();
      expect(groups, hasLength(1));
    });
  });

  group('screens', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> until(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
        await settle(tester);
      }
      await settle(tester);
    }

    testWidgets('the toolbox lists the five tools', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(ToolboxScreen(showFolder: (_) {})));
      await settle(tester);
      for (final tool in ['RAM cleaner', 'Memory cleaner', 'Duplicate finder', 'Video player', 'Music player']) {
        expect(find.text(tool), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('memory cleaner: safe kinds ticked, asks, deletes those only', (tester) async {
      final temp = await tester.runAsync(() => save('Download/x.tmp', '12345'));
      final apk = await tester.runAsync(() => save('Download/x.apk', '1234567'));
      JunkScanner.scanOverride = () async => [
            JunkGroup(JunkKind.temporary, [JunkItem(temp!.path, 5)]),
            JunkGroup(JunkKind.installers, [JunkItem(apk!.path, 7)]),
          ];
      await tester.pumpWidget(themedApp(const MemoryCleanerScreen()));
      await until(tester, find.text('Temporary files'));
      expect(find.textContaining('Clean 5'), findsOneWidget, reason: 'installers are not ticked');

      await tester.tap(find.textContaining('Clean 5'));
      await settle(tester);
      expect(find.text('Delete 1 item?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      JunkScanner.scanOverride = () async => [];
      for (var i = 0; i < 40 && temp!.existsSync(); i++) {
        await settle(tester);
      }
      expect(temp!.existsSync(), isFalse);
      expect(apk!.existsSync(), isTrue);
      await until(tester, find.text('All clean'));
      expect(find.textContaining('Freed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('duplicate finder: every copy but the oldest ticked; deleting leaves one', (tester) async {
      final oldest = (await tester.runAsync(() => save('a/photo.jpg', 'same contents')))!;
      await tester.runAsync(() => oldest.setLastModified(DateTime(2020)));
      final copy = (await tester.runAsync(() => save('b/photo (1).jpg', 'same contents')))!;
      tester.view.physicalSize = const Size(900, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(DuplicateFinderScreen(folder: root.path)));
      await settle(tester);
      await tester.tap(find.text('Find duplicates'));
      await until(tester, find.textContaining('Delete 1'));
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('photo (1).jpg'), findsOneWidget);

      await tester.tap(find.textContaining('Delete 1'));
      await settle(tester);
      expect(find.text('Delete 1 file?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      for (var i = 0; i < 40 && copy.existsSync(); i++) {
        await settle(tester);
      }
      expect(copy.existsSync(), isFalse);
      expect(oldest.existsSync(), isTrue, reason: 'the oldest stays');
      await until(tester, find.text('No duplicates'));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
