import 'dart:typed_data';
import 'dart:ui';

import 'package:folder/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:folder/features/viewer_pdf/services/pdf_document_ops.dart';
import 'package:folder/features/viewer_pdf/services/pdfium_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// A PDF whose pages have the given widths (height 400).
Uint8List _makePdf(List<double> widths) {
  final doc = NativeDocument.create();
  try {
    for (var i = 0; i < widths.length; i++) {
      final page = pdfium.FPDFPage_New(doc.handle, i, widths[i], 400);
      pdfium.FPDF_ClosePage(page);
    }
    return doc.save();
  } finally {
    doc.close();
  }
}

Future<Uint8List> makePdf(List<double> widths) =>
    onPdfiumWorker(_makePdf, widths);

Future<List<double>> widths(Uint8List pdf) async => [
  for (final m in await PdfDocumentOps.pageMetas(pdf)) m.width,
];

Future<String> pageText(Uint8List pdf, int page, {String? password}) async {
  final doc = await PdfDocument.openData(
    pdf,
    passwordProvider: password == null ? null : () => password,
  );
  try {
    final text = await doc.pages[page].loadText();
    return text?.fullText ?? '';
  } finally {
    await doc.dispose();
  }
}

/// RGBA of the pixel at [display] (points, rotation applied) on [page],
/// rendered at 1 px per point.
Future<Color> pixelAt(Uint8List pdf, int page, Offset display) async {
  final doc = await PdfDocument.openData(pdf);
  try {
    final p = doc.pages[page];
    final image = (await p.render(
      width: p.width.round(),
      height: p.height.round(),
      fullWidth: p.width,
      fullHeight: p.height,
      backgroundColor: 0xFFFFFFFF,
    ))!;
    final i = (display.dy.round() * image.width + display.dx.round()) * 4;
    final px = image.pixels;
    final color = Color.fromARGB(px[i + 3], px[i + 2], px[i + 1], px[i]);
    image.dispose();
    return color;
  } finally {
    await doc.dispose();
  }
}

void main() {
  setUpAll(() => pdfrxInitialize());

  test(
    'probes, and unlocks encrypted files only with their password',
    () async {
      final pdf = await makePdf([300, 300]);
      expect((await PdfDocumentOps.probe(pdf)).pageCount, 2);
      expect(
        (await PdfDocumentOps.probe(Uint8List.fromList([1, 2, 3]))).status,
        PdfOpenStatus.invalid,
      );

      final withText = await PdfDocumentOps.drawOnPage(pdf, 0, const [
        TextMark(
          position: Offset(20, 20),
          text: 'Secret plan',
          fontSize: 18,
          color: Color(0xFF000000),
        ),
      ]);
      final locked = await PdfDocumentOps.encrypt(withText, 'pässwörd');
      expect(
        (await PdfDocumentOps.probe(locked)).status,
        PdfOpenStatus.needsPassword,
      );
      expect(
        (await PdfDocumentOps.probe(locked, password: 'wrong')).status,
        PdfOpenStatus.needsPassword,
      );
      expect(
        (await PdfDocumentOps.probe(locked, password: 'pässwörd')).status,
        PdfOpenStatus.ok,
      );
      expect(
        await pageText(locked, 0, password: 'pässwörd'),
        contains('Secret plan'),
      );

      final unlocked = await PdfDocumentOps.decrypt(locked, 'pässwörd');
      expect((await PdfDocumentOps.probe(unlocked)).status, PdfOpenStatus.ok);
      expect(await pageText(unlocked, 0), contains('Secret plan'));
    },
  );

  test('rotates, deletes, inserts and extracts pages', () async {
    final pdf = await makePdf([100, 200, 300]);
    final rotated = await PdfDocumentOps.rotatePages(pdf, {1}, 1);
    final metas = await PdfDocumentOps.pageMetas(rotated);
    expect([for (final m in metas) m.rotation], [0, 90, 0]);
    expect(metas[1].displaySize, const Size(400, 200));

    expect(await widths(await PdfDocumentOps.deletePages(pdf, {0, 2})), [200]);
    expect(() => PdfDocumentOps.deletePages(pdf, {0, 1, 2}), throwsA(anything));
    expect(await widths(await PdfDocumentOps.insertBlankPage(pdf, 1)), [
      100,
      200,
      200,
      300,
    ]);
    expect(await widths(await PdfDocumentOps.extractPages(pdf, {2, 0})), [
      100,
      300,
    ]);

    final other = await makePdf([50, 60]);
    expect(await widths(await PdfDocumentOps.insertPdf(pdf, other, index: 1)), [
      100,
      50,
      60,
      200,
      300,
    ]);
    expect(await widths(await PdfDocumentOps.insertPdf(pdf, other)), [
      100,
      200,
      300,
      50,
      60,
    ]);
  });

  test('applies a page plan: reorder, rotate, drop and add blanks', () async {
    final pdf = await makePdf([100, 200, 300]);
    final out = await PdfDocumentOps.applyPagePlan(pdf, const [
      PagePlanEntry.source(2),
      PagePlanEntry.blank(Size(123, 456)),
      PagePlanEntry.source(0, quarterTurns: 3),
    ]);
    final metas = await PdfDocumentOps.pageMetas(out);
    expect([for (final m in metas) m.width], [300, 123, 100]);
    expect([for (final m in metas) m.rotation], [0, 0, 270]);
    expect(metas[1].height, 456);
  });

  test(
    'draws ink, text and images where they were placed, on rotated pages too',
    () async {
      for (final turns in [0, 1, 2, 3]) {
        var pdf = await makePdf([300]);
        if (turns > 0) pdf = await PdfDocumentOps.rotatePages(pdf, {0}, turns);
        final size = (await PdfDocumentOps.pageMetas(pdf)).single.displaySize;

        final png = img.encodePng(
          img.Image(width: 20, height: 20, numChannels: 4)
            ..clear(img.ColorRgba8(0, 0, 255, 255)),
        );
        pdf = await PdfDocumentOps.drawOnPage(pdf, 0, [
          // A red stroke near the top-left corner as displayed.
          const InkMark(
            points: [Offset(10, 20), Offset(60, 20)],
            color: Color(0xFFFF0000),
            width: 8,
          ),
          ImageMark(
            rect: Rect.fromLTWH(size.width - 50, size.height - 50, 40, 40),
            bytes: png,
          ),
          const TextMark(
            position: Offset(20, 60),
            text: 'Über café ×',
            fontSize: 14,
            color: Color(0xFF000000),
          ),
        ]);

        final ink = await pixelAt(pdf, 0, const Offset(35, 20));
        expect(
          (ink.r, ink.g < 0.2, ink.b < 0.2),
          (1.0, true, true),
          reason: 'ink, $turns turns',
        );
        final blue = await pixelAt(
          pdf,
          0,
          Offset(size.width - 30, size.height - 30),
        );
        expect(
          blue.b > 0.9 && blue.r < 0.1,
          isTrue,
          reason: 'image, $turns turns: $blue',
        );
        final blank = await pixelAt(pdf, 0, Offset(size.width - 30, 20));
        expect(
          blank.r > 0.9 && blank.g > 0.9 && blank.b > 0.9,
          isTrue,
          reason: 'blank, $turns turns',
        );
        expect(
          await pageText(pdf, 0),
          contains('Über café'),
          reason: 'text, $turns turns',
        );
      }
    },
  );

  test('embeds a system font once for non-Western text', () async {
    final pdf = await makePdf([300]);
    if (!PdfDocumentOps.canEmbedText('Привет')) return; // No system font.
    final out = await PdfDocumentOps.drawOnPage(pdf, 0, const [
      TextMark(position: Offset(20, 20), text: 'Привет, мир', fontSize: 14, color: Color(0xFF000000)),
      TextMark(position: Offset(20, 60), text: 'Ελληνικά', fontSize: 14, color: Color(0xFF000000)),
      TextMark(position: Offset(20, 100), text: '“Quotes” – fine • ok', fontSize: 14, color: Color(0xFF000000)),
    ]);
    final text = await pageText(out, 0);
    expect(text, contains('Привет'));
    expect(text, contains('Ελληνικά'));
    expect(text, contains('“Quotes” – fine'));
    // One copy of the font, not one per text box.
    final fontSize = 2 * 1024 * 1024;
    expect(out.length, lessThan(fontSize));
  });
}
