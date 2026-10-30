import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:explorer/core/theme/icon_strokes.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Screenshot tests only run with SCREENSHOTS=1 (they write PNGs to
/// build/screenshots/ for reviewing the UI; they assert nothing).
final bool screenshotsEnabled = Platform.environment['SCREENSHOTS'] == '1';

/// Loads every font in the app's FontManifest (Geist, Lucide, Material
/// icons, …) so screenshots show real text instead of test boxes.
Future<void> loadAppFonts() async {
  final manifest = json.decode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<dynamic>;
  for (final entry in manifest.cast<Map<String, dynamic>>()) {
    // The app draws its icons with lighter lines (see below).
    if (entry['family'] == 'packages/lucide_icons_flutter/Lucide') continue;
    final loader = FontLoader(entry['family'] as String);
    for (final font in (entry['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(Uri.decodeFull(font['asset'] as String)));
    }
    await loader.load();
  }
  await IconStrokes.useLight();
}

/// Sets the test window to [logicalSize] at [pixelRatio].
void setScreenSize(WidgetTester tester, Size logicalSize,
    {double pixelRatio = 2}) {
  tester.view.physicalSize = logicalSize * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
}

final _frameKey = GlobalKey();

/// Wraps the app so [saveScreenshot] captures it, overlays included.
Widget screenshotFrame(Widget app) =>
    RepaintBoundary(key: _frameKey, child: app);

/// Writes the app (see [screenshotFrame]) to build/screenshots/[name].png.
Future<void> saveScreenshot(WidgetTester tester, String name) async {
  final boundary =
      _frameKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(
      pixelRatio: tester.view.devicePixelRatio,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/screenshots/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}
