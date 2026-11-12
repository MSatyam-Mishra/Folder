import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/incoming_files.dart';
import 'package:folders/core/services/toolbox/duplicate_finder.dart';
import 'package:folders/core/services/toolbox/junk_scanner.dart';
import 'package:folders/core/services/toolbox/ram_cleaner.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/localsend/screens/localsend_screen.dart';
import 'package:folders/features/network/screens/file_server_screen.dart';
import 'package:folders/features/toolbox/duplicate_finder_screen.dart';
import 'package:folders/features/toolbox/junk_cleaner_screen.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:folders/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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

  group('junk cleaner', () {
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
        folders: [
          JunkFolder(JunkKind.logs, p.join(root.path, 'logs')),
          JunkFolder(JunkKind.caches, p.join(root.path, 'caches')),
          JunkFolder(JunkKind.trash, p.join(root.path, 'trash')),
          JunkFolder(JunkKind.trash, p.join(root.path, 'not there')),
        ],
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

    testWidgets('the toolbox lists every tool', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(Scaffold(body: ToolboxMenu(onOpen: (_) {}))));
      await settle(tester);
      for (final tool in [
        'RAM cleaner',
        'Junk cleaner',
        'Duplicate finder',
        'Video player',
        'Music player',
        'Video downloader',
        'Wi-Fi sharing',
        'Nearby share',
      ]) {
        expect(find.text(tool), findsOneWidget, reason: tool);
      }
      expect(find.text('Memory cleaner'), findsNothing, reason: 'it is the Junk cleaner now');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a build without the video downloader has no such tool', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(Scaffold(
        body: ToolboxMenu(onOpen: (_) {}, tools: Tool.availableIn(videoDownloader: false)),
      )));
      await settle(tester);
      expect(find.text('Video downloader'), findsNothing);
      expect(find.text('Wi-Fi sharing'), findsOneWidget);
      expect(find.text('Nearby share'), findsOneWidget);
      expect(Tool.fromRoute('tool/video_downloader', videoDownloader: false), isNull);
      expect(Tool.fromRoute('tool/video_downloader'), Tool.videoDownloader);
      await tester.pumpWidget(const SizedBox());
    });

    test("the new tools' routes and screens; the Junk cleaner keeps the Memory cleaner's", () {
      expect(Tool.fromRoute('tool/memory_cleaner'), Tool.junkCleaner);
      expect(Tool.junkCleaner.shortcut.id, 'tool_memory_cleaner', reason: 'pinned shortcuts and drawer entries stay');
      expect(Tool.fromRoute('tool/wifi_sharing'), Tool.wifiSharing);
      expect(Tool.fromRoute('tool/nearby_share'), Tool.nearbyShare);
      expect(Tool.isRoute('tool/anything'), isTrue);
      expect(Tool.isRoute(IncomingRoute.fileServer), isFalse);
      expect(Tool.nearbyShare.screen, isA<LocalSendScreen>());
      expect(Tool.videoDownloader.screen, isA<VideoDownloaderScreen>());
      final sharing = Tool.wifiSharing.screen as FileServerScreen;
      expect(sharing.initialFolder, ExplorerPaths.userFolder, reason: 'a real folder, never This PC');
    });

    Future<void> openMenu(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showToolboxMenu(context),
            child: const Text('Toolbox'),
          ),
        ),
      )));
      await tester.tap(find.text('Toolbox'));
      await settle(tester);
    }

    testWidgets('the menu shows the tools in a grid, over the page, and a tap outside closes it', (tester) async {
      await openMenu(tester);
      final first = tester.getTopLeft(find.text('RAM cleaner'));
      final second = tester.getTopLeft(find.text('Junk cleaner'));
      final fourth = tester.getTopLeft(find.text('Video player'));
      expect(first.dy, second.dy, reason: 'side by side');
      expect(fourth.dy, greaterThan(first.dy), reason: 'then the next row');
      expect(find.text('Toolbox'), findsNWidgets(2), reason: 'the page stays behind it');

      await tester.tapAt(const Offset(10, 790));
      await settle(tester);
      expect(find.byType(ToolboxMenu), findsNothing);
      expect(find.text('Toolbox'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tool opens as its own screen, from where the menu was asked for', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Junk cleaner'));
      await settle(tester);
      expect(find.byType(ToolboxMenu), findsNothing);
      expect(find.byType(JunkCleanerScreen), findsOneWidget);
      expect(find.text('Junk cleaner'), findsOneWidget, reason: "the screen's title");
      expect(find.text('Scan'), findsOneWidget, reason: 'it waits to be asked');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Wi-Fi sharing opens at the folder showing, as from the drawer', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final explorer = FileExplorerBloc(watchFolders: false)..add(LoadDirectory(root.path));
      addTearDown(explorer.close);
      for (var i = 0; i < 40 && explorer.state is! FileExplorerLoaded; i++) {
        await settle(tester);
      }
      await tester.pumpWidget(themedApp(BlocProvider.value(
        value: explorer,
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(onPressed: () => showToolboxMenu(context), child: const Text('Toolbox')),
          ),
        ),
      )));
      await tester.tap(find.text('Toolbox'));
      await settle(tester);
      await tester.tap(find.text('Wi-Fi sharing'));
      await settle(tester);
      expect(find.byType(ToolboxMenu), findsNothing);
      expect(tester.widget<FileServerScreen>(find.byType(FileServerScreen)).initialFolder, root.path);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("Wi-Fi sharing with no folder showing starts at the user's own", (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Wi-Fi sharing'));
      await settle(tester);
      expect(tester.widget<FileServerScreen>(find.byType(FileServerScreen)).initialFolder, ExplorerPaths.userFolder);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the pin and a right-click offer the places this system has, and the menu stays', (tester) async {
      await openMenu(tester);
      await tester.tap(find.byTooltip('Add shortcut').first);
      await settle(tester);
      expect(find.text('Add to desktop'), findsOneWidget);
      if (Platform.isWindows) expect(find.text('Add to Start menu'), findsOneWidget);

      await tester.tapAt(const Offset(10, 790));
      await settle(tester);
      expect(find.text('Add to desktop'), findsNothing);
      expect(find.byType(ToolboxMenu), findsOneWidget, reason: 'only the shortcut menu closed');

      await tester.tap(find.text('Music player'), buttons: kSecondaryButton);
      await settle(tester);
      expect(find.text('Add to desktop'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('junk cleaner: safe kinds ticked, asks, deletes those only', (tester) async {
      final temp = await tester.runAsync(() => save('Download/x.tmp', '12345'));
      final apk = await tester.runAsync(() => save('Download/x.apk', '1234567'));
      JunkScanner.scanOverride = _finds([
        JunkGroup(JunkKind.temporary, [JunkItem(temp!.path, 5)]),
        JunkGroup(JunkKind.installers, [JunkItem(apk!.path, 7)]),
      ]);
      await tester.pumpWidget(themedApp(const JunkCleanerScreen()));
      await settle(tester);
      await tester.tap(find.text('Scan'));
      await until(tester, find.text('Temporary files'));
      expect(find.textContaining('Clean 5'), findsOneWidget, reason: 'installers are not ticked');

      await tester.tap(find.textContaining('Clean 5'));
      await settle(tester);
      expect(find.text('Delete 1 item?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      for (var i = 0; i < 40 && temp.existsSync(); i++) {
        await settle(tester);
      }
      expect(temp.existsSync(), isFalse);
      expect(apk.existsSync(), isTrue);
      await until(tester, find.text('5 B freed'));
      expect(find.text('1 item deleted'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('junk cleaner: files tick one by one, and big files wait unticked under Review', (tester) async {
      final a = (await tester.runAsync(() => save('Download/a.tmp', '123')))!;
      final b = (await tester.runAsync(() => save('Download/b.tmp', '12345')))!;
      final big = (await tester.runAsync(() => save('Movies/big.mkv', '1234567')))!;
      JunkScanner.scanOverride = _finds([
        JunkGroup(JunkKind.temporary, [JunkItem(a.path, 3), JunkItem(b.path, 5)]),
        JunkGroup(JunkKind.largeFiles, [JunkItem(big.path, 7)]),
      ]);
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(const JunkCleanerScreen()));
      await settle(tester);
      await tester.tap(find.text('Scan'));
      await until(tester, find.text('Temporary files'));
      expect(find.text('Review'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Review')).dy,
        greaterThan(tester.getTopLeft(find.text('Temporary files')).dy),
        reason: 'below the junk',
      );
      expect(find.textContaining('Clean 8 B'), findsOneWidget, reason: 'large files are not ticked');
      expect(find.text('8 B'), findsWidgets, reason: 'what can be freed, at the top');
      expect(find.text('15 B found in 3 items'), findsOneWidget);

      await tester.tap(find.byTooltip('Show files').first);
      await settle(tester);
      await tester.tap(find.textContaining('a.tmp'));
      await settle(tester);
      expect(find.textContaining('Clean 5 B'), findsOneWidget, reason: 'one file unticked');

      await tester.tap(find.byTooltip('Show files'));
      await settle(tester);
      await tester.tap(find.textContaining('big.mkv'));
      await settle(tester);
      expect(find.textContaining('Clean 12 B'), findsOneWidget, reason: 'one big file ticked');

      await tester.tap(find.text('Temporary files'));
      await settle(tester);
      expect(find.textContaining('Clean 15 B'), findsOneWidget, reason: 'a kind ticked in part ticks all of it');
      await tester.tap(find.text('Large files'));
      await settle(tester);
      expect(find.textContaining('Clean 8 B'), findsOneWidget, reason: 'and a kind ticked whole unticks');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('junk cleaner: waits for Scan, then scans, cleans and says what it freed', (tester) async {
      final old = DateTime.now().subtract(const Duration(days: 3));
      final temp = p.join(root.path, 'temp');
      final leftover = (await tester.runAsync(() async {
        final file = await save('temp/old.dat', 'old');
        await file.setLastModified(old);
        await (await save('home/Downloads/movie.mkv.part', 'part')).setLastModified(old);
        await save('home/Documents/notes.txt.bak', 'backup');
        return file;
      }))!;
      final userFolders = [p.join(root.path, 'home', 'Downloads'), p.join(root.path, 'home', 'Documents')];
      JunkScanner.scanOverride = _scanOf(temp, userFolders);
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(const JunkCleanerScreen()));
      await settle(tester);
      expect(find.text('Scan'), findsOneWidget);
      expect(find.textContaining('Last cleaned'), findsNothing, reason: 'it never cleaned');
      expect(find.text('Temporary files'), findsNothing, reason: "it doesn't scan by itself");

      await tester.tap(find.text('Scan'));
      await until(tester, find.text('Temporary files'));
      expect(find.text('Unfinished downloads'), findsOneWidget);
      expect(find.text('Backup copies'), findsOneWidget);
      expect(find.textContaining('Clean 3 B'), findsOneWidget, reason: 'only the temporary file is ticked');

      await tester.tap(find.textContaining('Clean 3 B'));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await until(tester, find.text('3 B freed'));
      expect(find.text('1 item deleted'), findsOneWidget);
      expect(find.textContaining("couldn't be deleted"), findsNothing);
      expect(leftover.existsSync(), isFalse);
      expect(exists('home/Downloads/movie.mkv.part'), isTrue);
      expect(exists('home/Documents/notes.txt.bak'), isTrue);
      final prefs = (await tester.runAsync(SharedPreferences.getInstance))!;
      expect(prefs.getInt('junk_cleaner_last_freed'), 3);

      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(find.text('Scan'), findsOneWidget, reason: 'with nowhere to go back to, it starts again');
      expect(find.text('Last cleaned just now: 3 B freed'), findsOneWidget);

      await tester.tap(find.text('Scan'));
      await until(tester, find.text('Backup copies'));
      expect(find.text('Temporary files'), findsNothing, reason: 'it was cleaned');
      expect(find.textContaining('Clean 0 B'), findsOneWidget, reason: 'nothing safe is left to tick');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('junk cleaner: shows the scan going on, and Stop stops it', (tester) async {
      JunkScanner.scanOverride = _slowScan(p.join(root.path, 'Chrome', 'User Data', 'Default', 'Cache'));
      await tester.pumpWidget(themedApp(const JunkCleanerScreen()));
      await settle(tester);
      await tester.tap(find.text('Scan'));
      await until(tester, find.text('Browser caches'));
      expect(find.text('12 items found'), findsOneWidget);
      expect(find.text('3 MB'), findsOneWidget, reason: 'the size found so far');
      expect(find.textContaining('Default${p.separator}Cache'), findsOneWidget, reason: 'where it is looking');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('Stop'));
      await settle(tester);
      expect(find.text('Scan'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      for (var i = 0; i < 4; i++) {
        await settle(tester);
      }
      expect(find.text('Temporary files'), findsNothing, reason: 'what it would have found never shows');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("junk cleaner: says what couldn't be deleted, and shows which", (tester) async {
      final gone = p.join(root.path, 'gone', 'locked.tmp');
      final real = (await tester.runAsync(() => save('Download/x.tmp', '12345')))!;
      JunkScanner.scanOverride = _finds([
        JunkGroup(JunkKind.temporary, [JunkItem(real.path, 5), JunkItem(gone, 9)]),
      ]);
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(const JunkCleanerScreen()));
      await settle(tester);
      await tester.tap(find.text('Scan'));
      await until(tester, find.textContaining('Clean 14 B'));
      await tester.tap(find.textContaining('Clean 14 B'));
      await settle(tester);
      await tester.tap(find.text('Delete'));
      await until(tester, find.text('5 B freed'));
      expect(find.text("1 item couldn't be deleted, as they're in use or protected."), findsOneWidget);

      await tester.tap(find.text('See which'));
      await settle(tester);
      expect(find.text('Not deleted'), findsOneWidget);
      expect(find.text('locked.tmp'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('junk cleaner: the start screen tells when it last cleaned', (tester) async {
      SharedPreferences.setMockInitialValues({
        'junk_cleaner_last_at': DateTime.now().subtract(const Duration(days: 3, hours: 1)).millisecondsSinceEpoch,
        'junk_cleaner_last_freed': 1288490189,
        'junk_cleaner_last_items': 412,
      });
      await tester.pumpWidget(themedApp(const JunkCleanerScreen()));
      await settle(tester);
      expect(find.text('Last cleaned 3 days ago: 1.2 GB freed'), findsOneWidget);
      expect(find.text('Scan'), findsOneWidget);
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

// Scans for the junk cleaner's screen. A scan runs in an isolate of its own,
// so each is made here, where it holds only what it's given.

/// A scan that finds [groups].
List<JunkGroup> Function(JunkReport report) _finds(List<JunkGroup> groups) => (_) => groups;

/// A real scan of [temp] and [userFolders].
List<JunkGroup> Function(JunkReport report) _scanOf(String temp, List<String> userFolders) =>
    (report) => JunkScanner.scanComputer(temp, userFolders: userFolders, onProgress: report);

/// A scan that says where it's looking, then takes its time (ten seconds).
List<JunkGroup> Function(JunkReport report) _slowScan(String place) => (report) {
      report(JunkScanProgress(place: place, kind: JunkKind.browserCaches, items: 12, bytes: 3 * 1024 * 1024));
      for (var i = 0; i < 200; i++) {
        sleep(const Duration(milliseconds: 50));
      }
      return [JunkGroup(JunkKind.temporary, [JunkItem(place, 1)])];
    };
