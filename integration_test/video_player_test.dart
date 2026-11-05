import 'dart:io';

import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/features/video_player/video_player_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
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

    // A pinch zooms the picture, and not the subtitles.
    double zoom() => tester
        .widget<Transform>(find.ancestor(of: find.byType(Video), matching: find.byType(Transform)).first)
        .transform
        .getMaxScaleOnAxis();
    expect(zoom(), 1);
    final subtitleBefore = tester.getCenter(find.text('The subtitle beside it'));
    final middle = tester.getCenter(find.byType(VideoPlayerPage));
    final one = await tester.createGesture(pointer: 11, kind: PointerDeviceKind.touch);
    final two = await tester.createGesture(pointer: 12, kind: PointerDeviceKind.touch);
    await one.down(middle - const Offset(60, 0));
    await two.down(middle + const Offset(60, 0));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await one.moveBy(const Offset(-20, 0));
      await two.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await one.up();
    await two.up();
    await rounds(3);
    expect(zoom(), greaterThan(1.5));
    expect(find.textContaining('Zoom '), findsOneWidget);
    expect(tester.getCenter(find.text('The subtitle beside it')), subtitleBefore);
    await saveScreenshot(tester, 'player_zoomed');

    // 0 goes back; so does the picture button.
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    await rounds(2);
    expect(zoom(), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await rounds(2);
    expect(zoom(), 1.25);
    await tester.tap(find.byTooltip('Picture: Fit'));
    await rounds(2);
    expect(zoom(), 1);
    expect(find.byTooltip('Picture: Fit'), findsOneWidget, reason: 'the first tap only undoes the zoom');

    // The decoder, beside the audio.
    await tester.tap(find.byTooltip('Decoder'));
    await rounds(4);
    expect(find.text('HW · Hardware'), findsOneWidget);
    expect(find.text('SW · Software'), findsOneWidget);
    await saveScreenshot(tester, 'player_decoder');
    await tester.tap(find.text('SW · Software'));
    await rounds(6);
    expect(find.text('SW'), findsOneWidget, reason: 'on the button now');
    await tester.pumpWidget(const SizedBox());
    await rounds(3);
  });

  testWidgets('a subtitle file it cannot read stops nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Desktop.initMedia();
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('explorer_player_bad')))!;
    addTearDown(() => dir.delete(recursive: true));
    final video = p.join(dir.path, 'Clip.mp4');
    await tester.runAsync(() async {
      final made = await Process.run('ffmpeg', [
        '-y', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc=size=320x180:rate=25:duration=20',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
        video,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      await File(p.join(dir.path, 'Clip.srt')).writeAsBytes(List.generate(8192, (i) => i * 31 % 251));
    });
    await tester.pumpWidget(screenshotFrame(themedApp(VideoPlayerPage(playlist: [video]))));
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.textContaining("Can't play"), findsNothing);
    expect(find.text('Open with another app'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
