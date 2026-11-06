import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folders/core/formats/cfb_reader.dart';

import 'doc_model.dart';
import 'docx_parser.dart' show loadImageData, mapSymbolChar;

/// Thrown for password-protected / obfuscated documents.
class DocumentEncryptedException implements Exception {
  const DocumentEncryptedException();
  @override
  String toString() => 'This document is password-protected.';
}

/// Parses Word 97–2003 binary documents (`.doc`, `.dot`, and `.wps` files
/// that are really Word documents) from their OLE2 container. [onPreview]
/// receives a long document's first pages' blocks early (at most once).
DocModel parseDocBytes(
  Uint8List bytes, {
  String format = 'doc',
  void Function(DocModel preview)? onPreview,
}) {
  final cfb = CfbReader(bytes);
  if (cfb.find('EncryptedPackage') != null) {
    throw const DocumentEncryptedException();
  }
  final wd = cfb.readStream('WordDocument');
  if (wd == null) {
    throw const FormatException('Not a Word document (no WordDocument stream)');
  }
  return _DocParser(cfb, wd, format, onPreview).parse();
}

class _Sprm {
  _Sprm(this.op, this.data);
  final int op;
  final Uint8List data;
  int get u8 => data.isEmpty ? 0 : data[0];
  int get i16 => data.length < 2
      ? 0
      : ByteData.sublistView(data).getInt16(0, Endian.little);
  int get u16 => data.length < 2
      ? 0
      : ByteData.sublistView(data).getUint16(0, Endian.little);
  int get i32 => data.length < 4
      ? 0
      : ByteData.sublistView(data).getInt32(0, Endian.little);
}

List<_Sprm> _parseGrpprl(Uint8List b, int start, int end) {
  final out = <_Sprm>[];
  var i = start;
  final bd = ByteData.sublistView(b);
  while (i + 2 <= end && i + 2 <= b.length) {
    final op = bd.getUint16(i, Endian.little);
    final spra = op >> 13;
    var dataStart = i + 2;
    int size;
    switch (spra) {
      case 0:
      case 1:
        size = 1;
      case 2:
      case 4:
      case 5:
        size = 2;
      case 3:
        size = 4;
      case 7:
        size = 3;
      default:
        if (dataStart >= b.length) return out;
        if (op == 0xD608 || op == 0xD606) {
          if (dataStart + 2 > b.length) return out;
          size = bd.getUint16(dataStart, Endian.little) - 1;
          dataStart += 2;
        } else {
          size = b[dataStart];
          dataStart += 1;
        }
    }
    if (size < 0 || dataStart + size > b.length) return out;
    out.add(_Sprm(op, Uint8List.sublistView(b, dataStart, dataStart + size)));
    i = dataStart + size;
  }
  return out;
}

class _Piece {
  _Piece(this.cpStart, this.cpEnd, this.fc, this.compressed);
  final int cpStart;
  final int cpEnd;
  final int fc;
  final bool compressed;
  int fcOf(int cp) => fc + (cp - cpStart) * (compressed ? 1 : 2);
}

class _FcRun {
  _FcRun(this.start, this.end, this.sprms, [this.istd = 0]);
  final int start;
  final int end;
  final List<_Sprm> sprms;
  final int istd;
}

class _StyleInfo {
  _StyleInfo(this.name, this.type, this.base, this.papx, this.chpx);
  final String name;
  final int type; // 1 paragraph, 2 character
  final int base;
  final List<_Sprm> papx;
  final List<_Sprm> chpx;
}

class _LvlInfo {
  _LvlInfo(this.start, this.nfc, this.text, this.papx);
  final int start;
  final int nfc;
  final String text;
  final List<_Sprm> papx;
}

class _CharProps {
  bool bold = false,
      italic = false,
      strike = false,
      caps = false,
      smallCaps = false;
  bool vanish = false, deleted = false, special = false;
  bool underline = false;
  int? color;
  int? highlight;
  double size = 10;
  int font = 0;
  int iss = 0;
  int picLocation = -1;

  _CharProps copy() => _CharProps()
    ..bold = bold
    ..italic = italic
    ..strike = strike
    ..caps = caps
    ..smallCaps = smallCaps
    ..vanish = vanish
    ..deleted = deleted
    ..special = special
    ..underline = underline
    ..color = color
    ..highlight = highlight
    ..size = size
    ..font = font
    ..iss = iss
    ..picLocation = picLocation;
}

class _ParaProps {
  int istd = 0;
  DocAlign align = DocAlign.left;
  double left = 0, right = 0, first = 0, before = 0, after = 0;
  double line = 1;
  double? exact;
  bool inTable = false, ttp = false, keepNext = false, pageBreakBefore = false;
  bool bidi = false;
  int itap = 0;
  int ilfo = 0, ilvl = 0;
  int? outline;
  List<double>? cellEdges;
}

const _icoColors = [
  null,
  0xFF000000,
  0xFF0000FF,
  0xFF00FFFF,
  0xFF00FF00,
  0xFFFF00FF,
  0xFFFF0000,
  0xFFFFFF00,
  0xFFFFFFFF,
  0xFF000080,
  0xFF008080,
  0xFF008000,
  0xFF800080,
  0xFF800000,
  0xFF808000,
  0xFF808080,
  0xFFC0C0C0,
];

class _DocParser {
  _DocParser(this.cfb, this.wd, this.format, this.onPreview)
    : bd = ByteData.sublistView(wd);

  final CfbReader cfb;
  final Uint8List wd;
  final ByteData bd;
  final String format;
  final void Function(DocModel preview)? onPreview;
  Uint8List table = Uint8List(0);
  late ByteData tb;
  Uint8List? data;

  final List<_Piece> pieces = [];
  final List<_FcRun> papxRuns = [];
  final List<_FcRun> chpxRuns = [];
  final Map<int, _StyleInfo> styles = {};
  final List<String> fonts = [];
  final Map<int, List<_LvlInfo>> lists = {}; // lsid -> levels
  final List<int> lfoLsid = [];
  final Map<String, DocImageData> images = {};
  DocPageSetup page = DocPageSetup.letter;
  int _imageNo = 0;
  int _footnote = 0;

  int u16(int o) => o + 2 <= wd.length ? bd.getUint16(o, Endian.little) : 0;
  int u32(int o) => o + 4 <= wd.length ? bd.getUint32(o, Endian.little) : 0;
  int i32(int o) => o + 4 <= wd.length ? bd.getInt32(o, Endian.little) : 0;
  int tu16(int o) => o + 2 <= table.length ? tb.getUint16(o, Endian.little) : 0;
  int tu32(int o) => o + 4 <= table.length ? tb.getUint32(o, Endian.little) : 0;
  int ti32(int o) => o + 4 <= table.length ? tb.getInt32(o, Endian.little) : 0;

  DocModel parse() {
    final ident = u16(0);
    if (ident != 0xA5EC && ident != 0xA5DC) {
      throw const FormatException('Unrecognised Word document');
    }
    final nFib = u16(2);
    final flags = u16(0x0A);
    if ((flags & 0x0100) != 0 || (flags & 0x8000) != 0) {
      throw const DocumentEncryptedException();
    }
    if (nFib < 101 || ident == 0xA5DC && nFib < 0xC1) {
      return _parseWord95();
    }
    final tableName = (flags & 0x0200) != 0 ? '1Table' : '0Table';
    table = cfb.readStream(tableName) ?? Uint8List(0);
    tb = ByteData.sublistView(table);
    data = cfb.readStream('Data');

    var off = 32;
    final csw = u16(off);
    off += 2 + csw * 2;
    final cslw = u16(off);
    off += 2;
    final rgLw = off;
    off += cslw * 4;
    off += 2; // cbRgFcLcb
    final rgFcLcb = off;
    final ccpText = i32(rgLw + 12);

    int fc(int index) => u32(rgFcLcb + index * 8);
    int lcb(int index) => u32(rgFcLcb + index * 8 + 4);

    _readPieces(fc(33), lcb(33), ccpText);
    if (pieces.isEmpty) {
      // Non-complex fallback: text straight after the FIB.
      final fcMin = u32(0x18);
      pieces.add(_Piece(0, ccpText, fcMin, true));
    }
    _safe(() => _readFonts(fc(15), lcb(15)));
    _safe(() => _readStyles(fc(1), lcb(1)));
    _safe(() => _readBte(fc(13), lcb(13), papx: true));
    _safe(() => _readBte(fc(12), lcb(12), papx: false));
    _safe(() => _readLists(fc(73), lcb(73), fc(74), lcb(74)));
    _safe(() => _readSections(fc(6), lcb(6)));

    final text = _text(0, ccpText);
    return _build(text, ccpText);
  }

  void _safe(void Function() f) {
    try {
      f();
    } catch (_) {}
  }

  DocModel _parseWord95() {
    final fcMin = u32(0x18);
    final fcMac = u32(0x1C);
    final end = fcMac.clamp(0, wd.length);
    final start = fcMin.clamp(0, end);
    pieces.add(_Piece(0, end - start, start, true));
    final text = _text(0, end - start);
    return _build(text, end - start);
  }

  void _readPieces(int fcClx, int lcbClx, int ccpText) {
    if (lcbClx == 0 || fcClx + lcbClx > table.length) return;
    var i = fcClx;
    final end = fcClx + lcbClx;
    // Everything is bounded by the Clx's own size: a damaged one must not
    // loop forever or allocate millions of pieces.
    while (i < end) {
      final type = table[i];
      if (type == 1) {
        // Prc: cbGrpprl is non-negative and must fit.
        if (i + 3 > end) return;
        final cb = tb.getInt16(i + 1, Endian.little);
        if (cb < 0 || i + 3 + cb > end) return;
        i += 3 + cb;
      } else if (type == 2) {
        if (i + 5 > end) return;
        final plc = i + 5;
        final lcb = math.min(tu32(i + 1), end - plc);
        final n = (lcb - 4) ~/ 12;
        if (n <= 0) return;
        for (var k = 0; k < n; k++) {
          final cpStart = tu32(plc + k * 4);
          final cpEnd = tu32(plc + (k + 1) * 4);
          if (cpEnd <= cpStart) continue;
          final pcd = plc + (n + 1) * 4 + k * 8;
          final fcRaw = tu32(pcd + 2);
          final compressed = (fcRaw & 0x40000000) != 0;
          final fcVal = fcRaw & 0x3FFFFFFF;
          pieces.add(
            _Piece(cpStart, cpEnd, compressed ? fcVal ~/ 2 : fcVal, compressed),
          );
        }
        return;
      } else {
        return;
      }
    }
  }

  String _text(int cpStart, int cpEnd) {
    final sb = StringBuffer();
    for (final p in pieces) {
      final s = p.cpStart < cpStart ? cpStart : p.cpStart;
      final e = p.cpEnd > cpEnd ? cpEnd : p.cpEnd;
      if (e <= s) continue;
      final fcS = p.fcOf(s);
      if (p.compressed) {
        final end = (fcS + (e - s)).clamp(0, wd.length);
        if (fcS < end) {
          sb.write(decodeCp1252(Uint8List.sublistView(wd, fcS, end)));
        }
      } else {
        final end = (fcS + (e - s) * 2).clamp(0, wd.length);
        if (fcS < end) {
          sb.write(decodeUtf16le(Uint8List.sublistView(wd, fcS, end)));
        }
      }
    }
    return sb.toString();
  }

  _Piece? _lastPiece;

  _Piece? _pieceAt(int cp) {
    // Text is walked in order, so the previous piece almost always matches.
    final last = _lastPiece;
    if (last != null && cp >= last.cpStart && cp < last.cpEnd) return last;
    for (final p in pieces) {
      if (cp >= p.cpStart && cp < p.cpEnd) return _lastPiece = p;
    }
    return null;
  }

  int _fcOf(int cp) => _pieceAt(cp)?.fcOf(cp) ?? -1;

  void _readFonts(int fc, int lcb) {
    if (lcb == 0 || fc + lcb > table.length) return;
    final count = tu16(fc);
    var pos = fc + 4;
    for (var i = 0; i < count && pos < fc + lcb; i++) {
      final cb = table[pos] + 1;
      final nameStart = pos + 40;
      final units = <int>[];
      for (var j = nameStart; j + 1 < pos + cb; j += 2) {
        final u = tu16(j);
        if (u == 0) break;
        units.add(u);
      }
      fonts.add(String.fromCharCodes(units));
      pos += cb;
    }
  }

  void _readStyles(int fc, int lcb) {
    if (lcb == 0 || fc + lcb > table.length) return;
    final cbStshi = tu16(fc);
    final stshi = fc + 2;
    final cstd = tu16(stshi);
    final cbStdBase = tu16(stshi + 2);
    var pos = stshi + cbStshi;
    for (var istd = 0; istd < cstd && pos + 2 <= fc + lcb; istd++) {
      final cbStd = tu16(pos);
      final std = pos + 2;
      pos = std + cbStd;
      if (cbStd == 0) continue;
      final w2 = tu16(std + 2);
      final w3 = tu16(std + 4);
      final stk = w2 & 0xF;
      final base = w2 >> 4;
      final cupx = w3 & 0xF;
      var p = std + cbStdBase;
      final cch = tu16(p);
      final name = StringBuffer();
      for (var k = 0; k < cch; k++) {
        name.writeCharCode(tu16(p + 2 + k * 2));
      }
      p += 2 + cch * 2 + 2;
      List<_Sprm> papx = const [];
      List<_Sprm> chpx = const [];
      for (var u = 0; u < cupx && p < std + cbStd; u++) {
        if ((p - std) % 2 != 0) p++;
        final cbUpx = tu16(p);
        final start = p + 2;
        if (stk == 1 && u == 0) {
          papx = _parseGrpprl(table, start + 2, start + cbUpx);
        } else if ((stk == 1 && u == 1) || (stk == 2 && u == 0)) {
          chpx = _parseGrpprl(table, start, start + cbUpx);
        }
        p = start + cbUpx;
      }
      styles[istd] = _StyleInfo(
        name.toString(),
        stk,
        base == 0xFFF ? -1 : base,
        papx,
        chpx,
      );
    }
  }

  void _readBte(int fc, int lcb, {required bool papx}) {
    if (lcb == 0 || fc + lcb > table.length) return;
    final n = (lcb - 4) ~/ 8;
    final pns = <int>[];
    for (var k = 0; k < n; k++) {
      pns.add(tu32(fc + (n + 1) * 4 + k * 4) & 0x3FFFFF);
    }
    for (final pn in pns) {
      final pageOff = pn * 512;
      if (pageOff + 512 > wd.length) continue;
      final crun = wd[pageOff + 511];
      for (var r = 0; r < crun; r++) {
        final fcStart = u32(pageOff + r * 4);
        final fcEnd = u32(pageOff + (r + 1) * 4);
        if (papx) {
          final bx = pageOff + (crun + 1) * 4 + r * 13;
          final bOff = wd[bx] * 2;
          if (bOff == 0) {
            papxRuns.add(_FcRun(fcStart, fcEnd, const []));
            continue;
          }
          var o = pageOff + bOff;
          var cb = wd[o];
          int size;
          if (cb == 0) {
            cb = wd[o + 1];
            size = cb * 2;
            o += 2;
          } else {
            size = cb * 2 - 1;
            o += 1;
          }
          final istd = u16(o);
          papxRuns.add(
            _FcRun(fcStart, fcEnd, _parseGrpprl(wd, o + 2, o + size), istd),
          );
        } else {
          final bOff = wd[pageOff + (crun + 1) * 4 + r] * 2;
          if (bOff == 0) {
            chpxRuns.add(_FcRun(fcStart, fcEnd, const []));
            continue;
          }
          final o = pageOff + bOff;
          final cb = wd[o];
          chpxRuns.add(
            _FcRun(fcStart, fcEnd, _parseGrpprl(wd, o + 1, o + 1 + cb)),
          );
        }
      }
    }
    final list = papx ? papxRuns : chpxRuns;
    list.sort((a, b) => a.start.compareTo(b.start));
  }

  void _readLists(int fcLst, int lcbLst, int fcLfo, int lcbLfo) {
    if (lcbLst < 2 || fcLst + lcbLst > table.length) return;
    // Counts are clamped to what the structures can actually hold.
    final cLst = tb
        .getInt16(fcLst, Endian.little)
        .clamp(0, math.max(0, (lcbLst - 2) ~/ 28));
    final lstIds = <int>[];
    final simple = <bool>[];
    var pos = fcLst + 2;
    for (var i = 0; i < cLst; i++) {
      lstIds.add(ti32(pos));
      simple.add((table[pos + 26] & 1) != 0);
      pos += 28;
    }
    for (var i = 0; i < cLst; i++) {
      final count = simple[i] ? 1 : 9;
      final levels = <_LvlInfo>[];
      for (var l = 0; l < count; l++) {
        if (pos + 28 > table.length) return;
        final start = ti32(pos);
        final nfc = table[pos + 4];
        final cbChpx = table[pos + 24];
        final cbPapx = table[pos + 25];
        final papxStart = pos + 28;
        final papx = _parseGrpprl(table, papxStart, papxStart + cbPapx);
        var p = papxStart + cbPapx + cbChpx;
        final cch = tu16(p);
        final sb = StringBuffer();
        for (var k = 0; k < cch; k++) {
          sb.writeCharCode(tu16(p + 2 + k * 2));
        }
        p += 2 + cch * 2;
        levels.add(_LvlInfo(start, nfc, sb.toString(), papx));
        pos = p;
      }
      lists[lstIds[i]] = levels;
    }
    if (lcbLfo < 4 || fcLfo + lcbLfo > table.length) return;
    final lfoMac = ti32(fcLfo).clamp(0, (lcbLfo - 4) ~/ 16);
    for (var i = 0; i < lfoMac; i++) {
      lfoLsid.add(ti32(fcLfo + 4 + i * 16));
    }
  }

  void _readSections(int fc, int lcb) {
    if (lcb == 0 || fc + lcb > table.length) return;
    final n = (lcb - 4) ~/ 16;
    if (n <= 0) return;
    final sed = fc + (n + 1) * 4 + (n - 1) * 12;
    final fcSepx = ti32(sed + 2);
    if (fcSepx <= 0 || fcSepx + 2 > wd.length) return;
    final cb = u16(fcSepx);
    double w = 612, h = 792, ml = 90, mr = 90, mt = 72, mb = 72;
    for (final s in _parseGrpprl(wd, fcSepx + 2, fcSepx + 2 + cb)) {
      switch (s.op) {
        case 0xB01F:
          w = s.u16 / 20;
        case 0xB020:
          h = s.u16 / 20;
        case 0xB021:
          ml = s.u16 / 20;
        case 0xB022:
          mr = s.u16 / 20;
        case 0x9023:
          mt = s.i16.abs() / 20;
        case 0x9024:
          mb = s.i16.abs() / 20;
      }
    }
    if (w > 72 && h > 72) {
      page = DocPageSetup(
        width: w,
        height: h,
        marginLeft: ml,
        marginRight: mr,
        marginTop: mt,
        marginBottom: mb,
      );
    }
  }

  // -------------------------------------------------------------------------

  List<_Sprm> _papxAt(int fc, [List<int>? istdOut]) {
    final runs = papxRuns;
    var lo = 0, hi = runs.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final r = runs[mid];
      if (fc < r.start) {
        hi = mid - 1;
      } else if (fc >= r.end) {
        lo = mid + 1;
      } else {
        istdOut?.add(r.istd);
        return r.sprms;
      }
    }
    return const [];
  }

  _FcRun? _chpxRunAt(int fc) {
    final runs = chpxRuns;
    var lo = 0, hi = runs.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final r = runs[mid];
      if (fc < r.start) {
        hi = mid - 1;
      } else if (fc >= r.end) {
        lo = mid + 1;
      } else {
        return r;
      }
    }
    return null;
  }

  void _applyPara(_ParaProps p, List<_Sprm> sprms) {
    for (final s in sprms) {
      switch (s.op) {
        case 0x4600:
          p.istd = s.u16;
        case 0x2403:
        case 0x2461:
          p.align = switch (s.u8) {
            1 => DocAlign.center,
            2 => DocAlign.right,
            3 || 4 || 5 => DocAlign.justify,
            _ => DocAlign.left,
          };
        case 0x2405:
          break;
        case 0x2406:
          p.keepNext = s.u8 != 0;
        case 0x2407:
          p.pageBreakBefore = s.u8 != 0;
        case 0x260A:
          p.ilvl = s.u8;
        case 0x460B:
          p.ilfo = s.u16;
        case 0x840E:
        case 0x845D:
          p.right = s.i16 / 20;
        case 0x840F:
        case 0x845E:
          p.left = s.i16 / 20;
        case 0x8411:
        case 0x8460:
          p.first = s.i16 / 20;
        case 0x6412:
          if (s.data.length >= 4) {
            final dya = ByteData.sublistView(s.data).getInt16(0, Endian.little);
            final mult = ByteData.sublistView(
              s.data,
            ).getInt16(2, Endian.little);
            if (mult == 1) {
              p.line = (dya / 240).clamp(0.5, 5.0);
              p.exact = null;
            } else if (dya < 0) {
              p.exact = -dya / 20;
            } else if (dya / 20 > 16) {
              p.exact = dya / 20;
            }
          }
        case 0xA413:
          p.before = s.u16 / 20;
        case 0xA414:
          p.after = s.u16 / 20;
        case 0x2416:
          p.inTable = s.u8 != 0;
        case 0x2417:
          p.ttp = s.u8 != 0;
        case 0x6649:
          p.itap = s.i32;
        case 0x2640:
          p.outline = s.u8;
        case 0x2441:
          p.bidi = s.u8 != 0;
        case 0xD608:
          if (s.data.isNotEmpty) {
            final itcMac = s.data[0];
            final edges = <double>[];
            final b = ByteData.sublistView(s.data);
            for (
              var k = 0;
              k <= itcMac && 1 + k * 2 + 2 <= s.data.length;
              k++
            ) {
              edges.add(b.getInt16(1 + k * 2, Endian.little) / 20);
            }
            p.cellEdges = edges;
          }
      }
    }
  }

  bool _toggle(int operand, bool styleValue) {
    switch (operand) {
      case 0:
        return false;
      case 1:
        return true;
      case 0x80:
        return styleValue;
      case 0x81:
        return !styleValue;
      default:
        return operand != 0;
    }
  }

  void _applyChar(_CharProps c, List<_Sprm> sprms, _CharProps style) {
    for (final s in sprms) {
      switch (s.op) {
        case 0x0835:
          c.bold = _toggle(s.u8, style.bold);
        case 0x0836:
          c.italic = _toggle(s.u8, style.italic);
        case 0x0837:
        case 0x2A53:
          c.strike = _toggle(s.u8, style.strike);
        case 0x083A:
          c.smallCaps = _toggle(s.u8, style.smallCaps);
        case 0x083B:
          c.caps = _toggle(s.u8, style.caps);
        case 0x083C:
          c.vanish = _toggle(s.u8, style.vanish);
        case 0x0800:
          c.deleted = s.u8 != 0;
        case 0x2A3E:
          c.underline = s.u8 != 0;
        case 0x2A42:
          final ico = s.u8;
          c.color = ico < _icoColors.length ? _icoColors[ico] : null;
        case 0x6870:
          if (s.data.length >= 4) {
            if (s.data[3] == 0xFF) {
              c.color = null;
            } else {
              c.color =
                  0xFF000000 | (s.data[0] << 16) | (s.data[1] << 8) | s.data[2];
            }
          }
        case 0x4A43:
          if (s.u16 > 0) c.size = s.u16 / 2;
        case 0x2A48:
          c.iss = s.u8;
        case 0x2A0C:
          final ico = s.u8;
          c.highlight = ico > 0 && ico < _icoColors.length
              ? _icoColors[ico]
              : null;
        case 0x4A4F:
          c.font = s.u16;
        case 0x0855:
          c.special = s.u8 != 0;
        case 0x6A03:
          c.picLocation = s.i32;
        case 0x2A33:
          final keep = c.picLocation;
          c
            ..bold = style.bold
            ..italic = style.italic
            ..underline = style.underline
            ..strike = style.strike
            ..color = style.color
            ..size = style.size
            ..iss = 0;
          c.picLocation = keep;
      }
    }
  }

  final Map<int, _CharProps> _styleCharCache = {};
  final Map<int, _ParaProps> _styleParaCache = {};

  _CharProps _styleChar(int istd, [int depth = 0]) {
    final cached = _styleCharCache[istd];
    if (cached != null) return cached;
    final st = styles[istd];
    _CharProps c;
    if (st == null || depth > 10) {
      c = _CharProps();
    } else {
      c =
          (st.base >= 0 && st.base != istd
                  ? _styleChar(st.base, depth + 1)
                  : _CharProps())
              .copy();
      _applyChar(c, st.chpx, c.copy());
    }
    _styleCharCache[istd] = c;
    return c;
  }

  _ParaProps _stylePara(int istd, [int depth = 0]) {
    final cached = _styleParaCache[istd];
    if (cached != null) return cached;
    final st = styles[istd];
    final p = _ParaProps();
    if (st != null && depth <= 10) {
      if (st.base >= 0 && st.base != istd) {
        final b = _stylePara(st.base, depth + 1);
        p
          ..align = b.align
          ..left = b.left
          ..right = b.right
          ..first = b.first
          ..before = b.before
          ..after = b.after
          ..line = b.line
          ..exact = b.exact
          ..keepNext = b.keepNext
          ..outline = b.outline
          ..ilfo = b.ilfo
          ..ilvl = b.ilvl;
      }
      _applyPara(p, st.papx);
    }
    p.istd = istd;
    _styleParaCache[istd] = p;
    return p;
  }

  int? _headingOf(int istd, _ParaProps p) {
    final name = (styles[istd]?.name ?? '').toLowerCase();
    final m = RegExp(r'^heading\s*([1-9])').firstMatch(name);
    if (m != null) return int.parse(m.group(1)!).clamp(1, 6);
    if (istd >= 1 && istd <= 9 && styles[istd] == null) return istd.clamp(1, 6);
    final ol = p.outline;
    if (ol != null && ol < 9) return (ol + 1).clamp(1, 6);
    return null;
  }

  DocRunStyle _runStyle(_CharProps c) {
    final fontName = c.font >= 0 && c.font < fonts.length
        ? fonts[c.font]
        : null;
    return DocRunStyle(
      bold: c.bold,
      italic: c.italic,
      underline: c.underline,
      strike: c.strike,
      allCaps: c.caps,
      smallCaps: c.smallCaps,
      color: c.color,
      highlight: c.highlight,
      fontSize: c.size,
      fontFamily: fontName == null || fontName.isEmpty ? null : fontName,
      vertAlign: c.iss == 1
          ? DocVertAlign.superscript
          : c.iss == 2
          ? DocVertAlign.subscript
          : DocVertAlign.baseline,
    );
  }

  // -------------------------------------------------------------------------

  DocModel _build(String text, int ccpText) {
    final blocks = <DocBlock>[];
    final listCounters = <int, List<int>>{};
    var paraStart = 0;

    // Table assembly.
    DocTable? table;
    DocTableRow? row;
    var cellBlocks = <DocBlock>[];

    // Field state.
    final fieldStack =
        <List<Object>>[]; // [inResult(bool), instr(StringBuffer)]

    void flushTable() {
      if (table != null) {
        if (row != null && row!.cells.isNotEmpty) table!.rows.add(row!);
        if (table!.rows.isNotEmpty) blocks.add(table!);
      }
      table = null;
      row = null;
      cellBlocks = <DocBlock>[];
    }

    for (var cp = 0; cp <= text.length; cp++) {
      final atEnd = cp == text.length;
      final ch = atEnd ? 0x0D : text.codeUnitAt(cp);
      if (ch != 0x0D && ch != 0x07 && !(ch == 0x0C)) continue;
      if (atEnd && paraStart >= text.length) break;

      final markFc = atEnd ? -1 : _fcOf(cp);
      final istdOut = <int>[];
      final sprms = markFc < 0 ? const <_Sprm>[] : _papxAt(markFc, istdOut);
      final istd = istdOut.isEmpty ? 0 : istdOut.first;
      final base = _stylePara(istd);
      final pp = _ParaProps()
        ..align = base.align
        ..left = base.left
        ..right = base.right
        ..first = base.first
        ..before = base.before
        ..after = base.after
        ..line = base.line
        ..exact = base.exact
        ..keepNext = base.keepNext
        ..outline = base.outline
        ..ilfo = base.ilfo
        ..ilvl = base.ilvl
        ..istd = istd;
      _applyPara(pp, sprms);

      final para = _paragraph(
        text,
        paraStart,
        cp,
        pp,
        fieldStack,
        listCounters,
      );
      paraStart = cp + 1;

      if (pp.inTable || ch == 0x07) {
        if (pp.ttp) {
          // Row end mark.
          table ??= DocTable();
          if (row != null) {
            final edges = pp.cellEdges;
            if (edges != null && edges.length == row!.cells.length + 1) {
              for (var k = 0; k < row!.cells.length; k++) {
                row!.cells[k].width = edges[k + 1] - edges[k];
              }
              if (table!.columnWidths.isEmpty ||
                  table!.columnWidths.length < row!.cells.length) {
                table!.columnWidths = [
                  for (var k = 0; k < row!.cells.length; k++)
                    (edges[k + 1] - edges[k]).abs(),
                ];
              }
            }
            table!.rows.add(row!);
          }
          row = null;
          cellBlocks = <DocBlock>[];
          continue;
        }
        table ??= DocTable();
        row ??= DocTableRow();
        if (para != null) cellBlocks.addAll(para);
        if (ch == 0x07) {
          row!.cells.add(DocTableCell(blocks: cellBlocks));
          cellBlocks = <DocBlock>[];
        }
        continue;
      }
      if (table != null) flushTable();
      if (pp.pageBreakBefore) blocks.add(DocPageBreak(joinNext: true));
      if (para != null) blocks.addAll(para);
      // A page break character; the paragraph's text continues after it.
      if (ch == 0x0C) blocks.add(DocPageBreak(joinNext: true));
      final preview = onPreview;
      if (preview != null &&
          !_previewSent &&
          table == null &&
          blocks.length >= 60) {
        _previewSent = true;
        // Only worth it when a good part of the text is still to come.
        if (text.length - cp > 20000) {
          preview(_model(List.of(blocks), Map.of(images)));
        }
      }
    }
    flushTable();
    // Column widths must match the widest row.
    for (final b in blocks) {
      if (b is DocTable) {
        var max = 0;
        for (final r in b.rows) {
          if (r.cells.length > max) max = r.cells.length;
        }
        if (b.columnWidths.length != max) b.columnWidths = [];
      }
    }
    return _model(blocks, images);
  }

  bool _previewSent = false;

  DocModel _model(List<DocBlock> blocks, Map<String, DocImageData> images) {
    final normal = _runStyle(_styleChar(0));
    final headings = <int, DocRunStyle>{};
    for (var l = 1; l <= 6; l++) {
      final st = styles[l];
      if (st != null && st.name.toLowerCase().startsWith('heading')) {
        headings[l] = _runStyle(_styleChar(l));
      }
    }
    final defaults = DocModel.defaultHeadingStyles(normal);
    for (var l = 1; l <= 6; l++) {
      headings.putIfAbsent(l, () => defaults[l]!);
    }
    return DocModel(
      format: format,
      blocks: blocks.isEmpty ? [DocParagraph()] : blocks,
      images: images,
      page: page,
      baseStyle: normal,
      headingStyles: headings,
    );
  }

  /// Builds a paragraph from text [start, end); returns null for nothing.
  List<DocBlock>? _paragraph(
    String text,
    int start,
    int end,
    _ParaProps pp,
    List<List<Object>> fields,
    Map<int, List<int>> counters,
  ) {
    final styleChar = _styleChar(pp.istd);
    final inlines = <DocInline>[];
    String? link;
    var lastRun = -1;
    _FcRun? run;
    _CharProps props = styleChar;
    _CharProps? styleOf;
    var style = DocRunStyle.plain;

    // Text of the current run; appending to DocText.text per character
    // would be quadratic in the paragraph length.
    final buf = StringBuffer();
    DocRunStyle? bufStyle;
    String? bufLink;
    void flush() {
      if (buf.isEmpty) return;
      inlines.add(DocText(buf.toString(), bufStyle!, link: bufLink));
      buf.clear();
    }

    for (var cp = start; cp < end; cp++) {
      final ch = text.codeUnitAt(cp);
      final fc = _fcOf(cp);
      if (fc >= 0 && (run == null || fc < run.start || fc >= run.end)) {
        run = _chpxRunAt(fc);
        final idx = run == null ? -1 : run.start;
        if (idx != lastRun) {
          lastRun = idx;
          props = styleChar.copy();
          if (run != null) _applyChar(props, run.sprms, styleChar);
        }
      }
      // Fields.
      if (ch == 0x13) {
        fields.add([false, StringBuffer()]);
        continue;
      }
      if (ch == 0x14) {
        if (fields.isNotEmpty) {
          fields.last[0] = true;
          final instr = (fields.last[1] as StringBuffer).toString().trim();
          if (instr.toUpperCase().startsWith('HYPERLINK')) {
            final m = RegExp(r'"([^"]*)"').firstMatch(instr);
            final anchor = RegExp(r'\\l\s+"([^"]*)"').firstMatch(instr);
            link = m != null && anchor == null
                ? m.group(1)
                : (anchor != null ? '#${anchor.group(1)}' : null);
          }
        }
        continue;
      }
      if (ch == 0x15) {
        if (fields.isNotEmpty) fields.removeLast();
        if (!fields.any((f) => f[0] == true)) link = null;
        continue;
      }
      if (fields.isNotEmpty && fields.last[0] == false) {
        (fields.last[1] as StringBuffer).writeCharCode(ch);
        continue;
      }
      if (props.deleted || props.vanish) continue;

      if (!identical(props, styleOf)) {
        style = _runStyle(props);
        styleOf = props;
      }
      String? out;
      switch (ch) {
        case 0x01:
          if (props.special && props.picLocation >= 0) {
            final img = _picture(props.picLocation);
            if (img != null) {
              flush();
              inlines.add(img);
            }
          }
          continue;
        case 0x08:
        case 0x05:
        case 0x03:
        case 0x04:
        case 0x00:
        case 0x1F:
        case 0x0E:
          continue;
        case 0x02:
          _footnote++;
          flush();
          inlines.add(
            DocObject(
              kind: 'Footnote',
              displayText: '$_footnote',
              style: style.copyWith(vertAlign: DocVertAlign.superscript),
            ),
          );
          continue;
        case 0x0B:
          out = '\n';
        case 0x1E:
          out = '\u2011';
        case 0x09:
          out = '\t';
        case 0xA0:
          out = '\u00A0';
        default:
          if (props.special && ch == 0x28) {
            // Symbol with sprmCSymbol; best effort.
            out = mapSymbolChar(0xF0B7, null);
          } else if (ch < 0x20) {
            continue;
          } else {
            out = String.fromCharCode(ch);
          }
      }
      if (buf.isNotEmpty && (bufStyle != style || bufLink != link)) flush();
      if (buf.isEmpty) {
        bufStyle = style;
        bufLink = link;
      }
      buf.write(out);
    }
    flush();

    final heading = _headingOf(pp.istd, pp);
    DocListInfo? list;
    if (pp.ilfo > 0 && pp.ilfo <= lfoLsid.length) {
      final levels = lists[lfoLsid[pp.ilfo - 1]];
      final lvl = levels == null || levels.isEmpty
          ? null
          : levels[pp.ilvl.clamp(0, levels.length - 1)];
      final c = counters.putIfAbsent(pp.ilfo, () => List.filled(9, 0));
      final level = pp.ilvl.clamp(0, 8);
      if (lvl != null) {
        if (lvl.papx.isNotEmpty) {
          final lp = _ParaProps();
          _applyPara(lp, lvl.papx);
          if (lp.left != 0) pp.left = lp.left;
          if (lp.first != 0) pp.first = lp.first;
        }
        c[level] = c[level] == 0 ? lvl.start : c[level] + 1;
        for (var k = level + 1; k < 9; k++) {
          c[k] = 0;
        }
        final bullet = lvl.nfc == 23;
        String label;
        if (bullet) {
          label = lvl.text.isEmpty
              ? '\u2022'
              : mapSymbolChar(lvl.text.codeUnitAt(0), 'Symbol');
          if (lvl.text == 'o') label = '\u25E6';
        } else {
          final sb = StringBuffer();
          for (final u in lvl.text.codeUnits) {
            if (u < 9) {
              final lv = levels![u.clamp(0, levels.length - 1)];
              sb.write(
                formatListNumber(c[u] == 0 ? lv.start : c[u], _nfcName(lv.nfc)),
              );
            } else {
              sb.writeCharCode(u);
            }
          }
          label = sb.toString();
        }
        list = DocListInfo(
          ordered: !bullet,
          level: level,
          format: bullet ? 'bullet' : _nfcName(lvl.nfc),
          label: label,
        );
      } else {
        list = DocListInfo(
          ordered: false,
          level: level,
          label: '\u2022',
          format: 'bullet',
        );
      }
    }

    final markStyle = _runStyle(styleChar);
    final p = DocParagraph(
      inlines: inlines,
      headingLevel: heading,
      styleId: styles[pp.istd]?.name,
      align: pp.align,
      indentLeft: pp.left,
      indentRight: pp.right,
      firstLine: pp.first,
      spaceBefore: pp.before,
      spaceAfter: pp.after,
      lineSpacing: pp.line,
      lineExact: pp.exact,
      list: list,
      keepNext: pp.keepNext,
      rtl: pp.bidi,
      markStyle: markStyle,
    );
    return [p];
  }

  String _nfcName(int nfc) => switch (nfc) {
    1 => 'upperRoman',
    2 => 'lowerRoman',
    3 => 'upperLetter',
    4 => 'lowerLetter',
    5 => 'ordinal',
    22 => 'decimalZero',
    23 => 'bullet',
    255 => 'none',
    _ => 'decimal',
  };

  DocImage? _picture(int offset) {
    final d = data;
    if (d == null || offset < 0 || offset + 0x44 > d.length) return null;
    final b = ByteData.sublistView(d);
    final lcb = b.getInt32(offset, Endian.little);
    if (lcb <= 0x44 || offset + lcb > d.length) return null;
    final dxaGoal = b.getInt16(offset + 0x1C, Endian.little);
    final dyaGoal = b.getInt16(offset + 0x1E, Endian.little);
    final mx = b.getUint16(offset + 0x20, Endian.little);
    final my = b.getUint16(offset + 0x22, Endian.little);
    final end = offset + lcb;
    Uint8List? img;
    for (var i = offset + 0x44; i + 8 < end; i++) {
      if (d[i] == 0x89 &&
          d[i + 1] == 0x50 &&
          d[i + 2] == 0x4E &&
          d[i + 3] == 0x47) {
        // PNG: until IEND.
        for (var j = i + 8; j + 8 <= end; j++) {
          if (d[j] == 0x49 &&
              d[j + 1] == 0x45 &&
              d[j + 2] == 0x4E &&
              d[j + 3] == 0x44) {
            img = Uint8List.fromList(Uint8List.sublistView(d, i, j + 8));
            break;
          }
        }
        break;
      }
      if (d[i] == 0xFF && d[i + 1] == 0xD8 && d[i + 2] == 0xFF) {
        var last = -1;
        for (var j = end - 2; j > i; j--) {
          if (d[j] == 0xFF && d[j + 1] == 0xD9) {
            last = j;
            break;
          }
        }
        if (last > i) {
          img = Uint8List.fromList(Uint8List.sublistView(d, i, last + 2));
        }
        break;
      }
    }
    if (img == null) return null;
    final id = 'doc_image_${_imageNo++}';
    images[id] = loadImageData(img, '$id.bin');
    var w = dxaGoal * (mx == 0 ? 1000 : mx) / 1000 / 20;
    var h = dyaGoal * (my == 0 ? 1000 : my) / 1000 / 20;
    if (w <= 0 || h <= 0) {
      w = 0;
      h = 0;
    }
    return DocImage(imageId: id, width: w, height: h);
  }
}
