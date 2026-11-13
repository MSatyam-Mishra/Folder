import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/new_files.dart';
import 'package:folders/features/document_scanner/document_scanner.dart';
import 'package:folders/features/document_scanner/scan_document.dart';
import 'package:folders/features/file_explorere/widgets/new_file_button.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

void main() {
  final time = DateTime(2026, 11, 13, 14, 5, 59);
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('document_scanner_test');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    DocumentScanner.debugSupported = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DocumentScanner.channel, null);
    dir.deleteSync(recursive: true);
  });

  /// What the native side leaves in the cache: a folder with the scan.
  ScanResult fakeScan({int pages = 2}) {
    final cache = Directory(p.join(dir.path, 'cache', 'scans', '1'))..createSync(recursive: true);
    final pdf = File(p.join(cache.path, 'scan.pdf'))..writeAsStringSync('%PDF-1.7');
    return ScanResult(pdf: pdf.path, pages: [
      for (var i = 1; i <= pages; i++) (File(p.join(cache.path, 'page-$i.jpg'))..writeAsBytesSync([0xFF, 0xD8, i])).path,
    ]);
  }

  test('names like "Scan 2026-11-13 14.05", never over a file', () {
    expect(DocumentScanner.baseName(time), 'Scan 2026-11-13 14.05');
    final out = Directory(p.join(dir.path, 'out'))..createSync();
    final scan = fakeScan(pages: 3);
    expect(DocumentScanner.namesFor(scan, ScanFormat.pdf, out.path, time), ['Scan 2026-11-13 14.05.pdf']);
    expect(DocumentScanner.namesFor(scan, ScanFormat.jpeg, out.path, time), [
      'Scan 2026-11-13 14.05 1.jpg',
      'Scan 2026-11-13 14.05 2.jpg',
      'Scan 2026-11-13 14.05 3.jpg',
    ]);
    expect(DocumentScanner.namesFor(const ScanResult(pages: ['x']), ScanFormat.jpeg, out.path, time), ['Scan 2026-11-13 14.05.jpg']);

    File(p.join(out.path, 'Scan 2026-11-13 14.05.pdf')).writeAsStringSync('');
    File(p.join(out.path, 'Scan 2026-11-13 14.05 (2).pdf')).writeAsStringSync('');
    expect(DocumentScanner.namesFor(scan, ScanFormat.pdf, out.path, time), ['Scan 2026-11-13 14.05 (3).pdf']);
    File(p.join(out.path, 'Scan 2026-11-13 14.05 2.jpg')).writeAsStringSync('');
    expect(DocumentScanner.namesFor(scan, ScanFormat.jpeg, out.path, time).first, 'Scan 2026-11-13 14.05 (2) 1.jpg');
  });

  test('saves the PDF or the pages, then clears the cache', () async {
    final out = Directory(p.join(dir.path, 'out'))..createSync();
    var scan = fakeScan();
    final pdf = await DocumentScanner.save(scan, ScanFormat.pdf, out.path, time: time);
    expect(pdf.map(p.basename), ['Scan 2026-11-13 14.05.pdf']);
    expect(File(pdf.single).readAsStringSync(), '%PDF-1.7');
    expect(File(scan.pdf!).parent.existsSync(), isFalse, reason: "the scanner's copies go");

    scan = fakeScan();
    final pages = await DocumentScanner.save(scan, ScanFormat.jpeg, out.path, time: time);
    expect(pages.map(p.basename), ['Scan 2026-11-13 14.05 1.jpg', 'Scan 2026-11-13 14.05 2.jpg']);
    expect(File(pages[1]).readAsBytesSync(), [0xFF, 0xD8, 2]);

    await expectLater(DocumentScanner.save(const ScanResult(), ScanFormat.pdf, out.path), throwsA(isA<ScanUnavailable>()));
  });

  test('asks the scanner for the chosen format, and explains failures', () async {
    final asked = <Object?>[];
    var fail = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(DocumentScanner.channel, (call) async {
      asked.add(call.arguments);
      if (fail) throw PlatformException(code: 'unavailable', message: 'Waiting for the module');
      return {'pdf': '/cache/scan.pdf', 'pages': ['/cache/page-1.jpg']};
    });
    final scan = await DocumentScanner.scan(ScanFormat.jpeg);
    expect(asked.single, {'pdf': false, 'jpeg': true});
    expect(scan!.pdf, '/cache/scan.pdf');
    expect(scan.pages, ['/cache/page-1.jpg']);
    fail = true;
    await expectLater(
      DocumentScanner.scan(ScanFormat.pdf),
      throwsA(isA<ScanUnavailable>().having((e) => e.message, 'message', contains('Google Play services'))),
    );
  });

  testWidgets('Scan document is in the new-item sheet where there is a scanner', (tester) async {
    DocumentScanner.debugSupported = true;
    var scanned = 0;
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => Column(
          children: [
            TextButton(
              onPressed: () => showNewItemSheet(context, onNewFile: (NewFileKind _) {}, onScanDocument: () => scanned++),
              child: const Text('with'),
            ),
            TextButton(onPressed: () => showNewItemSheet(context, onNewFile: (NewFileKind _) {}), child: const Text('without')),
          ],
        ),
      ),
    )));
    await tester.tap(find.text('with'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan document'));
    await tester.pumpAndSettle();
    expect(scanned, 1);

    await tester.tap(find.text('without'));
    await tester.pumpAndSettle();
    expect(find.text('Scan document'), findsNothing);
  });

  testWidgets('the format sheet offers PDF and pictures', (tester) async {
    ScanFormat? chosen;
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(onPressed: () async => chosen = await chooseScanFormat(context), child: const Text('go')),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Save as PDF'), findsOneWidget);
    await tester.tap(find.text('Save as pictures'));
    await tester.pumpAndSettle();
    expect(chosen, ScanFormat.jpeg);
  });

  test('the tool is on Android only', () {
    expect(Tool.availableIn(videoDownloader: true, android: true), contains(Tool.documentScanner));
    expect(Tool.availableIn(videoDownloader: true), isNot(contains(Tool.documentScanner)));
    expect(Tool.fromRoute('tool/document_scanner', android: true), Tool.documentScanner);
    expect(Tool.fromRoute('tool/document_scanner', android: false), isNull);
    expect(Tool.documentScanner.shortcut.route, 'tool/document_scanner');
  });
}
