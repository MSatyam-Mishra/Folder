import 'dart:io';

import 'package:folder/features/viewer_3d/screens/blend_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screenshots.dart';
import 'doc_viewer_harness.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/blend_screens_test.dart
void main() {
  late Directory temp;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    temp = await Directory.systemTemp.createTemp('blend_shots_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await temp.delete(recursive: true);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('blend without meshes ${mode.name}', (tester) async {
      await pumpViewer(
        tester,
        BlendViewerScreen(
          file: File('test/fixtures/blend/no_mesh_gzip.blend'),
        ),
        mode: mode,
        size: const Size(390, 844),
      );
      await settleUntil(tester, find.text('Nothing to show in 3D'));
      await saveScreenshot(tester, 'blend_empty_${mode.name}_phone');
    }, skip: !screenshotsEnabled);
  }
}
