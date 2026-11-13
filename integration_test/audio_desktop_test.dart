import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/services/audio/audio_support.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

/// On a computer with ffmpeg on the PATH:
/// `flutter test integration_test/audio_desktop_test.dart -d windows`.
/// libmpv's Windows build reads no AMR and no CAF: such files must fail
/// rather than hang, and then open from a copy FFmpeg converts.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AMR and CAF open through a converted copy', (tester) async {
    await tester.runAsync(() async {
      Desktop.initMedia();
      final dir = await Directory.systemTemp.createTemp('folders_audio_test');
      try {
        final files = <String, List<String>>{
          'tone.mp3': ['-c:a', 'libmp3lame'],
          'tone.amr': ['-ar', '8000', '-ac', '1', '-c:a', 'libopencore_amrnb'],
          'tone.caf': ['-c:a', 'pcm_s16le'],
        };
        for (final MapEntry(key: name, value: codec) in files.entries) {
          final made = await Process.run('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=f=440:d=4', ...codec, p.join(dir.path, name)]);
          expect(made.exitCode, 0, reason: '${made.stderr}');
        }
        for (final name in files.keys) {
          final path = p.join(dir.path, name);
          final direct = AudioPlayer();
          try {
            await direct.setFilePath(path).timeout(const Duration(seconds: 40));
            debugPrint('AUDIO: $name opens as it is');
          } on TimeoutException {
            fail('$name: the load hung');
          } catch (e) {
            debugPrint('AUDIO: $name fails as it is: $e');
          } finally {
            await direct.dispose();
          }

          final player = AudioPlayer();
          try {
            final duration = await AudioSupport.load(player, path).timeout(const Duration(seconds: 40));
            unawaited(player.play());
            await Future<void>.delayed(const Duration(milliseconds: 2500));
            // A computer without a sound device (as the one this was written
            // on) doesn't move on, so only the loading counts.
            debugPrint('AUDIO: $name: duration ${duration?.inMilliseconds} ms, at ${player.position.inMilliseconds} ms after 2.5 s');
            expect(duration, greaterThan(const Duration(seconds: 3)), reason: '$name opens, with its length');
          } finally {
            await player.dispose();
          }
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
