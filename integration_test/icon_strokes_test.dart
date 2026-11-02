import 'dart:ui' as ui;

import 'package:explorer/core/theme/icon_strokes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// On a device: `flutter test integration_test/icon_strokes_test.dart -d DEVICE`
/// Once [IconStrokes.useLight] ran, the font loaded then takes the place of
/// the one bundled with Lucide: lighter lines, and Hi-icons where they fit.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// How much ink [icon] takes, drawn 200 px tall from [family].
  Future<int> ink(IconData icon, {String? family}) async {
    final recorder = ui.PictureRecorder();
    TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: family ?? icon.fontFamily,
          package: icon.fontPackage,
          fontSize: 200,
          color: Colors.black,
        ),
      ),
      textDirection: TextDirection.ltr,
    )
      ..layout()
      ..paint(Canvas(recorder), Offset.zero);
    final image = await recorder.endRecording().toImage(220, 220);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var total = 0;
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      total += bytes.getUint8(i);
    }
    return total;
  }

  testWidgets('icons are drawn with the light weight, or from Hi-icons', (tester) async {
    // Folders, files and what the pack doesn't have: Lucide's light weight.
    const icons = [LucideIcons.folder, LucideIcons.fileText, LucideIcons.copy];
    final regular = [for (final icon in icons) await ink(icon)];
    final light = [for (final icon in icons) await ink(icon, family: 'Lucide300')];
    const redrawn = [LucideIcons.settings, LucideIcons.x, LucideIcons.search];
    final before = [for (final icon in redrawn) await ink(icon, family: 'Lucide300')];
    await IconStrokes.useLight();
    for (final (i, icon) in redrawn.indexed) {
      final now = await ink(icon);
      expect(now, greaterThan(0), reason: '${icon.codePoint}: a blank glyph');
      expect((now - before[i]).abs(), greaterThan(before[i] * 0.01), reason: '${icon.codePoint}: still Lucide');
    }
    for (final (i, icon) in icons.indexed) {
      expect(light[i], lessThan(regular[i] * 0.9), reason: 'the light weight has thinner lines');
      expect(await ink(icon), closeTo(light[i], light[i] * 0.02), reason: '${icon.codePoint}: the light weight is used');
    }
  });
}
