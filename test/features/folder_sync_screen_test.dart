import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/services/toolbox/sync_pairs.dart';
import 'package:folders/features/toolbox/folder_sync_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Folder sync's screen: choose two folders, compare, preview, sync.
void main() {
  late Directory root;
  final deleted = <String>[];
  final base = DateTime(2026, 6, 1, 12);

  String at(String path) => p.joinAll([root.path, ...path.split('/')]);

  Future<void> save(WidgetTester tester, String path, String text, {Duration age = Duration.zero}) async {
    await tester.runAsync(() async {
      final file = File(at(path));
      await file.parent.create(recursive: true);
      await file.writeAsString(text);
      await file.setLastModified(base.subtract(age));
    });
  }

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
    expect(finder, findsWidgets);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('explorer_sync_screen');
    SharedPreferences.setMockInitialValues({});
    deleted.clear();
    AppDelete.override = (path) async {
      deleted.add(p.relative(path, from: root.path).replaceAll(r'\', '/'));
      if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else {
        File(path).deleteSync();
      }
    };
  });

  tearDown(() {
    FolderSyncScreen.pickFolder = null;
    AppDelete.override = null;
    BackgroundTasks.instance.reset();
    root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final picks = [at('left'), at('right')];
    FolderSyncScreen.pickFolder = (_) async => picks.removeAt(0);
    await tester.pumpWidget(themedApp(const FolderSyncScreen()));
    await settle(tester);
    await tester.tap(find.text('Choose a folder').first);
    await settle(tester);
    await tester.tap(find.text('Choose a folder'));
    await settle(tester);
    expect(find.text(at('left')), findsOneWidget);
    expect(find.text(at('right')), findsOneWidget);
  }

  testWidgets('compare, preview the mirror with its warning, sync, and save the pair', (tester) async {
    await save(tester, 'left/a.txt', 'only on the left');
    await save(tester, 'right/b.txt', 'only on the right');
    await save(tester, 'left/c.txt', 'newer');
    await save(tester, 'right/c.txt', 'old', age: const Duration(days: 1));
    await save(tester, 'left/same.txt', 'same');
    await save(tester, 'right/same.txt', 'same');
    await open(tester);

    await tester.tap(find.text('Compare'));
    await until(tester, find.text('3 differences'));
    expect(find.text('1 file the same on both sides (4 B)'), findsOneWidget);
    for (final group in ['Only on the left', 'Only on the right', 'Newer on the left']) {
      expect(find.text(group), findsOneWidget, reason: group);
    }
    expect(find.textContaining('a.txt'), findsOneWidget, reason: 'a short list shows its files');

    await tester.tap(find.text('Mirror'));
    await settle(tester);
    expect(find.textContaining('exact copy of the left'), findsOneWidget);
    await tester.tap(find.text('Preview'));
    await until(tester, find.text('What will happen'));
    expect(find.text('Copy to the right'), findsOneWidget);
    expect(find.text('Replace on the right'), findsOneWidget);
    expect(find.text('Delete on the right'), findsOneWidget);
    expect(find.textContaining('Mirror deletes 1 item on the right'), findsOneWidget);
    expect(File(at('right/b.txt')).existsSync(), isTrue, reason: 'nothing is done before the user says so');

    await tester.tap(find.text('Sync and delete 1'));
    await until(tester, find.text('Synced'));
    expect(find.text('1 copied, 1 replaced, 1 deleted'), findsOneWidget);
    expect(File(at('right/a.txt')).readAsStringSync(), 'only on the left');
    expect(File(at('right/c.txt')).readAsStringSync(), 'newer');
    expect(File(at('right/b.txt')).existsSync(), isFalse);
    expect(deleted, unorderedEquals(['right/c.txt', 'right/b.txt']), reason: "through the browser's delete");
    expect(BackgroundTasks.instance.all.single.headline, 'Sync in progress');
    expect(BackgroundTasks.instance.all.single.status, TaskStatus.done);

    await tester.tap(find.byTooltip('Save this pair'));
    await settle(tester);
    expect(find.text('left → right'), findsOneWidget, reason: 'a name to start from');
    await tester.tap(find.text('Save'));
    await settle(tester);
    final pairs = await tester.runAsync(SyncPairs.load);
    expect(pairs!.single.name, 'left → right');
    expect(pairs.single.left, at('left'));

    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Saved pairs'), findsOneWidget);
    expect(find.text('left → right'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two-way lists its conflicts, and a choice for all settles them', (tester) async {
    await save(tester, 'left/clash.txt', 'short');
    await save(tester, 'right/clash.txt', 'much longer');
    await save(tester, 'right/new.txt', 'new');
    await open(tester);

    await tester.tap(find.text('Compare'));
    await until(tester, find.text('2 differences'));
    await tester.tap(find.text('Two-way'));
    await tester.tap(find.text('Preview'));
    await until(tester, find.text('Conflicts'));
    expect(find.text('Copy to the left'), findsOneWidget);
    expect(find.text('1 conflict left as they are'), findsOneWidget);
    expect(find.textContaining('Same date, but they differ'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget, reason: 'two-way never deletes');

    await tester.tap(find.text('Keep left'));
    await settle(tester);
    expect(find.text('Replace on the right'), findsOneWidget);
    expect(find.text('1 conflict left as they are'), findsNothing);

    await tester.tap(find.text('Sync now'));
    await until(tester, find.text('Synced'));
    expect(File(at('right/clash.txt')).readAsStringSync(), 'short');
    expect(File(at('left/new.txt')).readAsStringSync(), 'new');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('refuses the same folder twice, and one inside the other', (tester) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => Directory(at('left/inner')).create(recursive: true));
    final picks = [at('left'), at('left/inner')];
    FolderSyncScreen.pickFolder = (_) async => picks.removeAt(0);
    await tester.pumpWidget(themedApp(const FolderSyncScreen()));
    await settle(tester);
    await tester.tap(find.text('Compare'));
    await settle(tester);
    expect(find.text('Choose both folders'), findsOneWidget);
    await tester.tap(find.text('Choose a folder').first);
    await settle(tester);
    await tester.tap(find.text('Choose a folder'));
    await settle(tester);
    await tester.tap(find.text('Compare'));
    await settle(tester);
    expect(find.text('One folder is inside the other'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
