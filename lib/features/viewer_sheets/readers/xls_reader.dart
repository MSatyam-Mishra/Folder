import 'dart:typed_data';

import 'package:folder/core/formats/cfb_reader.dart';

import '../model/number_format.dart';
import '../model/workbook.dart';
import 'xls_formula.dart';
import 'xlsx_reader.dart' show SpreadsheetReadException;
import 'xlsx_styles.dart' show defaultIndexedColors;

class _Record {
  _Record(this.type, this.offset, this.data);
  final int type;

  /// Stream offset of the record header.
  final int offset;
  final Uint8List data;
}

class _Xf {
  _Xf(this.font, this.fmt, this.hAlign, this.vAlign, this.wrap, this.fill);
  final int font;
  final int fmt;
  final int hAlign;
  final int vAlign;
  final bool wrap;
  final int? fill; // palette index
}

class _Font {
  _Font(this.bold, this.italic, this.underline, this.strike, this.color, this.height);
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int color;
  final double height; // points
}

class _BoundSheet {
  _BoundSheet(this.offset, this.state, this.type, this.name);
  final int offset;
  final int state;
  final int type;
  final String name;
}

/// Reads Excel 97-2003 (BIFF8) workbooks; BIFF5 values best effort.
class XlsReader {
  XlsReader._(this._data) : _bd = ByteData.sublistView(_data);

  static Workbook read(Uint8List bytes) {
    if (!CfbReader.isCfb(bytes)) {
      throw SpreadsheetReadException('This doesn\'t look like an Excel 97-2003 file.');
    }
    final CfbReader cfb;
    try {
      cfb = CfbReader(bytes);
    } on FormatException {
      throw SpreadsheetReadException('This .xls file is damaged.');
    }
    if (cfb.find('EncryptedPackage') != null) {
      throw SpreadsheetReadException('This workbook is password-protected and can\'t be opened here.');
    }
    final stream = cfb.readStream('Workbook') ?? cfb.readStream('Book');
    if (stream == null) {
      throw SpreadsheetReadException('This file doesn\'t contain an Excel workbook.');
    }
    return XlsReader._(stream)._read();
  }

  final Uint8List _data;
  final ByteData _bd;
  var _biff8 = true;
  var _codepage = 1252;
  var _date1904 = false;
  final _fonts = <_Font>[];
  final _formats = <int, String>{};
  final _xfs = <_Xf>[];
  final _palette = List<int>.of(defaultIndexedColors);
  final _sheets = <_BoundSheet>[];
  final _sst = <String>[];
  final _xti = <(int, int, int)>[];
  var _internalSupbook = -1;
  var _supbookCount = 0;
  final _styleCache = <int, CellStyle>{};

  int _u16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);
  int _u32(Uint8List d, int o) =>
      d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

  _Record? _recordAt(int offset) {
    if (offset + 4 > _data.length) return null;
    final type = _bd.getUint16(offset, Endian.little);
    final len = _bd.getUint16(offset + 2, Endian.little);
    final end = offset + 4 + len;
    if (end > _data.length) return null;
    return _Record(type, offset, Uint8List.sublistView(_data, offset + 4, end));
  }

  String _decode8(List<int> bytes) =>
      _codepage == 1200 ? String.fromCharCodes(bytes) : decodeCp1252(bytes);

  /// XLUnicodeString with a 16-bit length (BIFF8) or 8-bit string (BIFF5).
  (String, int) _readString(Uint8List d, int o, {bool shortLen = false}) {
    if (!_biff8) {
      final cch = shortLen ? d[o] : _u16(d, o);
      final start = o + (shortLen ? 1 : 2);
      final end = (start + cch).clamp(0, d.length);
      return (_decode8(d.sublist(start, end)), end);
    }
    final cch = shortLen ? d[o] : _u16(d, o);
    var p = o + (shortLen ? 1 : 2);
    final flags = d[p];
    p++;
    var runs = 0;
    var ext = 0;
    if ((flags & 0x08) != 0) {
      runs = _u16(d, p);
      p += 2;
    }
    if ((flags & 0x04) != 0) {
      ext = _u32(d, p);
      p += 4;
    }
    String s;
    if ((flags & 0x01) != 0) {
      final end = (p + cch * 2).clamp(0, d.length);
      s = decodeUtf16le(d.sublist(p, end));
      p = end;
    } else {
      final end = (p + cch).clamp(0, d.length);
      s = String.fromCharCodes(d.sublist(p, end));
      p = end;
    }
    p += runs * 4 + ext;
    return (s, p);
  }

  Workbook _read() {
    var offset = 0;
    final bof = _recordAt(0);
    if (bof == null || (bof.type != 0x0809)) {
      if (bof != null && (bof.type == 0x0009 || bof.type == 0x0209 || bof.type == 0x0409)) {
        throw SpreadsheetReadException('This Excel file is too old (Excel 2-4) to open here.');
      }
      throw SpreadsheetReadException('This .xls file is damaged or unsupported.');
    }
    final version = _u16(bof.data, 0);
    _biff8 = version == 0x0600;
    if (version != 0x0600 && version != 0x0500) {
      throw SpreadsheetReadException('This Excel file format version isn\'t supported.');
    }

    // Workbook globals.
    while (true) {
      final rec = _recordAt(offset);
      if (rec == null) break;
      offset += 4 + rec.data.length;
      final d = rec.data;
      switch (rec.type) {
        case 0x002F: // FILEPASS
          throw SpreadsheetReadException(
              'This workbook is password-protected and can\'t be opened here.');
        case 0x0042: // CODEPAGE
          _codepage = _u16(d, 0);
        case 0x0022: // DATEMODE
          _date1904 = _u16(d, 0) == 1;
        case 0x0031: // FONT
          final height = _u16(d, 0) / 20.0;
          final grbit = _u16(d, 2);
          final color = _u16(d, 4);
          final weight = _u16(d, 6);
          final underline = d.length > 10 ? d[10] : 0;
          _fonts.add(_Font(weight >= 700, (grbit & 0x02) != 0, underline != 0,
              (grbit & 0x08) != 0, color, height));
        case 0x041E: // FORMAT
          final id = _u16(d, 0);
          final (s, _) = _readString(d, 2, shortLen: !_biff8);
          _formats[id] = s;
        case 0x00E0: // XF
          if (_biff8 && d.length >= 20) {
            final align = d[6];
            final fill = _u32(d, 14);
            final colors = _u16(d, 18);
            final pattern = (fill >> 26) & 0x3F;
            _xfs.add(_Xf(_u16(d, 0), _u16(d, 2), align & 0x07, (align >> 4) & 0x07,
                (align & 0x08) != 0, pattern == 0 ? null : (colors & 0x7F)));
          } else if (d.length >= 16) {
            final align = d[6];
            final colors = _u32(d, 8);
            final pattern = (colors >> 16) & 0x3F;
            _xfs.add(_Xf(_u16(d, 0), _u16(d, 2), align & 0x07, (align >> 4) & 0x07,
                (align & 0x08) != 0, pattern == 0 ? null : (colors & 0x7F)));
          } else {
            _xfs.add(_Xf(0, 0, 0, 2, false, null));
          }
        case 0x0092: // PALETTE
          final n = _u16(d, 0);
          for (var k = 0; k < n && 8 + k < _palette.length; k++) {
            final o = 2 + k * 4;
            if (o + 3 > d.length) break;
            _palette[8 + k] = (d[o] << 16) | (d[o + 1] << 8) | d[o + 2];
          }
        case 0x0085: // BOUNDSHEET
          final pos = _u32(d, 0);
          final state = d[4] & 0x03;
          final type = d[5];
          final (name, _) = _readString(d, 6, shortLen: true);
          _sheets.add(_BoundSheet(pos, state, type, name));
        case 0x00FC: // SST
          _readSst(rec, offset);
        case 0x01AE: // SUPBOOK
          if (d.length >= 4 && _u16(d, 2) == 0x0401) _internalSupbook = _supbookCount;
          _supbookCount++;
        case 0x0017: // EXTERNSHEET
          if (_biff8) {
            final n = _u16(d, 0);
            for (var k = 0; k < n; k++) {
              final o = 2 + k * 6;
              if (o + 6 > d.length) break;
              _xti.add((_u16(d, o), _bd16s(d, o + 2), _bd16s(d, o + 4)));
            }
          }
      }
      if (rec.type == 0x000A) break; // EOF
    }

    final worksheets = _sheets.where((s) => s.type == 0).toList();
    final warnings = <String>[];
    for (final s in _sheets) {
      if (s.type != 0) warnings.add('"${s.name}" is a chart or macro sheet and isn\'t shown.');
    }
    if (worksheets.isEmpty) throw SpreadsheetReadException('This workbook has no worksheets.');

    final decoder = BiffFormulaDecoder(sheetNameForXti: (ixti) {
      if (ixti >= _xti.length) return null;
      final x = _xti[ixti];
      if (x.$1 != _internalSupbook && _internalSupbook >= 0) return null;
      final tab = x.$2;
      if (tab < 0 || tab >= _sheets.length) return null;
      return _sheets[tab].name;
    });

    final sheets = <SheetData>[];
    for (final bs in worksheets) {
      final sheet = SheetData(
        name: bs.name,
        visibility: bs.state == 1
            ? SheetVisibility.hidden
            : bs.state == 2
                ? SheetVisibility.veryHidden
                : SheetVisibility.visible,
      );
      _readSheet(bs.offset, sheet, decoder);
      sheet.invalidateBounds();
      sheets.add(sheet);
    }
    if (!_biff8) {
      warnings.add('Excel 95 file: formulas and some formatting aren\'t shown.');
    }
    var active = sheets.indexWhere((s) => s.visibility == SheetVisibility.visible);
    if (active < 0) active = 0;
    return Workbook(
      sheets: sheets,
      format: SpreadsheetFormat.xls,
      date1904: _date1904,
      activeSheet: active,
      warnings: warnings,
    );
  }

  int _bd16s(Uint8List d, int o) {
    final v = _u16(d, o);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  /// SST with CONTINUE handling: strings may split across records, and a
  /// split inside character data starts the next record with a new
  /// option-flags byte.
  void _readSst(_Record first, int nextOffset) {
    final chunks = <Uint8List>[first.data];
    var off = nextOffset;
    while (true) {
      final r = _recordAt(off);
      if (r == null || r.type != 0x003C) break;
      chunks.add(r.data);
      off += 4 + r.data.length;
    }
    final total = _u32(first.data, 4);
    var ci = 0;
    var p = 8;
    Uint8List cur = chunks[0];

    bool ensure(int n) {
      // Moves to the next chunk when the current one is exhausted (only at
      // boundaries where no flag byte is inserted).
      while (p >= cur.length) {
        ci++;
        if (ci >= chunks.length) return false;
        cur = chunks[ci];
        p = 0;
      }
      return p + n <= cur.length || ci + 1 < chunks.length;
    }

    int readByte() {
      if (!ensure(1)) throw RangeError('sst');
      return cur[p++];
    }

    int readU16() => readByte() | (readByte() << 8);
    int readU32() => readU16() | (readU16() << 16);

    void skip(int n) {
      var left = n;
      while (left > 0) {
        if (!ensure(1)) return;
        final take = (cur.length - p) < left ? cur.length - p : left;
        p += take;
        left -= take;
      }
    }

    try {
      for (var k = 0; k < total; k++) {
        final cch = readU16();
        var flags = readByte();
        var runs = 0;
        var ext = 0;
        if ((flags & 0x08) != 0) runs = readU16();
        if ((flags & 0x04) != 0) ext = readU32();
        final units = <int>[];
        var remaining = cch;
        while (remaining > 0) {
          if (p >= cur.length) {
            ci++;
            if (ci >= chunks.length) break;
            cur = chunks[ci];
            p = 0;
            flags = cur[p++]; // continuation option flags
          }
          final wide = (flags & 0x01) != 0;
          final avail = cur.length - p;
          final n = wide ? avail ~/ 2 : avail;
          final take = n < remaining ? n : remaining;
          if (wide) {
            for (var j = 0; j < take; j++) {
              units.add(cur[p] | (cur[p + 1] << 8));
              p += 2;
            }
          } else {
            for (var j = 0; j < take; j++) {
              units.add(cur[p++]);
            }
          }
          remaining -= take;
          if (take == 0 && remaining > 0) {
            // Odd leftover byte; move on.
            p = cur.length;
          }
        }
        _sst.add(String.fromCharCodes(units));
        skip(runs * 4 + ext);
      }
    } on RangeError {
      // Truncated SST: keep what we have.
    }
  }

  CellStyle _style(int ixfe) {
    final cached = _styleCache[ixfe];
    if (cached != null) return cached;
    if (ixfe < 0 || ixfe >= _xfs.length) return CellStyle.plain;
    final xf = _xfs[ixfe];
    final fontIdx = xf.font >= 4 ? xf.font - 1 : xf.font;
    final font = fontIdx >= 0 && fontIdx < _fonts.length ? _fonts[fontIdx] : null;
    final baseSize = _fonts.isNotEmpty ? _fonts.first.height : 10.0;
    int? color(int idx, {bool font = false}) {
      if (idx >= 64 || idx == 0x7FFF) return null;
      if (font && (idx == 8 || idx == 0)) return null;
      if (idx < 0 || idx >= _palette.length) return null;
      return 0xFF000000 | _palette[idx];
    }

    final code = _formats[xf.fmt] ?? NumberFormats.codeForId(xf.fmt);
    final style = CellStyle(
      bold: font?.bold ?? false,
      italic: font?.italic ?? false,
      underline: font?.underline ?? false,
      strike: font?.strike ?? false,
      fontColor: font == null ? null : color(font.color, font: true),
      fontSize: font == null || font.height == baseSize ? null : font.height * 11 / baseSize,
      fillColor: xf.fill == null ? null : color(xf.fill!),
      hAlign: switch (xf.hAlign) {
        1 => HAlign.left,
        2 => HAlign.center,
        3 => HAlign.right,
        4 => HAlign.fill,
        5 => HAlign.justify,
        6 => HAlign.centerContinuous,
        7 => HAlign.distributed,
        _ => HAlign.general,
      },
      vAlign: switch (xf.vAlign) {
        0 => VAlign.top,
        1 => VAlign.center,
        3 => VAlign.justify,
        4 => VAlign.distributed,
        _ => VAlign.bottom,
      },
      wrap: xf.wrap,
      numFmt: code,
    );
    _styleCache[ixfe] = style;
    return style;
  }

  static double _rk(int rk) {
    double v;
    if ((rk & 0x02) != 0) {
      v = (rk.toSigned(32) >> 2).toDouble();
    } else {
      final bd = ByteData(8)..setUint32(4, rk & 0xFFFFFFFC, Endian.little);
      v = bd.getFloat64(0, Endian.little);
    }
    if ((rk & 0x01) != 0) v /= 100;
    return v;
  }

  void _readSheet(int start, SheetData sheet, BiffFormulaDecoder decoder) {
    final bof = _recordAt(start);
    if (bof == null || bof.type != 0x0809) return;
    var off = start + 4 + bof.data.length;
    var depth = 0;
    (int, int)? pendingString;
    final sharedFormulas = <int, (Uint8List, int, int)>{};
    final pendingShared = <(int, int, int, int)>[]; // row, col, masterRow, masterCol
    var frozen = false;

    void put(int r, int c, Cell cell) {
      if (r >= kMaxRows || c >= kMaxCols) return;
      sheet.cells[cellKey(r, c)] = cell;
    }

    while (true) {
      final rec = _recordAt(off);
      if (rec == null) break;
      off += 4 + rec.data.length;
      final d = rec.data;
      if (rec.type == 0x0809) {
        depth++; // embedded chart substream
        continue;
      }
      if (rec.type == 0x000A) {
        if (depth == 0) break;
        depth--;
        continue;
      }
      if (depth > 0) continue;
      switch (rec.type) {
        case 0x00FD: // LABELSST
          if (d.length < 10) break;
          final idx = _u32(d, 6);
          put(_u16(d, 0), _u16(d, 2),
              Cell(value: idx < _sst.length ? _sst[idx] : '', style: _style(_u16(d, 4))));
        case 0x0204: // LABEL
        case 0x00D6: // RSTRING
          if (d.length < 8) break;
          final (s, _) = _readString(d, 6);
          put(_u16(d, 0), _u16(d, 2), Cell(value: s, style: _style(_u16(d, 4))));
        case 0x0203: // NUMBER
          if (d.length < 14) break;
          put(_u16(d, 0), _u16(d, 2),
              Cell(value: _bd64(d, 6), style: _style(_u16(d, 4))));
        case 0x027E: // RK
          if (d.length < 10) break;
          put(_u16(d, 0), _u16(d, 2), Cell(value: _rk(_u32(d, 6)), style: _style(_u16(d, 4))));
        case 0x00BD: // MULRK
          if (d.length < 6) break;
          final r = _u16(d, 0);
          final c0 = _u16(d, 2);
          final n = (d.length - 6) ~/ 6;
          for (var k = 0; k < n; k++) {
            final o = 4 + k * 6;
            put(r, c0 + k, Cell(value: _rk(_u32(d, o + 2)), style: _style(_u16(d, o))));
          }
        case 0x0205: // BOOLERR
          if (d.length < 8) break;
          final v = d[6];
          final isErr = d[7] != 0;
          put(_u16(d, 0), _u16(d, 2), Cell(
            value: isErr ? CellError(biffErrorCode(v)) : v != 0,
            style: _style(_u16(d, 4)),
          ));
        case 0x0201: // BLANK
          if (d.length < 6) break;
          final ixfe = _u16(d, 4);
          if (ixfe != 15 && _style(ixfe).fillColor != null) {
            put(_u16(d, 0), _u16(d, 2), Cell(style: _style(ixfe)));
          }
        case 0x00BE: // MULBLANK
          if (d.length < 6) break;
          final r = _u16(d, 0);
          final c0 = _u16(d, 2);
          final n = (d.length - 6) ~/ 2;
          for (var k = 0; k < n; k++) {
            final ixfe = _u16(d, 4 + k * 2);
            if (ixfe != 15 && _style(ixfe).fillColor != null) {
              put(r, c0 + k, Cell(style: _style(ixfe)));
            }
          }
        case 0x0006: // FORMULA
          if (d.length < 20) break;
          final r = _u16(d, 0);
          final c = _u16(d, 2);
          final style = _style(_u16(d, 4));
          Object? value;
          if (d[12] == 0xFF && d[13] == 0xFF) {
            switch (d[6]) {
              case 0:
                pendingString = (r, c);
                value = null; // filled by the following STRING record
              case 1:
                value = d[8] != 0;
              case 2:
                value = CellError(biffErrorCode(d[8]));
              case 3:
                value = '';
            }
          } else {
            value = _bd64(d, 6);
          }
          String? formula;
          if (_biff8 && d.length >= 22) {
            final cce = _u16(d, 20);
            if (22 + cce <= d.length) {
              final rgce = Uint8List.sublistView(d, 22, 22 + cce);
              if (cce == 5 && rgce[0] == 0x01) {
                // ptgExp: shared or array formula, resolved later.
                pendingShared.add((r, c, _u16(rgce, 1), _u16(rgce, 3)));
              } else {
                formula = decoder.decode(rgce, row: r, col: c);
              }
            }
          }
          // fAlwaysCalc / fCalcOnLoad or an empty-string result (what many
          // non-Excel writers store): recompute instead of trusting it.
          final emptyResult = d[12] == 0xFF && d[13] == 0xFF && d[6] == 3;
          if (formula != null && (emptyResult || (_u16(d, 14) & 0x03) != 0)) {
            value = null;
            pendingString = null;
          }
          put(r, c, Cell(value: value, formula: formula, style: style));
        case 0x0207: // STRING
          if (pendingString != null && d.length >= 2) {
            final (s, _) = _readStringWithContinue(rec, off);
            final p = pendingString;
            final existing = sheet.cells[cellKey(p.$1, p.$2)];
            if (existing != null) {
              sheet.cells[cellKey(p.$1, p.$2)] = existing.withValue(s);
            }
          }
          pendingString = null;
        case 0x04BC: // SHRFMLA
          if (!_biff8 || d.length < 10) break;
          final r1 = _u16(d, 0);
          final c1 = d[4];
          final cce = _u16(d, 8);
          if (10 + cce <= d.length) {
            sharedFormulas[cellKey(r1, c1)] =
                (Uint8List.fromList(d.sublist(10, 10 + cce)), r1, c1);
          }
        case 0x00E5: // MERGEDCELLS
          final n = _u16(d, 0);
          for (var k = 0; k < n; k++) {
            final o = 2 + k * 8;
            if (o + 8 > d.length) break;
            final m = CellRange(_u16(d, o), _u16(d, o + 4), _u16(d, o + 2), _u16(d, o + 6));
            if (!m.isSingle) sheet.merges.add(m);
          }
        case 0x007D: // COLINFO
          if (d.length < 10) break;
          final first = _u16(d, 0);
          final last = _u16(d, 2);
          final w = _u16(d, 4) / 256.0 * 7;
          final hidden = (_u16(d, 8) & 0x01) != 0;
          for (var c = first; c <= last && c < 256; c++) {
            sheet.colWidths[c] = w.roundToDouble();
            if (hidden) sheet.hiddenCols.add(c);
          }
        case 0x0055: // DEFCOLWIDTH
          if (d.length >= 2) sheet.defaultColWidth = (_u16(d, 0) * 7 + 5).toDouble();
        case 0x0099: // STANDARDWIDTH
          if (d.length >= 2) sheet.defaultColWidth = (_u16(d, 0) / 256.0 * 7).roundToDouble();
        case 0x0225: // DEFAULTROWHEIGHT
          if (d.length >= 4) {
            final h = _u16(d, 2);
            if (h > 0) sheet.defaultRowHeight = (h / 20 * 4 / 3).roundToDouble();
          }
        case 0x0208: // ROW
          if (d.length < 16) break;
          final r = _u16(d, 0);
          final h = _u16(d, 6) & 0x7FFF;
          final flags = _u16(d, 12);
          if ((flags & 0x40) != 0 && h > 0) {
            sheet.rowHeights[r] = (h / 20 * 4 / 3).roundToDouble();
          }
          if ((flags & 0x20) != 0) sheet.hiddenRows.add(r);
        case 0x023E: // WINDOW2
          if (d.length >= 2) frozen = (_u16(d, 0) & 0x0008) != 0;
        case 0x0041: // PANE
          if (frozen && d.length >= 4) {
            sheet.frozenCols = _u16(d, 0).clamp(0, 255);
            sheet.frozenRows = _u16(d, 2).clamp(0, 65535);
          }
      }
    }

    // Resolve shared formulas now that SHRFMLA records are known.
    for (final (r, c, mr, mc) in pendingShared) {
      final sf = sharedFormulas[cellKey(mr, mc)];
      if (sf == null) continue;
      final f = decoder.decode(sf.$1, row: r, col: c, shared: true);
      if (f == null) continue;
      final key = cellKey(r, c);
      final cell = sheet.cells[key];
      if (cell != null) sheet.cells[key] = Cell(value: cell.value, formula: f, style: cell.style);
    }
  }

  double _bd64(Uint8List d, int o) => ByteData.sublistView(d, o, o + 8).getFloat64(0, Endian.little);

  /// STRING record (formula result) which may continue in CONTINUE records.
  (String, int) _readStringWithContinue(_Record rec, int nextOffset) {
    final d = rec.data;
    if (!_biff8) return _readString(d, 0);
    final cch = _u16(d, 0);
    var flags = d[2];
    var p = 3;
    var cur = d;
    var off = nextOffset;
    final units = <int>[];
    var remaining = cch;
    while (remaining > 0) {
      if (p >= cur.length) {
        final next = _recordAt(off);
        if (next == null || next.type != 0x003C) break;
        off += 4 + next.data.length;
        cur = next.data;
        p = 0;
        flags = cur[p++];
      }
      final wide = (flags & 1) != 0;
      if (wide) {
        if (p + 1 >= cur.length) {
          p = cur.length;
          continue;
        }
        units.add(cur[p] | (cur[p + 1] << 8));
        p += 2;
      } else {
        units.add(cur[p++]);
      }
      remaining--;
    }
    return (String.fromCharCodes(units), p);
  }
}
