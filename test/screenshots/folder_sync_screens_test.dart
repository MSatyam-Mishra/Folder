import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/toolbox/folder_sync_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/folder_sync_screens_test.dart
/// → build/screenshots/sync_*.png: Folder sync's start, results, preview,
/// running and stopped, on a phone and a computer, light and dark, and in the Windows
/// and macOS styles (the iOS style's own icon set needs a test of its own).
void main() {
  late Directory root;
  final base = DateTime(2026, 10, 20, 9);

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
  });

  Future<void> settle(WidgetTester tester, {int frames = 8}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> sample(WidgetTester tester) => tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('sync_shots_');
        Future<void> save(String path, int size, {int days = 0}) async {
          final file = File(p.joinAll([root.path, ...path.split('/')]));
          await file.parent.create(recursive: true);
          await file.writeAsBytes(List.filled(size, 65));
          await file.setLastModified(base.subtract(Duration(days: days)));
        }

        for (var i = 0; i < 6; i++) {
          await save('Photos/2026/IMG_10$i.jpg', 2400000 + i * 1000);
          await save('Backup/2026/IMG_10$i.jpg', 2400000 + i * 1000);
        }
        await save('Photos/2026/IMG_200.jpg', 3100000);
        await save('Photos/2026/IMG_201.jpg', 2800000);
        await save('Photos/Edits/Beach.png', 9100000);
        await save('Photos/Edits/Sunset.png', 7700000);
        await save('Photos/notes.txt', 1200);
        await save('Backup/notes.txt', 900, days: 4);
        await save('Photos/album.json', 4000, days: 2);
        await save('Backup/album.json', 4400);
        await save('Backup/old/IMG_001.jpg', 2200000);
        await save('Backup/Thumbs.db', 36000);
      });

  for (final (style, mode, device, size) in [
    (AppStyle.standard, ThemeMode.light, 'phone', const Size(390, 844)),
    (AppStyle.standard, ThemeMode.dark, 'computer', const Size(1280, 800)),
    (AppStyle.windows, ThemeMode.light, 'computer', const Size(1280, 800)),
    (AppStyle.macos, ThemeMode.dark, 'phone', const Size(390, 844)),
  ]) {
    final tag = '${style.name}_${mode.name}_$device';
    testWidgets('folder sync $tag', (tester) async {
      await sample(tester);
      addTearDown(() {
        FolderSyncScreen.pickFolder = null;
        AppDelete.override = null;
        BackgroundTasks.instance.reset();
        try {
          root.deleteSync(recursive: true);
        } on FileSystemException {
          // Still open somewhere; the system's temporary folder is cleaned later.
        }
      });
      AppDelete.override = (path) async {
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory) {
          Directory(path).deleteSync(recursive: true);
        } else {
          File(path).deleteSync();
        }
      };
      SharedPreferences.setMockInitialValues({
        'folder_sync_pairs': '[{"id":"a","name":"Music → USB stick","left":"C:/Users/me/Music","right":"E:/Music",'
            '"mode":"mirror","lastRun":${base.millisecondsSinceEpoch},"lastSummary":"14 copied, 2 deleted"}]',
      });
      final picks = [p.join(root.path, 'Photos'), p.join(root.path, 'Backup')];
      FolderSyncScreen.pickFolder = (_) async => picks.removeAt(0);
      setScreenSize(tester, size);
      await tester.pumpWidget(screenshotFrame(themedApp(const FolderSyncScreen(), themeMode: mode, style: style)));
      await settle(tester);
      await tester.tap(find.text('Choose a folder').first);
      await settle(tester, frames: 2);
      await tester.tap(find.text('Choose a folder'));
      await settle(tester, frames: 2);
      await saveScreenshot(tester, 'sync_start_$tag');

      await tester.tap(find.text('Compare'));
      await settle(tester, frames: 14);
      await saveScreenshot(tester, 'sync_results_$tag');

      await tester.tap(find.text('Mirror'));
      await tester.tap(find.text('Preview'));
      await settle(tester, frames: 4);
      await saveScreenshot(tester, 'sync_preview_$tag');

      await tester.tap(find.textContaining('Sync and delete'));
      await settle(tester, frames: 6);
      await saveScreenshot(tester, 'sync_running_$tag');
      await tester.tap(find.text('Cancel'));
      await settle(tester, frames: 10);
      await saveScreenshot(tester, 'sync_stopped_$tag');
      await tester.pumpWidget(const SizedBox());
    }, skip: !screenshotsEnabled);
  }
}
