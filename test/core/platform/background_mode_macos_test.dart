@TestOn('mac-os')
library;

import 'dart:ui' show AppExitResponse;

import 'package:folders/core/platform/background_mode.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cmd+Q, Quit in the Dock and logging out on macOS: the Tasks view while
/// work goes on, as for the close button, and quit() still quits.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  const display = {
    'id': '1',
    'name': 'Built-in',
    'size': {'width': 1440.0, 'height': 900.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
    'visibleSize': {'width': 1440.0, 'height': 875.0},
    'scaleFactor': 2,
  };

  setUpAll(() async {
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'getBounds' => {'x': 100.0, 'y': 100.0, 'width': 1200.0, 'height': 800.0},
        'isMinimized' => false,
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.leanflutter.plugins/screen_retriever'),
      (call) async => switch (call.method) {
        'getPrimaryDisplay' => display,
        'getAllDisplays' => {
            'displays': [display],
          },
        'getCursorScreenPoint' => {'dx': 10.0, 'dy': 10.0},
        _ => null,
      },
    );
    await BackgroundMode.instance.init();
  });

  tearDown(BackgroundTasks.instance.reset);

  Future<AppExitResponse> quitAsked() => WidgetsBinding.instance.handleRequestAppExit();

  test('quits at once when nothing is running', () async {
    calls.clear();
    expect(await quitAsked(), AppExitResponse.exit);
    expect(BackgroundMode.instance.tasksOnly, isFalse);
    expect(calls, isEmpty);
  });

  test('while a copy runs, the window shows the Tasks view instead', () async {
    BackgroundTasks.instance.start('Copying');
    calls.clear();
    expect(await quitAsked(), AppExitResponse.cancel);
    await pumpEventQueue();
    expect(BackgroundMode.instance.tasksOnly, isTrue);
    expect(calls, containsAllInOrder(['show', 'setBounds']));
    expect(calls, isNot(contains('destroy')));
    await BackgroundMode.instance.openExplorer();
  });

  test('asked again with the Tasks view up, it quits', () async {
    BackgroundTasks.instance.start('Copying');
    expect(await quitAsked(), AppExitResponse.cancel);
    await pumpEventQueue();
    expect(await quitAsked(), AppExitResponse.exit);

    // Back in Folders, the next quit shows the Tasks view first again.
    await BackgroundMode.instance.openExplorer();
    expect(await quitAsked(), AppExitResponse.cancel);
    await pumpEventQueue();
    await BackgroundMode.instance.openExplorer();
  });

  test('quit() gets through, even while work goes on', () async {
    BackgroundTasks.instance.start('Copying');
    await BackgroundMode.instance.quit();
    expect(calls, contains('destroy'));
    expect(await quitAsked(), AppExitResponse.exit);
  });
}
