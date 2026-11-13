import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/search/pdf_text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

/// A one-page PDF with [text] in Helvetica, written by hand with a correct
/// cross-reference table.
List<int> tinyPdf(String text) {
  final stream = 'BT /F1 18 Tf 20 100 Td ($text) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(out.toString());
}

void main() {
  late Directory root;

  setUpAll(() async {
    await pdfrxInitialize();
    PdfText.initialize = pdfrxInitialize;
  });

  setUp(() async => root = await Directory.systemTemp.createTemp('search_pdf_test'));
  tearDown(() => root.delete(recursive: true));

  test("reads a PDF's text through PDFium", () async {
    final path = p.join(root.path, 'invoice.pdf');
    await File(path).writeAsBytes(tinyPdf('Invoice for March receipts'));
    final text = await PdfText.read(path);
    expect(text, contains('Invoice for March receipts'));
  });

  test("a damaged PDF reads as nothing", () async {
    final path = p.join(root.path, 'broken.pdf');
    await File(path).writeAsString('%PDF-1.4 not really');
    expect(await PdfText.read(path), isNull);
  });
}
