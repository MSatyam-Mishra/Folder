import 'dart:io';
import 'dart:ui' as ui;

import 'package:folders/core/services/image_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On a device: `flutter test integration_test/image_text_test.dart -d DEVICE`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A 900×360 picture with three lines of text.
  Future<File> invoice() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawColor(Colors.white, BlendMode.src);
    var y = 40.0;
    for (final (line, size) in [('Invoice 2041', 48.0), ('Total due: 1,250.00 EUR', 38.0), ('Pay before 31 October', 38.0)]) {
      TextPainter(
        text: TextSpan(text: line, style: TextStyle(color: Colors.black, fontSize: size)),
        textDirection: TextDirection.ltr,
      )
        ..layout()
        ..paint(canvas, Offset(50, y));
      y += 100;
    }
    final image = await recorder.endRecording().toImage(900, 360);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${(await getTemporaryDirectory()).path}/ocr_invoice.png');
    return file.writeAsBytes(png!.buffer.asUint8List(), flush: true);
  }

  testWidgets('finds the text in an image on the device', (tester) async {
    final file = await invoice();
    // The first use may wait for Play services to fetch the model.
    ImageText? text;
    for (var i = 0; i < 30 && text == null; i++) {
      text = await ImageTextReader.read(file);
      if (text == null) await Future<void>.delayed(const Duration(seconds: 3));
    }
    expect(text, isNotNull);
    expect(text!.size, const Size(900, 360));
    expect(text.text, contains('Invoice 2041'));
    expect(text.text, contains('1,250.00'));
    expect(text.lines.first.box.left, closeTo(50, 20));
    expect(text.lines.first.box.top, closeTo(45, 25));
  });
}
