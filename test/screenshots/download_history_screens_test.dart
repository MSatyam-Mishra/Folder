import 'package:folders/core/services/video_downloader/downloader_backend.dart';
import 'package:folders/core/services/video_downloader/downloader_settings.dart';
import 'package:folders/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folders/core/services/video_downloader/ytdlp_models.dart';
import 'package:folders/features/video_downloader/widgets/history_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  setUpAll(() async {
    if (screenshotsEnabled) await loadAppFonts();
  });

  testWidgets('download history: a playlist folder and its downloads', (tester) async {
    SharedPreferences.setMockInitialValues({});
    setScreenSize(tester, const Size(420, 760));
    final out = p.join('downloads', 'Folders Videos');
    final now = DateTime(2026, 10, 23, 15, 40);
    HistoryEntry entry(String title, int mb, {String? playlist, int minutes = 0}) => HistoryEntry(
          id: title,
          title: title,
          url: 'https://www.youtube.com/watch?v=$title',
          filePath: p.join(out, playlist ?? '', '$title.mp4'),
          completedAt: now.subtract(Duration(minutes: minutes)),
          sizeBytes: mb * 1000000,
          extractor: 'Youtube',
          duration: 200.0 + mb,
          playlist: playlist,
        );
    final controller = VideoDownloaderController(const UnsupportedDownloaderBackend())
      ..settings = DownloaderSettings(outputDir: out)
      ..history = [
        entry('Lo-fi beats to study to', 48, playlist: 'Chill mix 2026', minutes: 1),
        entry('Rainy night jazz', 61, playlist: 'Chill mix 2026', minutes: 3),
        entry('Conference keynote', 220, minutes: 9),
        entry('Morning acoustic', 35, playlist: 'Chill mix 2026', minutes: 12),
        entry('Trailer', 18, minutes: 30),
      ];

    await tester.pumpWidget(screenshotFrame(themedApp(
      Scaffold(
        body: SafeArea(
          child: HistoryList(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();
    await saveScreenshot(tester, 'download_history');

    await tester.tap(find.text('Chill mix 2026'));
    await tester.pumpAndSettle();
    await saveScreenshot(tester, 'download_history_playlist');
  }, skip: !screenshotsEnabled);
}
