import 'dart:typed_data';

import 'package:folder/core/formats/cfb_reader.dart';

import '../formula/evaluator.dart';
import '../model/workbook.dart';
import 'csv_codec.dart';
import 'ods_reader.dart';
import 'xls_reader.dart';
import 'xlsx_reader.dart';

export 'xlsx_reader.dart' show SpreadsheetReadException;

/// Options for re-reading delimited text.
class CsvLoadOptions {
  const CsvLoadOptions({this.delimiter, this.hasHeader});
  final String? delimiter;
  final bool? hasHeader;
}

/// Parses any supported spreadsheet. Safe to call inside `Isolate.run`.
Workbook loadWorkbook(Uint8List bytes, {required String fileName, CsvLoadOptions? csv}) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  final baseName = dot < 0 ? fileName : fileName.substring(0, dot);
  final byExt = SpreadsheetFormat.fromExtension(ext);

  Workbook wb;
  final isZip = bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
  if (bytes.isEmpty) {
    wb = Workbook(sheets: [SheetData(name: 'Sheet1')], format: byExt ?? SpreadsheetFormat.xlsx);
    if (byExt == SpreadsheetFormat.csv) {
      wb.csv = CsvSettings(delimiter: CsvCodec.hintForExtension(ext) ?? ',');
    }
    return wb;
  }
  if (isZip) {
    final pkg = XlsxPackage.decode(bytes);
    final mime = pkg.text('mimetype')?.trim() ?? '';
    if (mime.startsWith('application/vnd.oasis.opendocument.spreadsheet') ||
        (pkg.has('content.xml') && !pkg.has('[Content_Types].xml'))) {
      wb = OdsReader.read(bytes);
    } else {
      final fmt = byExt != null && byExt.isXlsxFamily ? byExt : SpreadsheetFormat.xlsx;
      wb = XlsxReader.read(bytes, fmt, package: pkg);
    }
  } else if (CfbReader.isCfb(bytes)) {
    // OLE2: either BIFF or an encrypted OOXML package.
    final cfb = CfbReader(bytes);
    if (cfb.find('EncryptedPackage') != null || cfb.find('EncryptionInfo') != null) {
      throw SpreadsheetReadException('This workbook is password-protected and can\'t be opened here.');
    }
    wb = XlsReader.read(bytes);
  } else if (_looksLikeMarkup(bytes) && byExt != SpreadsheetFormat.csv) {
    throw SpreadsheetReadException(
        'This is an HTML or XML spreadsheet export, which isn\'t supported here. '
        'Try "Open in another app".');
  } else {
    wb = CsvCodec.read(bytes,
        sheetName: sheetNameFromFileName(baseName),
        delimiter: csv?.delimiter,
        extHint: ext,
        hasHeader: csv?.hasHeader);
    if (byExt != SpreadsheetFormat.csv && byExt != null) {
      wb.warnings.add('This file isn\'t really a ${ext.toUpperCase()} workbook; it was opened as text.');
    }
  }
  // Fill in formulas that have no cached value.
  try {
    FormulaEngine(wb).recalcMissing();
  } catch (_) {}
  return wb;
}

/// A sheet name Excel accepts, derived from a file name: forbidden
/// characters become `_`, no leading/trailing apostrophe, at most 31 UTF-16
/// units without splitting a surrogate pair, `Sheet1` when nothing is left.
String sheetNameFromFileName(String baseName) {
  var n = baseName.replaceAll(invalidSheetNameChars, '_').trim();
  while (n.startsWith("'")) {
    n = n.substring(1);
  }
  while (n.endsWith("'")) {
    n = n.substring(0, n.length - 1);
  }
  if (n.length > 31) {
    var cut = 31;
    final u = n.codeUnitAt(cut - 1);
    if (u >= 0xD800 && u <= 0xDBFF) cut--; // don't keep half a pair
    n = n.substring(0, cut).trimRight();
    while (n.endsWith("'")) {
      n = n.substring(0, n.length - 1);
    }
  }
  return n.trim().isEmpty ? 'Sheet1' : n;
}

/// A quick, read-only look at the first [rows] rows of the sheet that opens
/// first, for big files (xlsx family and delimited text), or null. Formulas
/// show the values cached in the file. Safe to call inside `Isolate.run`.
Workbook? loadWorkbookPreview(Uint8List bytes,
    {required String fileName, CsvLoadOptions? csv, int rows = 300}) {
  final dot = fileName.lastIndexOf('.');
  final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
  final baseName = dot < 0 ? fileName : fileName.substring(0, dot);
  final byExt = SpreadsheetFormat.fromExtension(ext);
  if (bytes.isEmpty) return null;
  final isZip = bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B;
  if (isZip) {
    final pkg = XlsxPackage.decode(bytes);
    if (!pkg.has('[Content_Types].xml') || pkg.has('content.xml')) return null; // ODS
    final fmt = byExt != null && byExt.isXlsxFamily ? byExt : SpreadsheetFormat.xlsx;
    return XlsxReader.readPreview(bytes, fmt, package: pkg, rows: rows);
  }
  if (byExt != SpreadsheetFormat.csv || CfbReader.isCfb(bytes) || _looksLikeMarkup(bytes)) return null;
  return CsvCodec.read(bytes,
      sheetName: sheetNameFromFileName(baseName),
      delimiter: csv?.delimiter,
      extHint: ext,
      hasHeader: csv?.hasHeader,
      previewRows: rows);
}

bool _looksLikeMarkup(Uint8List bytes) {
  final n = bytes.length < 512 ? bytes.length : 512;
  var head = String.fromCharCodes(bytes.sublist(0, n)).toLowerCase();
  if (head.startsWith('ï»¿')) head = head.substring(3);
  head = head.trimLeft();
  return head.startsWith('<?xml') ||
      head.startsWith('<!doctype html') ||
      head.startsWith('<html') ||
      head.startsWith('<table');
}
