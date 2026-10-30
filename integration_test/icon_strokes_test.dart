import 'dart:ui' as ui;

import 'package:explorer/core/theme/icon_strokes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// On a device: `flutter test integration_test/icon_strokes_test.dart -d DEVICE`
/// The app's icons get lighter lines once [IconStrokes.useLight] ran: the
/// font loaded then takes the place of the one bundled with Lucide.
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

  testWidgets('icons are drawn with the light weight', (tester) async {
    const icons = [LucideIcons.folder, LucideIcons.settings, LucideIcons.download];
    final regular = [for (final icon in icons) await ink(icon)];
    final light = [for (final icon in icons) await ink(icon, family: 'Lucide300')];
    await IconStrokes.useLight();
    for (final (i, icon) in icons.indexed) {
      expect(light[i], lessThan(regular[i] * 0.9), reason: 'the light weight has thinner lines');
      expect(await ink(icon), closeTo(light[i], light[i] * 0.02), reason: '${icon.codePoint}: the light weight is used');
    }
  });
}
