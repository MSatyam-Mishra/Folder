import 'dart:io';

import 'package:folder/features/viewer_sheets/model/workbook.dart';
import 'package:folder/features/viewer_sheets/screens/spreadsheet_screen.dart';
import 'package:folder/features/viewer_sheets/widgets/color_palette.dart';
import 'package:folder/features/viewer_sheets/widgets/find_bar.dart';
import 'package:folder/features/viewer_sheets/widgets/sheet_grid.dart';
import 'package:folder/features/viewer_sheets/writers/xlsx_writer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'doc_viewer_harness.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/sheet_viewer_screens_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? dir;
  File? xlsx;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    await loadDocumentFontAliases();
    dir = await sampleDir('sheets');
    xlsx = File(p.join(dir!.path, 'Budget 2026.xlsx'));
    await xlsx!.writeAsBytes(
      XlsxWriter.writePackage(_sampleWorkbook(), target: SpreadsheetFormat.xlsx).bytes,
    );
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await dir?.delete(recursive: true);
  });

  for (final (mode, device, size) in shotVariants) {
    final tag = '${mode.name}_$device';
    final phone = device == 'phone';

    testWidgets('sheets $tag', (tester) async {
      await pumpViewer(tester, SpreadsheetScreen(file: xlsx!), mode: mode, size: size);
      await settleUntil(tester, find.byType(SheetGrid));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'sheets_read_$tag');

      // Select B3:C6 (shows selection stats).
      final grid = tester.getTopLeft(find.byType(SheetGrid));
      Offset cell(int row, int col) => grid +
          Offset(
            40 + (col == 0 ? 70 : 140 + (col - 1) * 96 + 48),
            24 + row * 20 + 10,
          );
      await tester.tapAt(cell(2, 1));
      await settle(tester, rounds: 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(cell(5, 2));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'sheets_select_$tag');

      // Edit a cell in place.
      await tester.tapAt(cell(7, 1));
      await settle(tester, rounds: 2);
      await tester.tapAt(cell(7, 1));
      await settle(tester, rounds: 3);
      await tester.enterText(find.byType(TextField).last, '=SUM(B3:B6)');
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'sheets_edit_$tag');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester, rounds: 3);

      await tester.tap(find.byTooltip('More options'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'sheets_menu_$tag');
      await dismissTop(tester);

      if (phone) {
        await tester.tap(find.byTooltip('More options'));
        await settle(tester, rounds: 6);
        await tester.tap(find.text('Find & replace'));
      } else {
        await tester.tap(find.byTooltip('Find & replace'));
      }
      await settle(tester, rounds: 4);
      await tester.enterText(
        find.descendant(of: find.byType(FindReplaceBar), matching: find.byType(TextField)).first,
        'North',
      );
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'sheets_find_$tag');
      await tester.tap(find.byTooltip('Close'));
      await settle(tester, rounds: 3);

      if (phone) {
        await tester.longPress(find.text('Expenses').first);
        await settle(tester, rounds: 6);
        await saveScreenshot(tester, 'sheets_tabmenu_$tag');
        await dismissTop(tester);

        await tester.longPressAt(cell(3, 1));
        await settle(tester, rounds: 6);
        await saveScreenshot(tester, 'sheets_cellmenu_$tag');
        await dismissTop(tester);

        showColorPalette(
          tester.element(find.byType(SpreadsheetScreen)),
          title: 'Fill color',
          noneLabel: 'No fill',
          current: 0xFFFFC000,
        );
        await settle(tester, rounds: 4);
        await saveScreenshot(tester, 'sheets_palette_$tag');
        await dismissTop(tester);

        await tester.ensureVisible(find.byTooltip('Number format'));
        await settle(tester, rounds: 2);
        await tester.tap(find.byTooltip('Number format'));
        await settle(tester, rounds: 6);
        await saveScreenshot(tester, 'sheets_numfmt_$tag');
        await dismissTop(tester);
      }
      await finish(tester);
    }, skip: !screenshotsEnabled);
  }
}

Workbook _sampleWorkbook() {
  const header = CellStyle(bold: true, fillColor: 0xFFDDEBF7, fontColor: 0xFF1F4E79);
  const money = CellStyle(numFmt: r'"$"#,##0.00');
  const red = CellStyle(numFmt: r'"$"#,##0.00', fontColor: 0xFFC00000);
  const navy = CellStyle(fontColor: 0xFF002060, bold: true);
  const note = CellStyle(italic: true, fontColor: 0xFF7F7F7F);
  final sales = SheetData(
    name: 'Sales',
    colWidths: {0: 140, 1: 96, 2: 96, 3: 96, 4: 96},
    frozenRows: 1,
  );
  void row(SheetData s, int r, List<Object?> values, {CellStyle style = CellStyle.plain, List<CellStyle?>? styles}) {
    for (var c = 0; c < values.length; c++) {
      final v = values[c];
      if (v == null) continue;
      final st = styles?[c] ?? style;
      if (v is String && v.startsWith('=')) {
        s.setCell(r, c, Cell(formula: v.substring(1), style: st));
      } else {
        s.setCell(r, c, Cell(value: v is int ? v.toDouble() : v, style: st));
      }
    }
  }

  row(sales, 0, ['Region', 'Q1', 'Q2', 'Q3', 'Q4'], style: header);
  final data = [
    ['North', 42000, 45500, 47250, 51800],
    ['South', 31000, 29800, 33400, 36100],
    ['East', 27500, 30100, 31900, 34650],
    ['West', 56000, 58300, 61200, 64900],
    ['Online', 18400, 22900, 27800, 33100],
  ];
  for (var i = 0; i < data.length; i++) {
    row(sales, i + 1, data[i], styles: [navy, money, money, i == 1 ? red : money, money]);
  }
  row(sales, 6, ['Total', '=SUM(B2:B6)', '=SUM(C2:C6)', '=SUM(D2:D6)', '=SUM(E2:E6)'],
      styles: [const CellStyle(bold: true), money, money, money, money]);
  row(sales, 9, ['Figures in USD, before tax.'], style: note);

  final expenses = SheetData(name: 'Expenses', colWidths: {0: 140, 1: 96});
  row(expenses, 0, ['Item', 'Cost'], style: header);
  row(expenses, 1, ['Rent', 12000], styles: [null, money]);
  row(expenses, 2, ['Salaries', 86000], styles: [null, money]);
  final notes = SheetData(name: 'Notes', colWidths: {0: 300});
  row(notes, 0, ['Prepared by Finance · October 2026']);
  return Workbook(sheets: [sales, expenses, notes], format: SpreadsheetFormat.xlsx);
}
