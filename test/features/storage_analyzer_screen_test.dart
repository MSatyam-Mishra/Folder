import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/features/toolbox/storage_analyzer_screen.dart';
import 'package:folders/features/toolbox/storage_treemap.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The Storage analyzer's screen: pick a place, scan it, find your way
/// around the map and the lists, and delete something.
void main() {
  late Directory root;
  final deleted = <String>[];
  final shown = <String>[];

  String at(String path) => p.joinAll([root.path, ...path.split('/')]);

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
    root = Directory.systemTemp.createTempSync('explorer_storage_screen');
    SharedPreferences.setMockInitialValues({});
    void save(String path, int size) {
      final file = File(at(path));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(List.filled(size, 1));
    }

    save('Videos/Holiday/beach.mp4', 900000);
    save('Videos/clip.mov', 300000);
    save('Photos/sunset.jpg', 250000);
    save('Music/song.mp3', 120000);
    save('notes.txt', 2000);
    deleted.clear();
    shown.clear();
    AppDelete.override = (path) async {
      deleted.add(p.relative(path, from: root.path).replaceAll(r'\', '/'));
      if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else {
        File(path).deleteSync();
      }
    };
    StorageAnalyzerScreen.findPlaces = () async => [StoragePlace('Test folder', root.path, LucideIcons.house)];
    StorageAnalyzerScreen.showFolder = shown.add;
  });

  tearDown(() {
    AppDelete.override = null;
    StorageAnalyzerScreen.findPlaces = null;
    StorageAnalyzerScreen.pickFolder = null;
    StorageAnalyzerScreen.showFolder = null;
    root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const StorageAnalyzerScreen()));
    await settle(tester);
    expect(find.text('See what takes up space'), findsOneWidget);
  }

  testWidgets('scan a folder, open its folders, and come back', (tester) async {
    await open(tester, const Size(1280, 900));
    await tester.tap(find.text('Test folder'));
    await until(tester, find.byType(StorageTreemap));

    // The folder by kind, with the biggest first in the list.
    expect(find.text('Videos'), findsWidgets);
    expect(find.text('Photos'), findsWidgets);
    expect(find.text('Music'), findsWidgets);
    expect(find.textContaining('5 files'), findsWidgets);
    expect(find.text('Biggest here'), findsOneWidget);

    // A folder's row opens it, with the way back above.
    await tester.tap(find.widgetWithText(InkWell, 'Videos').last);
    await settle(tester);
    expect(find.text('Holiday'), findsWidgets);
    expect(find.text('clip.mov'), findsWidgets);
    expect(find.text(p.basename(root.path)), findsOneWidget, reason: 'the scanned folder in the trail');

    // Its biggest files, however deep.
    await tester.tap(find.text('Biggest files'));
    await settle(tester);
    expect(find.text('beach.mp4'), findsWidgets);

    // Back up by the trail.
    await tester.tap(find.text(p.basename(root.path)));
    await settle(tester);
    expect(find.text('notes.txt'), findsWidgets);
  });

  testWidgets('a file can be shown in its folder, and deleted', (tester) async {
    await open(tester, const Size(1280, 900));
    await tester.tap(find.text('Test folder'));
    await until(tester, find.byType(StorageTreemap));

    await tester.tap(find.widgetWithText(InkWell, 'Photos').last);
    await settle(tester);
    await tester.tap(find.byTooltip('More').first);
    await settle(tester);
    expect(find.text('Open'), findsOneWidget);
    await tester.tap(find.text('Show in folder'));
    await settle(tester);
    expect(shown, [at('Photos')]);

    await tester.tap(find.byTooltip('More').first);
    await settle(tester);
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('Delete "sunset.jpg"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(deleted, ['Photos/sunset.jpg']);
    expect(find.text('sunset.jpg'), findsNothing);
    expect(find.text('This folder is empty'), findsOneWidget);
  });

  testWidgets('on a phone the list is under the map, and a folder can be chosen', (tester) async {
    await open(tester, const Size(400, 860));
    StorageAnalyzerScreen.pickFolder = () async => at('Videos');
    await tester.tap(find.text('Choose a folder…'));
    await until(tester, find.byType(StorageTreemap));
    expect(find.text('Holiday'), findsWidgets);
    expect(find.text('notes.txt'), findsNothing, reason: 'only the chosen folder');
    expect(tester.takeException(), isNull);

    // Back climbs the map: here, the top already, so nothing to climb.
    await tester.tap(find.widgetWithText(InkWell, 'Holiday').last);
    await settle(tester);
    expect(find.text('beach.mp4'), findsWidgets);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    await navigator.maybePop();
    await settle(tester);
    expect(find.text('clip.mov'), findsWidgets, reason: 'Back went up a folder, not out');
  });

  testWidgets('Stop ends a scan at once', (tester) async {
    for (var i = 0; i < 300; i++) {
      final file = File(at('many/f$i/x.bin'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(const [1, 2, 3]);
    }
    await open(tester, const Size(1280, 900));
    await tester.tap(find.text('Test folder'));
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await settle(tester);
    expect(find.text('See what takes up space'), findsOneWidget);
    expect(find.byType(StorageTreemap), findsNothing);
  });
}
