import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/features/document_scanner/document_scanner.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On an Android device with Google Play services:
/// `flutter test integration_test/document_scanner_test.dart -d DEVICE`.
/// It opens Google's scanner twice, first for a PDF, then for pictures: scan
/// a page each time (or import one from the gallery) and tap Save. A `SCAN:`
/// line says what came back and where it was saved.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Google scanner gives a PDF and pictures, saved under our names', (tester) async {
    await tester.runAsync(() async {
      expect(await DocumentScanner.available(), isTrue, reason: 'Play services');
      final folder = Directory('${(await getExternalStorageDirectory())!.path}/scans');
      if (folder.existsSync()) folder.deleteSync(recursive: true);
      folder.createSync(recursive: true);

      for (final format in ScanFormat.values) {
        debugPrint('SCAN: opening the scanner for ${format.name}');
        final scan = await DocumentScanner.scan(format);
        expect(scan, isNotNull, reason: 'a page scanned and saved');
        debugPrint('SCAN: ${format.name}: pdf ${scan!.pdf}, ${scan.pageCount} pages');
        final saved = await DocumentScanner.save(scan, format, folder.path);
        for (final path in saved) {
          final head = File(path).openSync().readSync(4);
          debugPrint('SCAN: saved $path (${File(path).lengthSync()} bytes)');
          if (format == ScanFormat.pdf) {
            expect(String.fromCharCodes(head), '%PDF');
          } else {
            expect(head.sublist(0, 2), [0xFF, 0xD8], reason: 'a JPEG');
          }
        }
        expect(saved.first.split('/').last, startsWith('Scan '));
      }
    });
  });
}
