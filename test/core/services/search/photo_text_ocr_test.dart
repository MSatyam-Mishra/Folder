import 'dart:io';

import 'package:folders/core/services/image_text.dart';
import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The photo text index with the system's real text recognition: Windows
/// OCR through Windows PowerShell. Opt-in, as it takes a few seconds:
/// EXPLORER_REAL_OCR=1 flutter test test/core/services/search/photo_text_ocr_test.dart
void main() {
  final wanted = Platform.environment['EXPLORER_REAL_OCR'] == '1' && Platform.isWindows;

  test('reads the words in a picture once, and keeps them', () async {
    final root = await Directory.systemTemp.createTemp('photo_ocr_test');
    addTearDown(() => root.delete(recursive: true));
    final picture = img.Image(width: 900, height: 200);
    img.fill(picture, color: img.ColorRgb8(255, 255, 255));
    img.drawString(picture, 'GROCERY RECEIPT', font: img.arial48, x: 30, y: 30, color: img.ColorRgb8(0, 0, 0));
    img.drawString(picture, 'TOTAL 12.40', font: img.arial48, x: 30, y: 110, color: img.ColorRgb8(0, 0, 0));
    final path = p.join(root.path, 'receipt.png');
    await File(path).writeAsBytes(img.encodePng(picture));

    var reads = 0;
    final index = PhotoTextIndex(
      folder: () async => p.join(root.path, 'index'),
      ocr: (path) async {
        reads++;
        return (await ImageTextReader.read(File(path)))?.text;
      },
    );
    final stat = await File(path).stat();
    final text = await index.read(path, stat.size, stat.modified.millisecondsSinceEpoch);
    expect(text.toUpperCase(), contains('RECEIPT'));
    expect(text.toUpperCase(), contains('TOTAL'));
    await index.read(path, stat.size, stat.modified.millisecondsSinceEpoch);
    expect(reads, 1);
  }, skip: wanted ? false : 'Set EXPLORER_REAL_OCR=1 on Windows to try the real OCR');
}
