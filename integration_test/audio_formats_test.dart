import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/audio/audio_support.dart';
import 'package:folders/core/services/audio/routing_audio_platform.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

/// On an Android device: `flutter test integration_test/audio_formats_test.dart -d DEVICE`.
/// Meanwhile, copy sound files (made with ffmpeg: tone.mp3, tone.wma,
/// tone.aiff, tone-pcm.caf...) to `<app's external files>/audio/`, then an
/// empty file named `ready` there. Each file is played for a moment through
/// just_audio as the app does; a `AUDIO:` line says how it went.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sound files play, or say why not', (tester) async {
    await tester.runAsync(() async {
      MediaKit.ensureInitialized();
      AudioSupport.initAndroid();
      final routing = JustAudioPlatform.instance as RoutingAudioPlatform;
      final folder = Directory('${(await getExternalStorageDirectory())!.path}/audio');
      debugPrint('AUDIO: waiting for ${folder.path}/ready');
      for (var i = 0; i < 300 && !File('${folder.path}/ready').existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final files = folder.listSync().whereType<File>().where((f) => !f.path.endsWith('ready')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(files, isNotEmpty);
      final results = <String, bool>{};
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final player = AudioPlayer();
        try {
          final duration = await player.setFilePath(file.path).timeout(const Duration(seconds: 30));
          final via = routing.players.last.usesFallback ? 'libmpv' : 'ExoPlayer';
          unawaited(player.play());
          await Future<void>.delayed(const Duration(milliseconds: 2500));
          final position = player.position;
          final played = position > const Duration(milliseconds: 800);
          results[name] = played;
          debugPrint('AUDIO: $name: ${played ? 'played' : 'did not play'} through $via, '
              'duration ${duration?.inMilliseconds} ms, at ${position.inMilliseconds} ms after 2.5 s');
        } catch (e) {
          results[name] = false;
          debugPrint('AUDIO: $name: failed: $e; the app says: ${AudioSupport.whyNot(file.path) ?? '(generic message)'}');
        } finally {
          await player.dispose();
        }
      }
      for (final name in ['tone.mp3', 'tone.wma', 'tone.aiff']) {
        if (results.containsKey(name)) expect(results[name], isTrue, reason: '$name should play');
      }
    });
  });
}
