import 'dart:io';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/services/social_files.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:explorer/features/file_explorere/widgets/social_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// An app's saved files: All files, and a tab for each folder.
void main() {
  late Directory root;

  Future<void> save(String path, [String text = 'x']) async {
    final file = File(p.joinAll([root.path, ...path.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_social');
    SocialFiles.storageOverride = root.path;
    const media = 'Android/media/com.whatsapp/WhatsApp/Media';
    await save('$media/WhatsApp Images/IMG-1.jpg');
    await save('$media/WhatsApp Images/Sent/IMG-2.jpg');
    await save('$media/WhatsApp Images/.nomedia');
    await save('$media/WhatsApp Video/VID-1.mp4');
    await save('$media/WhatsApp Documents/report.pdf');
    await save('$media/.Statuses/status.jpg');
    await save('$media/.Links/link.jpg');
    // The older place: the same tabs.
    await save('WhatsApp/Media/WhatsApp Images/IMG-old.jpg');
    await save('Pictures/Instagram/insta.jpg');
    await save('Movies/Instagram/reel.mp4');
    await save('Telegram/Telegram Video/tg.mp4');
    await save('Telegram/loose.txt');
    await save('Download/unrelated.pdf');
  });

  tearDown(() async {
    SocialFiles.storageOverride = null;
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
  });

  Future<List<String>> names(String path) async =>
      [for (final e in await SocialFiles.list(path)) p.basename(e.path)]..sort();

  group('paths', () {
    test('an app and a tab, even one with spaces', () {
      final path = ExplorerPaths.socialPath('whatsapp', 'Voice Notes');
      expect(ExplorerPaths.isSocial(path), isTrue);
      expect(ExplorerPaths.isVirtual(path), isTrue, reason: 'nothing can be created or pasted there');
      expect(ExplorerPaths.socialAppOf(path), 'whatsapp');
      expect(ExplorerPaths.socialTabOf(path), 'Voice Notes');
      expect(ExplorerPaths.socialTabOf(ExplorerPaths.socialPath('whatsapp')), isNull);
    });

    test('back goes from a tab to All files, then home', () {
      final all = ExplorerPaths.socialPath('whatsapp');
      expect(ExplorerPaths.parentOf(ExplorerPaths.socialPath('whatsapp', 'Video')), all);
      expect(ExplorerPaths.parentOf(all), ExplorerPaths.homePath);
    });

    test('the title is the app, or the tab', () {
      expect(ExplorerPaths.titleForPath(ExplorerPaths.socialPath('whatsapp')), 'WhatsApp');
      expect(ExplorerPaths.titleForPath(ExplorerPaths.socialPath('whatsapp', 'Video')), 'Video');
    });
  });

  group('tabs', () {
    test('short names, hidden ones only for statuses, old and new places merged', () async {
      expect(await SocialFiles.tabs(SocialApp.whatsapp), ['Documents', 'Images', 'Statuses', 'Video']);
    });

    test('folders of their own become tabs by kind', () async {
      expect(await SocialFiles.tabs(SocialApp.instagram), ['Images', 'Video']);
    });

    test('an app with nothing saved has none', () async {
      expect(await SocialFiles.tabs(SocialApp.twitter), isEmpty);
    });
  });

  group('files', () {
    test('All files has every file of the app, from inside subfolders too', () async {
      expect(await names(ExplorerPaths.socialPath('whatsapp')), [
        'IMG-1.jpg',
        'IMG-2.jpg',
        'IMG-old.jpg',
        'VID-1.mp4',
        'report.pdf',
        'status.jpg',
      ]);
    });

    test('a tab has its own, from every place', () async {
      expect(await names(ExplorerPaths.socialPath('whatsapp', 'Images')), ['IMG-1.jpg', 'IMG-2.jpg', 'IMG-old.jpg']);
    });

    test('files loose in the app folder are in All files', () async {
      expect(await names(ExplorerPaths.socialPath('telegram')), ['loose.txt', 'tg.mp4']);
    });

    test('other apps and folders stay out', () async {
      expect(await names(ExplorerPaths.socialPath('instagram')), ['insta.jpg', 'reel.mp4']);
    });
  });

  group('in the browser', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> until(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
        await settle(tester);
      }
      await settle(tester);
    }

    Future<void> open(WidgetTester tester, String path) async {
      ExplorerPaths.startFolder = path;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    }

    testWidgets('files show like any others, under tabs; a tab shows its own', (tester) async {
      await open(tester, ExplorerPaths.socialPath('whatsapp'));
      await until(tester, find.text('VID-1.mp4'));
      expect(find.byType(SocialTabs), findsOneWidget);
      expect(find.text('All files'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('New folder'), findsNothing, reason: "it's not a folder to create in");

      await until(tester, find.text('Images'));
      await tester.tap(find.text('Images'));
      await until(tester, find.text('IMG-old.jpg'));
      expect(find.text('VID-1.mp4'), findsNothing);
      expect(find.text('IMG-1.jpg'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an app with nothing says so, and its tabs stay', (tester) async {
      await open(tester, ExplorerPaths.socialPath('twitter'));
      await until(tester, find.text('No files here yet'));
      expect(find.text('No files here yet'), findsOneWidget);
      expect(find.text('All files'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
