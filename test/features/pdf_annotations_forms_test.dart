import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:folders/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:folders/features/viewer_pdf/services/pdf_annotation_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdf_document_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdf_form_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdfium_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

/// Builds a PDF from numbered object bodies, with a correct xref table.
Uint8List buildPdf(List<String> objects) {
  final out = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(latin1.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = latin1.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<</Size ${objects.length + 1}/Root 1 0 R>>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return latin1.encode(out.toString());
}

Uint8List formPdf() {
  const box = '0 0 1 rg 2 2 8 8 re f';
  return buildPdf([
    '<</Type/Catalog/Pages 2 0 R/AcroForm<</Fields[4 0 R 5 0 R 6 0 R]/DA(/Helv 0 Tf 0 g)'
        '/DR<</Font<</Helv 7 0 R>>>>>>>>',
    '<</Type/Pages/Kids[3 0 R]/Count 1>>',
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 400 400]/Annots[4 0 R 5 0 R 6 0 R]'
        '/Resources<</Font<</Helv 7 0 R>>>>>>',
    '<</Type/Annot/Subtype/Widget/FT/Tx/T(name)/V(Ada)/Rect[50 300 250 330]'
        '/DA(/Helv 12 Tf 0 g)/F 4/P 3 0 R>>',
    '<</Type/Annot/Subtype/Widget/FT/Btn/T(agree)/V/Off/AS/Off/Rect[50 250 70 270]/F 4/P 3 0 R'
        '/MK<</CA(4)>>/AP<</N<</Yes 8 0 R/Off 9 0 R>>>>>>',
    '<</Type/Annot/Subtype/Widget/FT/Ch/Ff 131072/T(size)/Opt[(Small)(Medium)(Large)]'
        '/V(Small)/Rect[50 200 250 230]/DA(/Helv 12 Tf 0 g)/F 4/P 3 0 R>>',
    '<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>',
    '<</Type/XObject/Subtype/Form/BBox[0 0 20 20]/Length ${box.length}>>\nstream\n$box\nendstream',
    '<</Type/XObject/Subtype/Form/BBox[0 0 20 20]/Length 0>>\nstream\n\nendstream',
  ]);
}

Uint8List _blankPdf(int _) {
  final doc = NativeDocument.create();
  try {
    pdfium.FPDF_ClosePage(pdfium.FPDFPage_New(doc.handle, 0, 400, 400));
    return doc.save();
  } finally {
    doc.close();
  }
}

/// Average colour of [rect] (pdfrx page coordinates) on page 1.
Future<Color> averageColor(Uint8List pdf, PdfRect rect) async {
  final doc = await PdfDocument.openData(pdf);
  try {
    final page = doc.pages.first;
    final image = (await page.render(
      width: page.width.round(),
      height: page.height.round(),
      fullWidth: page.width,
      fullHeight: page.height,
      backgroundColor: 0xFFFFFFFF,
    ))!;
    final r = rect.toRect(page: page);
    var sr = 0, sg = 0, sb = 0, n = 0;
    for (var y = r.top.ceil(); y < r.bottom.floor(); y++) {
      for (var x = r.left.ceil(); x < r.right.floor(); x++) {
        final i = (y * image.width + x) * 4;
        sb += image.pixels[i];
        sg += image.pixels[i + 1];
        sr += image.pixels[i + 2];
        n++;
      }
    }
    image.dispose();
    return Color.fromARGB(255, sr ~/ n, sg ~/ n, sb ~/ n);
  } finally {
    await doc.dispose();
  }
}

void main() {
  setUpAll(() => pdfrxInitialize());

  test(
    'adds, finds, recolours and removes markup and notes in place',
    () async {
      var pdf = await onPdfiumWorker(_blankPdf, 0);
      pdf = await PdfDocumentOps.drawOnPage(pdf, 0, const [
        TextMark(
          position: Offset(40, 40),
          text: 'Highlight me please',
          fontSize: 20,
          color: Color(0xFF000000),
        ),
      ]);

      final doc = await PdfDocument.openData(pdf);
      final text = await doc.pages.first.loadStructuredText();
      final start = text.fullText.indexOf('Highlight');
      final range = PdfPageTextRange(
        pageText: text,
        start: start,
        end: start + 9,
      );
      final line = range.bounds;

      await PdfAnnotationOps.addMarkup(doc, 0, PdfMarkupKind.highlight, [
        line,
      ], const Color(0xFFFFEB3B));
      final center = PdfPoint(
        (line.left + line.right) / 2,
        (line.top + line.bottom) / 2,
      );
      final hit = await PdfAnnotationOps.hitTest(doc, 0, center);
      expect(hit, isNotNull);
      expect(hit!.subtype, PdfMarkupKind.highlight.subtype);
      expect(hit.color.r, 1.0);

      var saved = await doc.encodePdf();
      var color = await averageColor(saved, line);
      expect(
        color.b < color.r * 0.8,
        isTrue,
        reason: 'yellow highlight: $color',
      );

      await PdfAnnotationOps.setColor(doc, hit, const Color(0xFF00BFFF));
      saved = await doc.encodePdf();
      color = await averageColor(saved, line);
      expect(color.b > color.r, isTrue, reason: 'recoloured to blue: $color');

      await PdfAnnotationOps.addNote(
        doc,
        0,
        const PdfPoint(300, 380),
        'Check this',
        const Color(0xFFFFEB3B),
      );
      final note = await PdfAnnotationOps.hitTest(
        doc,
        0,
        const PdfPoint(305, 375),
      );
      expect(note?.isNote, isTrue);
      expect(note?.contents, 'Check this');
      await PdfAnnotationOps.setContents(doc, note!, 'Checked ✓');
      expect(
        (await PdfAnnotationOps.hitTest(
          doc,
          0,
          const PdfPoint(305, 375),
        ))?.contents,
        'Checked ✓',
      );

      await PdfAnnotationOps.remove(
        doc,
        (await PdfAnnotationOps.hitTest(doc, 0, center))!,
      );
      expect(await PdfAnnotationOps.hitTest(doc, 0, center), isNull);
      await doc.dispose();
    },
  );

  test('reads and fills text fields, checkboxes and combo boxes', () async {
    var pdf = formPdf();
    var fields = await PdfFormOps.fields(pdf);
    expect(
      [for (final f in fields) f.type],
      [
        PdfFormFieldType.text,
        PdfFormFieldType.checkbox,
        PdfFormFieldType.combo,
      ],
    );
    final name = fields[0];
    expect((name.name, name.value), ('name', 'Ada'));
    expect(name.bounds.left, 50);
    expect(fields[1].checked, isFalse);
    expect(fields[2].options, ['Small', 'Medium', 'Large']);

    pdf = await PdfFormOps.setText(pdf, name, 'Grace Hopper');
    pdf = await PdfFormOps.toggle(pdf, fields[1]);
    pdf = await PdfFormOps.select(pdf, fields[2], 2);

    fields = await PdfFormOps.fields(pdf);
    expect(fields[0].value, 'Grace Hopper');
    expect(fields[1].checked, isTrue);
    expect(fields[2].value, 'Large');

    // The appearance is updated too, so other apps show the new value.
    final doc = await PdfDocument.openData(pdf);
    final text = await doc.pages.first.loadText();
    await doc.dispose();
    expect(text?.fullText ?? '', isNot(contains('Ada')));
  });
}
