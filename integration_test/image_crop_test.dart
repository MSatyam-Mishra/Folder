import 'dart:io';

import 'package:folders/features/viewer_image/screens/image_editor_screen.dart';
import 'package:folders/features/viewer_image/widgets/crop_frame.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/screenshots.dart';
import '../test/support/themed_app.dart';

/// On a computer: `flutter test integration_test/image_crop_test.dart -d windows`
/// Takes the crop frame's edges and corners with a mouse and saves: the file
/// comes out that size and shows the right part of the picture.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('crop by edges and a corner, and save', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('explorer_crop')))!;
    addTearDown(() => root.delete(recursive: true));
    // Red on the left half, blue on the right: what's kept can be told apart.
    final file = (await tester.runAsync(() async {
      final picture = img.Image(width: 800, height: 400);
      img.fillRect(picture, x1: 0, y1: 0, x2: 399, y2: 399, color: img.ColorRgb8(220, 30, 30));
      img.fillRect(picture, x1: 400, y1: 0, x2: 799, y2: 399, color: img.ColorRgb8(30, 30, 220));
      return File(p.join(root.path, 'Photo.png')).writeAsBytes(img.encodePng(picture));
    }))!;

    Future<void> rounds(int count) async {
      for (var i = 0; i < count; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    await tester.pumpWidget(screenshotFrame(themedApp(Builder(
      builder: (context) => ElevatedButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<String>(builder: (_) => ImageEditorScreen(file: file)),
        ),
        child: const Text('Edit'),
      ),
    ))));
    await tester.tap(find.text('Edit'));
    for (var i = 0; i < 100 && find.byType(CropFrame).evaluate().isEmpty; i++) {
      await rounds(1);
    }
    await rounds(10);
    await saveScreenshot(tester, 'crop_start');

    final origin = tester.getTopLeft(find.byType(CropFrame));
    final image = tester.widget<CropFrame>(find.byType(CropFrame)).imageRect.shift(origin);
    Future<void> drag(Offset from, Offset by) async {
      final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await tester.pump();
      await mouse.moveBy(by / 2);
      await tester.pump();
      await mouse.moveBy(by / 2);
      await tester.pump();
      await mouse.up();
      await rounds(2);
    }

    // The right edge to the middle: only the red half is left.
    await drag(image.centerRight, Offset(-image.width / 2, 0));
    // The bottom edge up by a quarter.
    await drag(image.bottomCenter - Offset(image.width / 4, 0), Offset(0, -image.height / 4));
    // The top left corner in, from just outside the image.
    await drag(image.topLeft - const Offset(6, 6), Offset(image.width / 8, 0));
    await saveScreenshot(tester, 'crop_dragged');

    final rect = tester.widget<CropFrame>(find.byType(CropFrame)).rect;
    expect(rect.right, closeTo(0.5, 0.02));
    expect(rect.bottom, closeTo(0.75, 0.02));
    expect(rect.left, closeTo(0.125, 0.02));
    expect(rect.top, closeTo(0, 0.02));

    await tester.tap(find.byTooltip('Save'));
    await rounds(10);
    await tester.tap(find.text('Save as copy'));
    final copy = File(p.join(root.path, 'Photo_edited.png'));
    for (var i = 0; i < 200 && !await tester.runAsync(copy.exists).then((e) => e ?? false); i++) {
      await rounds(1);
    }
    await rounds(10);
    final saved = (await tester.runAsync(() async => img.decodePng(await copy.readAsBytes())))!;
    expect(saved.width, closeTo(300, 12), reason: 'from an eighth to a half of 800');
    expect(saved.height, closeTo(300, 12), reason: 'three quarters of 400');
    final pixel = saved.getPixel(saved.width - 2, saved.height ~/ 2);
    expect(pixel.r, greaterThan(150), reason: "red: it's the left half that's kept");
    expect(pixel.b, lessThan(100));
    expect(find.byType(ImageEditorScreen), findsNothing, reason: 'closes after saving');
    await tester.pumpWidget(const SizedBox());
  });
}
