import 'dart:io';

import 'package:folders/core/services/image_text.dart';
import 'package:folders/features/viewer_image/widgets/image_text_layer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads Windows OCR output, also single lines and words', () {
    final text = ImageText.fromWindowsJson(
      '{"w":900,"h":360,"lines":{"t":"Invoice","words":{"t":"Invoice","x":52,"y":56,"w":148,"h":36}}}',
    )!;
    expect(text.size, const Size(900, 360));
    expect(text.text, 'Invoice');
    expect(text.lines.single.box, const Rect.fromLTWH(52, 56, 148, 36));
    expect(ImageText.fromWindowsJson('{"error":"no-language"}'), isNull);
  });

  test('reads Tesseract TSV', () {
    const tsv = 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n'
        '1\t1\t0\t0\t0\t0\t0\t0\t900\t360\t-1\t\n'
        '5\t1\t1\t1\t1\t1\t52\t56\t148\t36\t96\tInvoice\n'
        '5\t1\t1\t1\t1\t2\t218\t58\t95\t34\t96\t2041\n'
        '5\t1\t1\t1\t2\t1\t47\t162\t81\t28\t95\tTotal\n';
    final text = ImageText.fromTesseractTsv(tsv)!;
    expect(text.size, const Size(900, 360));
    expect(text.text, 'Invoice 2041\nTotal');
  });

  test('finds the text in an image with Windows OCR', () async {
    final text = await ImageTextReader.read(File('test/fixtures/ocr_invoice.png'));
    expect(text, isNotNull);
    expect(text!.text, contains('Invoice 2041'));
    expect(text.text, contains('1,250.00'));
    final invoice = text.lines.first;
    expect(invoice.box.left, closeTo(52, 20));
    expect(invoice.box.top, closeTo(56, 20));
  }, skip: !Platform.isWindows);

  testWidgets('the text on the image is selectable and copies line by line', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    final text = ImageText.fromWindowsJson(
      '{"w":900,"h":360,"lines":['
      '{"t":"Invoice 2041","words":[{"t":"Invoice","x":52,"y":56,"w":148,"h":36},{"t":"2041","x":218,"y":58,"w":95,"h":34}]},'
      '{"t":"Total due","words":[{"t":"Total","x":47,"y":162,"w":81,"h":28},{"t":"due","x":143,"y":162,"w":69,"h":28}]}]}',
    )!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 450, height: 180, child: ImageTextLayer(text: text, active: true)),
        ),
      ),
    ));
    // Lines sit where they were read, scaled to the space (half size here).
    final invoice = tester.getRect(find.text('Invoice 2041'));
    final layer = tester.getRect(find.byType(ImageTextLayer));
    expect(invoice.left - layer.left, closeTo(26, 1));
    expect(invoice.top - layer.top, closeTo(28, 1));

    final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    // A click on the text gives the selection the keyboard.
    await tester.tap(find.text('Total due'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 500));
    region.selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied, 'Invoice 2041\nTotal due');
  });
}
