import 'dart:io';
import 'dart:math' as math;

import 'package:folders/features/viewer_image/screens/image_editor_screen.dart';
import 'package:folders/features/viewer_image/screens/viewer_image_screen.dart';
import 'package:folders/features/viewer_media/screens/audio_player_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'viewer_shot_helpers.dart';

/// A landscape "photo": sky gradient, sun and hills.
List<int> _photo() {
  final image = img.Image(width: 1200, height: 800);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final t = y / image.height;
      var r = (40 + 180 * t).round(), g = (110 + 90 * t).round(), b = 230 - (60 * t).round();
      final hill = 560 + 60 * math.sin(x / 140) + 30 * math.cos(x / 60);
      if (y > hill) {
        r = 40 + (y - hill).round() ~/ 8;
        g = 120 - (y - hill).round() ~/ 6;
        b = 60;
      }
      final dx = x - 860, dy = y - 260;
      if (dx * dx + dy * dy < 90 * 90) {
        r = 255;
        g = 214;
        b = 102;
      }
      image.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }
  }
  return img.encodePng(image);
}

/// just_audio without a platform: loads instantly with a fixed duration.
void _fakeAudioPlatform() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.just_audio.methods'),
    (call) async {
      if (call.method == 'init') {
        final id = (call.arguments as Map)['id'] as String;
        messenger.setMockMethodCallHandler(
          MethodChannel('com.ryanheise.just_audio.methods.$id'),
          (call) async => call.method == 'load'
              ? <String, dynamic>{'duration': 215 * 1000000}
              : <String, dynamic>{},
        );
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.events.$id'),
          MockStreamHandler.inline(
            onListen: (_, sink) => sink.success(<String, dynamic>{
              'processingState': 3, // ready
              'updateTime': DateTime.now().millisecondsSinceEpoch,
              'updatePosition': 64 * 1000000,
              'bufferedPosition': 215 * 1000000,
              'duration': 215 * 1000000,
            }),
          ),
        );
        messenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.data.$id'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
      }
      return <String, dynamic>{};
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );
}

void main() {
  late Directory dir;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    dir = await Directory.systemTemp.createTemp('viewer_media_shots_');
    final photo = _photo();
    for (final name in ['Lake.png', 'Valley.png', 'Ridge.png']) {
      await File(p.join(dir.path, name)).writeAsBytes(photo);
    }
    await File(p.join(dir.path, 'Morning walk.mp3')).writeAsBytes(List.filled(4096, 0));
    await File(p.join(dir.path, 'Trailer.mp4')).writeAsBytes(List.filled(4096, 0));
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await dir.delete(recursive: true);
  });

  viewerShots('image viewer', (tester, shot) async {
    await shot.open(ImageViewerScreen(imageFile: File(p.join(dir.path, 'Valley.png'))));
    await settle(tester, rounds: 12);
    await shot.shot('image_viewer');
    await tester.tap(find.byTooltip('Details'));
    await settle(tester, rounds: 8);
    await shot.shot('image_details');
  });

  viewerShots('image editor', (tester, shot) async {
    await shot.open(ImageEditorScreen(file: File(p.join(dir.path, 'Lake.png'))));
    await settle(tester, rounds: 14);
    await shot.shot('image_editor_crop');
    await tester.tap(find.text('Adjust'));
    await settle(tester);
    await shot.shot('image_editor_adjust');
    await tester.tap(find.text('Filters'));
    await settle(tester, rounds: 8);
    await shot.shot('image_editor_filters');
  });

  viewerShots('audio player', (tester, shot) async {
    _fakeAudioPlatform();
    await shot.open(AudioPlayerScreen(audioFile: File(p.join(dir.path, 'Morning walk.mp3'))));
    await settle(tester, rounds: 8);
    await shot.shot('audio_player');
  });
}
