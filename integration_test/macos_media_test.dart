import 'dart:io';

import 'package:folders/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

/// On a Mac, from the repo:
/// `flutter test integration_test/macos_media_test.dart -d macos --dart-define=EXPLORER_ROOT=$PWD`
///
/// MKV and WebM, which AVFoundation can't open, play through mpv: the app
/// started with the video shows it in its video viewer, and mpv decodes the
/// picture and plays.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const root = String.fromEnvironment('EXPLORER_ROOT');
  File fixture(String name) => File(p.join(
        root.isEmpty ? Directory.current.path : root,
        'integration_test',
        'fixtures',
        name,
      ));

  /// Pumps until [done] holds, for up to about [seconds].
  Future<void> waitFor(WidgetTester tester, bool Function() done, String what, {int seconds = 20}) async {
    for (var i = 0; i < seconds * 10 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done(), isTrue, reason: 'timed out waiting for $what');
  }

  testWidgets('the app plays MKV and WebM in its video viewer', (tester) async {
    final mkv = fixture('sample.mkv');
    expect(mkv.existsSync(), isTrue, reason: mkv.path);
    app.main([mkv.path]);

    await waitFor(tester, () => find.byType(Video).evaluate().isNotEmpty, 'the video viewer');
    expect(find.text("Can't play this video"), findsNothing);
    final player = tester.widget<Video>(find.byType(Video)).controller.player;

    Future<void> plays(String name) async {
      await waitFor(tester, () => player.state.width == 160 && player.state.height == 120, '$name picture');
      expect(player.state.duration, greaterThan(const Duration(seconds: 1)));
      await player.play();
      await waitFor(tester, () => player.state.position > const Duration(milliseconds: 300), '$name to play');
    }

    await plays('sample.mkv');

    // Another file in the same player: VP9 in WebM.
    await player.open(Media(fixture('sample.webm').path));
    await waitFor(
      tester,
      () => player.state.playlist.medias.any((m) => m.uri.endsWith('sample.webm')) &&
          player.state.position < const Duration(milliseconds: 300),
      'the WebM',
    );
    await plays('sample.webm');
    expect(find.text("Can't play this video"), findsNothing);
  }, skip: !Platform.isMacOS);
}
