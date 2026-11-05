import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/exif_bytes.dart';
import 'package:image/image.dart' as img;

/// The header of a PostScript / EPS file: DSC comments and where its
/// embedded previews are. Handles plain PostScript, DOS EPS (binary header
/// with TIFF/WMF previews), EPSI and Photoshop EPS thumbnails.
class PostScriptInfo {
  PostScriptInfo._(this.psStart, this.psLength);

  /// Where the PostScript text starts (after a DOS EPS header) and its
  /// length.
  final int psStart;
  final int psLength;

  int? _tiffOffset, _tiffLength, _wmfLength;

  /// PostScript and EPSF versions from the first line.
  String? psVersion, epsfVersion;
  bool isIllustrator = false;
  final Map<String, String> details = {};

  int? _epsiAt;
  int? _photoshopAt;

  bool get hasWmfPreview => (_wmfLength ?? 0) > 0;

  static PostScriptInfo read(RandomBytes src) {
    final head = src.read(0, 32);
    PostScriptInfo info;
    if (head.length >= 30 &&
        head[0] == 0xC5 &&
        head[1] == 0xD0 &&
        head[2] == 0xD3 &&
        head[3] == 0xC6) {
      final d = ByteData.sublistView(head);
      info = PostScriptInfo._(
        d.getUint32(4, Endian.little),
        d.getUint32(8, Endian.little),
      );
      final wmfLength = d.getUint32(16, Endian.little);
      final tiffOffset = d.getUint32(20, Endian.little);
      final tiffLength = d.getUint32(24, Endian.little);
      if (tiffOffset > 0 && tiffLength > 0) {
        info._tiffOffset = tiffOffset;
        info._tiffLength = tiffLength;
      }
      info._wmfLength = wmfLength;
      info.details['Binary header'] = tiffLength > 0
          ? 'DOS EPS with TIFF preview'
          : wmfLength > 0
              ? 'DOS EPS with WMF preview'
              : 'DOS EPS';
    } else {
      info = PostScriptInfo._(0, src.length);
    }
    info._parseComments(src);
    return info;
  }

  void _parseComments(RandomBytes src) {
    final headLength = math.min(psLength, 512 * 1024);
    final text = latin1.decode(src.read(psStart, headLength));
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return;
    final first = RegExp(r'%!PS-Adobe-([\d.]+)(?:\s+EPSF-([\d.]+))?')
        .firstMatch(lines.first);
    psVersion = first?[1];
    epsfVersion = first?[2];
    if (psVersion != null) {
      details['PostScript'] =
          'Adobe-$psVersion${epsfVersion != null ? ' (EPSF-$epsfVersion)' : ''}';
    }

    final dsc = <String, String>{};
    String? lastKey;
    final fonts = <String>[];
    for (var i = 1; i < lines.length && i < 4000; i++) {
      final line = lines[i];
      if (line.startsWith('%%EndComments')) break;
      if (!line.startsWith('%')) break;
      if (line.startsWith('%%+')) {
        final more = line.substring(3).trim();
        if (lastKey == 'DocumentNeededResources' ||
            lastKey == 'DocumentFonts') {
          fonts.add(more.replaceFirst(RegExp(r'^font\s+'), ''));
        }
        continue;
      }
      final m = RegExp(r'^%%([A-Za-z0-9_]+):\s*(.*)$').firstMatch(line);
      if (m != null) {
        lastKey = m[1]!;
        dsc.putIfAbsent(lastKey, () => m[2]!.trim());
        if (lastKey == 'DocumentNeededResources' || lastKey == 'DocumentFonts') {
          final v = m[2]!.trim();
          if (v.isNotEmpty && v != '(atend)') {
            fonts.add(v.replaceFirst(RegExp(r'^font\s+'), ''));
          }
        }
        continue;
      }
      final ai = RegExp(r'^%AI5_FileFormat\s+([\d.]+)').firstMatch(line);
      if (ai != null) {
        isIllustrator = true;
        details.putIfAbsent('Illustrator file format', () => ai[1]!);
      }
    }
    // (atend) values are in the trailer.
    if (dsc.values.any((v) => v == '(atend)')) {
      final tailLength = math.min(psLength, 64 * 1024);
      final tail = latin1
          .decode(src.read(psStart + psLength - tailLength, tailLength));
      for (final m
          in RegExp(r'^%%([A-Za-z]+):\s*(.*)$', multiLine: true).allMatches(tail)) {
        if (dsc[m[1]!] == '(atend)') dsc[m[1]!] = m[2]!.trim();
      }
    }

    String? clean(String? v) {
      if (v == null) return null;
      var s = v.trim();
      if (s.startsWith('(') && s.endsWith(')')) {
        // DSC text values: "(a) (b)" → "a b".
        s = s
            .substring(1, s.length - 1)
            .replaceAll(RegExp(r'\)\s*\('), ' ');
      }
      s = s.replaceAll(r'\(', '(').replaceAll(r'\)', ')');
      return s.isEmpty || s == '(atend)' ? null : s;
    }

    void put(String label, String? v) {
      final c = clean(v);
      if (c != null) details[label] = c;
    }

    put('Title', dsc['Title']);
    put('Created with', dsc['Creator']);
    put('Created', dsc['CreationDate']);
    put('Author', dsc['For']);
    final creator = dsc['Creator'] ?? '';
    if (creator.contains('Illustrator')) isIllustrator = true;
    final aiVersion = RegExp(r'^%%AI8_CreatorVersion:\s*(.+)$', multiLine: true)
        .firstMatch(text);
    if (aiVersion != null) {
      isIllustrator = true;
      details['Illustrator version'] = aiVersion[1]!.trim();
    }
    final hiRes = _box(dsc['HiResBoundingBox']);
    final box = hiRes ?? _box(dsc['BoundingBox']);
    if (dsc['BoundingBox'] != null && clean(dsc['BoundingBox']) != null) {
      details['Bounding box'] = clean(dsc['BoundingBox'])!;
    }
    if (box != null) {
      details['Artwork size'] =
          describePoints(box[2] - box[0], box[3] - box[1]);
    }
    put('Pages', dsc['Pages']);
    put('Orientation', dsc['Orientation']);
    put('PostScript level', dsc['LanguageLevel']);
    put('Data encoding', dsc['DocumentData']);
    if (fonts.isNotEmpty) {
      final unique = fonts.toSet().toList();
      details['Fonts'] = unique.length <= 6
          ? unique.join(', ')
          : '${unique.take(6).join(', ')} and ${unique.length - 6} more';
    }

    final epsi = text.indexOf('%%BeginPreview:');
    if (epsi >= 0) _epsiAt = psStart + epsi;
    final photoshop = text.indexOf('%BeginPhotoshop:');
    if (photoshop >= 0) _photoshopAt = psStart + photoshop;
  }

  static List<double>? _box(String? v) {
    if (v == null) return null;
    final parts = v.trim().split(RegExp(r'\s+'));
    if (parts.length != 4) return null;
    final nums = parts.map(double.tryParse).toList();
    if (nums.any((n) => n == null)) return null;
    final b = nums.cast<double>();
    if (b[2] <= b[0] || b[3] <= b[1]) return null;
    return b;
  }

  /// "612 × 792 pt (8.5 × 11 in, 215.9 × 279.4 mm)".
  static String describePoints(double w, double h) {
    String n(double v, int digits) {
      final s = v.toStringAsFixed(digits);
      return s.contains('.')
          ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
          : s;
    }

    return '${n(w, 1)} × ${n(h, 1)} pt '
        '(${n(w / 72, 2)} × ${n(h / 72, 2)} in, '
        '${n(w / 72 * 25.4, 1)} × ${n(h / 72 * 25.4, 1)} mm)';
  }

  /// The TIFF preview of a DOS EPS file (raw TIFF bytes).
  Uint8List? tiffPreview(RandomBytes src) {
    final at = _tiffOffset, len = _tiffLength;
    if (at == null || len == null || len > (64 << 20)) return null;
    final bytes = src.read(at, len);
    return bytes.length == len ? Uint8List.fromList(bytes) : null;
  }

  /// The JPEG thumbnail inside a Photoshop EPS `%BeginPhotoshop` block.
  Uint8List? photoshopThumbnail(RandomBytes src) {
    final at = _photoshopAt;
    if (at == null) return null;
    final header = latin1.decode(src.read(at, 64));
    final size = int.tryParse(
        RegExp(r'%BeginPhotoshop:\s*(\d+)').firstMatch(header)?[1] ?? '');
    if (size == null || size <= 0 || size > (16 << 20)) return null;
    // Hex text: two characters per byte plus "% " and a newline per line.
    final text = latin1.decode(src.read(at, size * 3 + 4096));
    final data = _hex(_body(text, '%EndPhotoshop').replaceAll('%', ''));
    final soi = indexOfBytes(data, const [0xFF, 0xD8, 0xFF]);
    if (soi < 0) return null;
    final eoi = lastIndexOfBytes(data, const [0xFF, 0xD9]);
    if (eoi <= soi) return null;
    return Uint8List.sublistView(data, soi, eoi + 2);
  }

  /// The EPSI `%%BeginPreview` bitmap, as PNG.
  Uint8List? epsiPreview(RandomBytes src) {
    final at = _epsiAt;
    if (at == null) return null;
    final header = latin1.decode(src.read(at, 128));
    final m = RegExp(r'%%BeginPreview:\s*(\d+)\s+(\d+)\s+(\d+)')
        .firstMatch(header);
    if (m == null) return null;
    final w = int.parse(m[1]!), h = int.parse(m[2]!), depth = int.parse(m[3]!);
    if (w <= 0 || h <= 0 || w * h > 16 << 20 || !const {1, 2, 4, 8}.contains(depth)) {
      return null;
    }
    final rowBytes = (w * depth + 7) ~/ 8;
    final need = rowBytes * h;
    final text = latin1.decode(src.read(at, need * 3 + h * 4 + 4096));
    final data = _hex(_body(text, '%%EndPreview').replaceAll('%', ''));
    if (data.length < need) return null;
    final image = img.Image(width: w, height: h, numChannels: 1);
    final max = (1 << depth) - 1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final bit = x * depth;
        final byte = data[y * rowBytes + (bit >> 3)];
        final shift = 8 - depth - (bit & 7);
        final v = (byte >> shift) & max;
        // EPSI: 0 is white.
        final g = 255 - (v * 255 ~/ max);
        image.setPixelRgb(x, y, g, g, g);
      }
    }
    return img.encodePng(image);
  }

  /// The lines after the first one of [text], up to [endMarker]. Lines may
  /// end with CR (classic Mac), LF or CRLF.
  static String _body(String text, String endMarker) {
    final start = text.indexOf(RegExp(r'[\r\n]'));
    if (start < 0) return '';
    final end = text.indexOf(endMarker, start);
    return text.substring(start + 1, end < 0 ? text.length : end);
  }

  static Uint8List _hex(String s) {
    final out = BytesBuilder(copy: false);
    int? hi;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final int v;
      if (c >= 0x30 && c <= 0x39) {
        v = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        v = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        v = c - 0x61 + 10;
      } else {
        continue;
      }
      if (hi == null) {
        hi = v;
      } else {
        out.addByte(hi << 4 | v);
        hi = null;
      }
    }
    return out.takeBytes();
  }
}
