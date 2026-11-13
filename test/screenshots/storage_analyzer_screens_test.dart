import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/toolbox/storage_analyzer_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/storage_analyzer_screens_test.dart
/// → build/screenshots/storage_*.png: the Storage analyzer's start, scan
/// results and a folder opened, on a phone and a computer, light and dark,
/// and in the Windows and macOS styles.
void main() {
  late Directory root;

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

  /// Files a hundredth of real sizes, as NTFS reserves the space even for
  /// a file only made long.
  Future<void> sample(WidgetTester tester) => tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('storage_shots_');
        Future<void> save(String path, int size) async {
          final file = File(p.joinAll([root.path, ...path.split('/')]));
          await file.parent.create(recursive: true);
          final open = await file.open(mode: FileMode.write);
          await open.truncate(size);
          await open.close();
        }

        const mb = 10 * 1000;
        await save('Videos/Holidays/Beach 2025.mp4', 1900 * mb);
        await save('Videos/Holidays/Mountains.mp4', 1200 * mb);
        await save('Videos/Concert.mkv', 2600 * mb);
        await save('Videos/Clips/clip1.mov', 340 * mb);
        await save('Videos/Clips/clip2.mov', 280 * mb);
        for (var i = 0; i < 24; i++) {
          await save('Pictures/2025/IMG_${1000 + i}.jpg', (3 + i % 5) * mb);
          await save('Pictures/2024/IMG_${2000 + i}.heic', (2 + i % 4) * mb);
        }
        await save('Pictures/Edits/Panorama.png', 160 * mb);
        await save('Music/Albums/Live at Home.flac', 420 * mb);
        for (var i = 0; i < 18; i++) {
          await save('Music/Singles/Track ${i + 1}.mp3', (6 + i % 4) * mb);
        }
        await save('Documents/Taxes 2025.pdf', 12 * mb);
        await save('Documents/Thesis.docx', 30 * mb);
        await save('Documents/Budget.xlsx', 4 * mb);
        await save('Downloads/setup.exe', 380 * mb);
        await save('Downloads/game.apk', 900 * mb);
        await save('Downloads/backup.zip', 1400 * mb);
        await save('Downloads/photos.7z', 650 * mb);
        await save('Projects/app/build.bin', 520 * mb);
        await save('Projects/app/cache.db', 210 * mb);
      });

  for (final (style, mode, device, size) in [
    (AppStyle.standard, ThemeMode.light, 'phone', const Size(390, 844)),
    (AppStyle.standard, ThemeMode.dark, 'computer', const Size(1280, 800)),
    (AppStyle.windows, ThemeMode.light, 'computer', const Size(1280, 800)),
    (AppStyle.macos, ThemeMode.dark, 'phone', const Size(390, 844)),
  ]) {
    final tag = '${style.name}_${mode.name}_$device';
    testWidgets('storage analyzer $tag', (tester) async {
      await sample(tester);
      addTearDown(() {
        StorageAnalyzerScreen.findPlaces = null;
        AppDelete.override = null;
        try {
          root.deleteSync(recursive: true);
        } on FileSystemException {
          // Cleaned with the system's temporary folder later.
        }
      });
      SharedPreferences.setMockInitialValues({});
      StorageAnalyzerScreen.findPlaces = () async => [
            StoragePlace('Local Disk (C:)', root.path, LucideIcons.hardDrive),
            StoragePlace('Your folder', p.join(root.path, 'Pictures'), LucideIcons.house),
          ];
      setScreenSize(tester, size);
      await tester.pumpWidget(screenshotFrame(themedApp(const StorageAnalyzerScreen(), themeMode: mode, style: style)));
      await settle(tester);
      await saveScreenshot(tester, 'storage_start_$tag');

      await tester.tap(find.text('Local Disk (C:)'));
      await settle(tester, frames: 14);
      await saveScreenshot(tester, 'storage_results_$tag');

      await tester.tap(find.widgetWithText(InkWell, 'Videos').last);
      await settle(tester, frames: 4);
      await saveScreenshot(tester, 'storage_folder_$tag');

      await tester.tap(find.text('Biggest files'));
      await settle(tester, frames: 4);
      await saveScreenshot(tester, 'storage_files_$tag');
      await tester.pumpWidget(const SizedBox());
    }, skip: !screenshotsEnabled);
  }
}
