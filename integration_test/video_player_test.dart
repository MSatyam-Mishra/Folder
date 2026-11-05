import 'dart:io';

import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/features/video_player/video_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/screenshots.dart';
import '../test/support/themed_app.dart';

/// With real libmpv, needing FFmpeg to make a video:
/// `flutter test integration_test/video_player_test.dart -d windows`
/// The picture shows, a subtitle file beside the video is picked up, and the
/// keys work. Also writes build/screenshots/player_*.png.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plays a file: picture, subtitles beside it, keys', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Desktop.initMedia();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('explorer_player')))!;
    addTearDown(() => dir.delete(recursive: true));
    final video = p.join(dir.path, 'Clip.mp4');
    await tester.runAsync(() async {
      final made = await Process.run('ffmpeg', [
        '-y', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=25:duration=20',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=20',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac',
        video,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      await File(p.join(dir.path, 'Clip.srt')).writeAsString(
        '1\n00:00:00,000 --> 00:00:19,000\nThe subtitle beside it\n',
      );
    });

    Future<void> rounds(int count) async {
      for (var i = 0; i < count; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.pumpWidget(screenshotFrame(themedApp(VideoPlayerPage(playlist: [video]))));
    for (var i = 0; i < 80 && find.text('The subtitle beside it').evaluate().isEmpty; i++) {
      await rounds(1);
    }
    expect(find.text('The subtitle beside it'), findsOneWidget);
    expect(find.text('Clip.mp4'), findsOneWidget);
    await saveScreenshot(tester, 'player_controls');

    // Space pauses, and the controls stay.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await rounds(5);
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsNothing);

    await saveScreenshot(tester, 'player_paused');
    await tester.pumpWidget(const SizedBox());
    await rounds(3);
  });
}
