import 'dart:io';

import 'package:folder/core/services/image_text.dart';
import 'package:folder/features/viewer_image/widgets/image_text_layer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screenshots.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  testWidgets('text in an image, selected', (tester) async {
    final file = File('test/fixtures/ocr_invoice.png');
    final text = await tester.runAsync(() => ImageTextReader.read(file));
    expect(text, isNotNull);
    setScreenSize(tester, const Size(900, 360), pixelRatio: 1);
    final bytes = await tester.runAsync(() => file.readAsBytes());
    await tester.pumpWidget(screenshotFrame(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            Image.memory(bytes!, fit: BoxFit.fill),
            ImageTextLayer(text: text!, active: true),
          ],
        ),
      ),
    )));
    await tester.runAsync(() => precacheImage(MemoryImage(bytes), tester.element(find.byType(Image))));
    await tester.pump();
    await tester.tap(find.text('Total due: 1,250.00 EUR'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await saveScreenshot(tester, 'image_text_selected');
  }, skip: !screenshotsEnabled || !Platform.isWindows);
}
