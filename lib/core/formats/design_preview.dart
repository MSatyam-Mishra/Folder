import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folders/core/formats/design_postscript.dart';
import 'package:folders/core/formats/design_xmp.dart';
import 'package:folders/core/formats/design_zip.dart';
import 'package:folders/core/formats/exif_bytes.dart';
import 'package:folders/core/formats/exif_jpeg.dart';
import 'package:image/image.dart' as img;

/// What can be shown for a design, CAD or print file without the app that
/// made it: an embedded preview image (if any) and details.
class DesignPreview {
  const DesignPreview({
    required this.format,
    this.image,
    this.imageSource,
    this.imageWidth,
    this.imageHeight,
    this.details = const {},
    this.pdfCompatible = false,
    this.postScript = false,
    this.embeddedPdf,
    this.note,
    this.pageWidth,
    this.pageHeight,
  });

  /// e.g. "Adobe Illustrator artwork (PDF-compatible)".
  final String format;

  /// PNG, JPEG or BMP bytes Flutter can decode, or null.
  final Uint8List? image;

  /// Where [image] came from, e.g. "Embedded thumbnail (XMP)".
  final String? imageSource;
  final int? imageWidth;
  final int? imageHeight;

  /// Label → value, in display order.
  final Map<String, String> details;

  /// The file is a PDF inside (Illustrator 9+ with PDF content): it can be
  /// rendered and opened with the PDF viewer.
  final bool pdfCompatible;

  /// The file is PostScript text that can be viewed as source.
  final bool postScript;

  /// A PDF rendition stored inside the file (iWork '09 QuickLook/Preview.pdf).
  final Uint8List? embeddedPdf;

  /// Why there is no preview, or other caveats worth telling the user.
  final String? note;

  /// First page size in points, for [pdfCompatible] files, when known.
  final double? pageWidth, pageHeight;

  bool get hasImage => image != null;
}

/// Reads the previews embedded in design files. Synchronous: run it in a
/// background isolate. Reads only the parts of the file it needs.
abstract final class DesignPreviewReader {
  static DesignPreview read(String path) {
    final ext = _extension(path);
    try {
      if (FileSystemEntity.isDirectorySync(path)) {
        final dir = DesignContainer.open(path);
        if (dir == null) return DesignPreview(format: formatName(ext));
        try {
          return _zipBased(dir, ext, isDirectory: true);
        } finally {
          dir.close();
        }
      }
      final src = FileRandomBytes.open(path);
      try {
        return readSource(src, ext);
      } finally {
        src.close();
      }
    } catch (e) {
      return DesignPreview(
        format: formatName(ext),
        note: "This file couldn't be read: $e",
      );
    }
  }

  static DesignPreview readSource(RandomBytes src, String ext) {
    final head = src.read(0, 64);
    if (head.isEmpty) {
      return DesignPreview(format: formatName(ext), note: 'The file is empty.');
    }
    if (_starts(head, '%PDF')) return _pdfBased(src, ext);
    if (head.length >= 4 &&
        head[0] == 0xC5 &&
        head[1] == 0xD0 &&
        head[2] == 0xD3 &&
        head[3] == 0xC6) {
      return _postScript(src, ext);
    }
    if (_starts(head, '%!')) return _postScript(src, ext);
    if (_starts(head, 'AC1') || _starts(head, 'AC2')) return _dwg(src);
    if (indexOfBytes(head, _inddGuid) == 0) return _indesign(src, ext);
    if (_starts(head, 'fig-kiwi') || _starts(head, 'fig-jam')) {
      return _figBinary(src, head);
    }
    if (_starts(head, 'RIFF') && head.length >= 12 && _ascii(head, 8, 3) == 'CDR') {
      return _cdrRiff(src, head);
    }
    if (_starts(head, 'SQLite format 3')) {
      return DesignPreview(
        format: '${formatName(ext)} (legacy database format)',
        details: const {'Format': 'Sketch 42 or earlier (SQLite)'},
        note: 'Sketch files saved before version 43 have no readable preview.',
      );
    }
    if (head.length >= 4 &&
        head[0] == 0x00 &&
        head[1] == 0xFF &&
        head[2] == 0x4B &&
        head[3] == 0x41) {
      return _affinity(src, ext);
    }
    if (_starts(head, 'PK')) {
      final zip = ZipContainer.parse(src);
      if (zip != null) return _zipBased(zip, ext);
    }
    return _unknown(src, ext);
  }

  /// Display name for a design file extension.
  static String formatName(String ext) => switch (ext) {
        'ai' => 'Adobe Illustrator artwork',
        'eps' || 'epsf' => 'Encapsulated PostScript',
        'epsi' => 'Encapsulated PostScript (EPSI)',
        'ps' => 'PostScript document',
        'indd' => 'Adobe InDesign document',
        'indt' => 'Adobe InDesign template',
        'fig' => 'Figma design',
        'dwg' => 'AutoCAD drawing',
        'sketch' => 'Sketch document',
        'kra' => 'Krita document',
        'ora' => 'OpenRaster image',
        'procreate' => 'Procreate artwork',
        'cdr' => 'CorelDRAW drawing',
        'xd' => 'Adobe XD document',
        'afdesign' => 'Affinity Designer document',
        'afphoto' => 'Affinity Photo document',
        'afpub' => 'Affinity Publisher document',
        'pages' => 'Apple Pages document',
        'numbers' => 'Apple Numbers spreadsheet',
        _ => 'Design file',
      };

  // ------------------------------------------------------------------ PDF

  static DesignPreview _pdfBased(RandomBytes src, String ext) {
    final details = <String, String>{};
    final head = latin1.decode(src.read(0, 16));
    final version = RegExp(r'%PDF-(\d\.\d)').firstMatch(head)?[1];
    final format = ext == 'ai'
        ? 'Adobe Illustrator artwork (PDF-compatible)'
        : '${formatName(ext)} (PDF inside)';
    details['Format'] = format;
    if (version != null) details['PDF version'] = version;
    final packets = XmpPacket.findIn(
      src,
      regions: [(0, 4 << 20), (src.length - (4 << 20), 4 << 20)],
      maxScan: 64 << 20,
    );
    final thumb = _xmpDetails(packets, details);
    final size = _pdfPageSize(src);
    if (size != null) {
      details['Artboard'] = PostScriptInfo.describePoints(size.$1, size.$2);
    }
    final result = _withImage(
      format: format,
      image: thumb?.bytes,
      source: 'Embedded thumbnail (XMP)',
      details: details,
      pdfCompatible: true,
    );
    return DesignPreview(
      format: result.format,
      image: result.image,
      imageSource: result.imageSource,
      imageWidth: result.imageWidth,
      imageHeight: result.imageHeight,
      details: result.details,
      pdfCompatible: true,
      pageWidth: size?.$1,
      pageHeight: size?.$2,
    );
  }

  /// Size of the first page from its MediaBox, when it is stored
  /// uncompressed near the start (Illustrator writes it there).
  static (double, double)? _pdfPageSize(RandomBytes src) {
    final text = latin1.decode(src.read(0, 1 << 20));
    final m = RegExp(
      r'/MediaBox\s*\[\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*\]',
    ).firstMatch(text);
    if (m == null) return null;
    final w = double.parse(m[3]!) - double.parse(m[1]!);
    final h = double.parse(m[4]!) - double.parse(m[2]!);
    if (w <= 0 || h <= 0) return null;
    return (w, h);
  }

  /// Adds the common XMP fields to [details]; returns the best thumbnail.
  static XmpThumbnail? _xmpDetails(
    List<XmpPacket> packets,
    Map<String, String> details,
  ) {
    XmpThumbnail? best;
    for (final p in packets) {
      void put(String label, String? v) {
        if (v != null && v.trim().isNotEmpty) {
          details.putIfAbsent(label, () => v.trim());
        }
      }

      put('Title', p.value('dc:title'));
      put('Author', p.values('dc:creator').join(', '));
      put('Created with', p.value('xmp:CreatorTool'));
      put('Created', _xmpDate(p.value('xmp:CreateDate')));
      put('Modified', _xmpDate(p.value('xmp:ModifyDate')));
      final pages = p.value('xmpTPg:NPages');
      if (pages != null && pages != '1') put('Pages', pages);
      final w = p.value('stDim:w'), h = p.value('stDim:h');
      final unit = p.value('stDim:unit');
      if (w != null && h != null) {
        final wv = double.tryParse(w), hv = double.tryParse(h);
        if (wv != null && hv != null) {
          put('Page size', '${_num(wv)} × ${_num(hv)} ${unit?.toLowerCase() ?? ''}'.trim());
        }
      }
      final fonts = {
        ...p.values('xmpTPg:Fonts', field: 'stFnt:fontFamily'),
        ...p.values('xmpTPg:Fonts', field: 'stFnt:fontName'),
      };
      if (fonts.isNotEmpty) put('Fonts', _list(fonts));
      final plates = p.values('xmpTPg:PlateNames');
      if (plates.isNotEmpty) put('Plates', _list(plates));
      final thumbs = p.thumbnails();
      if (thumbs.isNotEmpty &&
          (best == null || thumbs.first.bytes.length > best.bytes.length)) {
        best = thumbs.first;
      }
    }
    return best;
  }

  // ----------------------------------------------------------- PostScript

  static DesignPreview _postScript(RandomBytes src, String ext) {
    final ps = PostScriptInfo.read(src);
    final details = <String, String>{};
    var format = formatName(ext);
    if (ext == 'ai' || ps.isIllustrator) {
      format = ext == 'ai'
          ? 'Adobe Illustrator artwork (PostScript)'
          : '${formatName(ext)} (from Illustrator)';
    } else if (ps.epsfVersion != null && ext == 'ps') {
      format = 'Encapsulated PostScript';
    }
    details['Format'] = format;
    details.addAll(ps.details);

    // Candidate previews: DOS EPS TIFF, Photoshop JPEG, EPSI bitmap and
    // the XMP thumbnail Illustrator writes; the largest wins.
    final images = <(Uint8List, String)>[];
    final tiff = ps.tiffPreview(src);
    if (tiff != null) images.add((tiff, 'TIFF preview'));
    final photoshop = ps.photoshopThumbnail(src);
    if (photoshop != null) images.add((photoshop, 'Photoshop thumbnail'));
    final epsi = ps.epsiPreview(src);
    if (epsi != null) images.add((epsi, 'EPSI preview'));
    final packets = XmpPacket.findIn(
      src,
      regions: [(ps.psStart, 4 << 20)],
      fullScan: false,
    );
    final xmp = _xmpDetails(packets, details);
    if (xmp != null) images.add((xmp.bytes, 'Embedded thumbnail (XMP)'));

    (Uint8List, String)? best;
    var bestPixels = -1;
    for (final candidate in images) {
      final size = imageSize(candidate.$1);
      final pixels = size == null ? 0 : size.$1 * size.$2;
      if (pixels > bestPixels) {
        best = candidate;
        bestPixels = pixels;
      }
    }
    String? note;
    if (best == null) {
      note = ps.hasWmfPreview
          ? 'The preview is a Windows Metafile, which can\'t be shown here. '
              'PostScript itself needs a PostScript interpreter to render.'
          : 'This file has no embedded preview. PostScript needs a '
              'PostScript interpreter to render; you can view its source.';
    }
    return _withImage(
      format: format,
      image: best?.$1,
      source: best?.$2,
      details: details,
      postScript: true,
      note: note,
    );
  }

  // -------------------------------------------------------------- InDesign

  static final _inddGuid = [
    0x06, 0x06, 0xED, 0xF5, 0xD8, 0x1D, 0x46, 0xE5, //
    0xBD, 0x31, 0xEF, 0xE7, 0xFE, 0x74, 0xB7, 0x1D,
  ];

  static DesignPreview _indesign(RandomBytes src, String ext) {
    final format = ext == 'indt' ? formatName('indt') : formatName('indd');
    final details = <String, String>{'Format': format};
    // InDesign appends its metadata near the end of the file.
    final packets = XmpPacket.findIn(
      src,
      regions: [(src.length - (4 << 20), 4 << 20), (0, 4 << 20)],
    );
    final thumb = _xmpDetails(packets, details);
    var pageThumbs = 0;
    for (final p in packets) {
      pageThumbs = math.max(pageThumbs, p.count('xmp:PageInfo'));
    }
    if (pageThumbs > 0) details['Page thumbnails'] = '$pageThumbs';
    return _withImage(
      format: format,
      image: thumb?.bytes,
      source: 'Embedded page thumbnail (XMP)',
      details: details,
      note: thumb == null
          ? 'This document was saved without preview images (InDesign '
              'preference "Always Save Preview Images with Documents").'
          : null,
    );
  }

  // ------------------------------------------------------------------ DWG

  static const _dwgReleases = {
    'AC1.2': 'R1.2',
    'AC1.40': 'R1.40',
    'AC1.50': 'R2.05',
    'AC2.10': 'R2.10',
    'AC1001': 'R2.22',
    'AC1002': 'R2.5',
    'AC1003': 'R2.6',
    'AC1004': 'R9',
    'AC1006': 'R10',
    'AC1009': 'R11 / R12',
    'AC1012': 'R13',
    'AC1014': 'R14',
    'AC1015': 'AutoCAD 2000 / 2000i / 2002',
    'AC1018': 'AutoCAD 2004 / 2005 / 2006',
    'AC1021': 'AutoCAD 2007 / 2008 / 2009',
    'AC1024': 'AutoCAD 2010 / 2011 / 2012',
    'AC1027': 'AutoCAD 2013 – 2017',
    'AC1032': 'AutoCAD 2018 and later',
  };

  static final _dwgSentinel = [
    0x1F, 0x25, 0x6D, 0x07, 0xD4, 0x36, 0x28, 0x28, //
    0x9D, 0x57, 0xCA, 0x3F, 0x9D, 0x44, 0x10, 0x2B,
  ];

  static DesignPreview _dwg(RandomBytes src) {
    final head = src.read(0, 32);
    var version = latin1.decode(head.sublist(0, 6)).replaceAll('\u0000', '');
    if (!_dwgReleases.containsKey(version)) {
      for (final k in _dwgReleases.keys) {
        if (version.startsWith(k)) version = k;
      }
    }
    final details = <String, String>{
      'Format': 'AutoCAD drawing (DWG)',
      'DWG version': version,
      if (_dwgReleases[version] != null) 'Saved as': _dwgReleases[version]!,
    };
    final modern = version.compareTo('AC1012') >= 0 && version.startsWith('AC10');
    if (!modern) {
      return DesignPreview(
        format: 'AutoCAD drawing',
        details: details,
        note: 'Drawings saved before AutoCAD R13 carry no preview image.',
      );
    }
    final codepage = src.u16(0x13, littleEndian: true);
    if (codepage > 0 && codepage < 100) {
      details['Code page'] = _dwgCodepage(codepage);
    }

    // The header points at the preview section; fall back to searching for
    // its sentinel.
    var at = src.u32(0x0D, littleEndian: true);
    if (at <= 0 || !src.matches(at, _dwgSentinel)) {
      at = src.indexOf(_dwgSentinel, end: math.min(src.length, 64 << 20));
    }
    Uint8List? image;
    String? source;
    String? note;
    if (at > 0) {
      final count = src.byteAt(at + 20);
      var pos = at + 21;
      final images = <int, (int, int)>{};
      for (var i = 0; i < count && i < 8; i++) {
        final code = src.byteAt(pos);
        final start = src.u32(pos + 1, littleEndian: true);
        final size = src.u32(pos + 5, littleEndian: true);
        images[code] = (start, size);
        pos += 9;
      }
      final png = images[6];
      final bmp = images[2];
      if (png != null && png.$2 > 0 && png.$2 < (32 << 20)) {
        final bytes = src.read(png.$1, png.$2);
        if (bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50) {
          image = Uint8List.fromList(bytes);
          source = 'Embedded thumbnail (PNG)';
        }
      }
      if (image == null && bmp != null && bmp.$2 > 40 && bmp.$2 < (32 << 20)) {
        image = _dibToBmp(src.read(bmp.$1, bmp.$2));
        if (image != null) source = 'Embedded thumbnail (BMP)';
      }
      if (image == null && images.containsKey(3)) {
        note = 'The drawing\'s preview is a Windows Metafile, which can\'t be '
            'shown here.';
      }
    }
    note ??= image == null ? 'This drawing has no embedded preview.' : null;
    return _withImage(
      format: 'AutoCAD drawing',
      image: image,
      source: source,
      details: details,
      note: note,
    );
  }

  static String _dwgCodepage(int cp) => switch (cp) {
        30 => 'ANSI 1252',
        29 => 'ANSI 1251',
        28 => 'ANSI 1250',
        31 => 'ANSI 1253',
        32 => 'ANSI 1254',
        38 => 'ANSI 932 (Japanese)',
        39 => 'ANSI 950 (Chinese, Traditional)',
        40 => 'ANSI 949 (Korean)',
        41 => 'ANSI 1361 (Johab)',
        42 => 'ANSI 936 (Chinese, Simplified)',
        _ => 'Code page #$cp',
      };

  /// A BMP file around a bare DIB (BITMAPINFOHEADER + palette + pixels).
  static Uint8List? _dibToBmp(Uint8List dib) {
    if (dib.length < 40) return null;
    final d = ByteData.sublistView(dib);
    final headerSize = d.getUint32(0, Endian.little);
    if (headerSize < 12 || headerSize > 124) return null;
    final bits = headerSize == 12
        ? d.getUint16(10, Endian.little)
        : d.getUint16(14, Endian.little);
    var colors = headerSize >= 40 ? d.getUint32(32, Endian.little) : 0;
    if (colors == 0 && bits <= 8) colors = 1 << bits;
    final compression = headerSize >= 40 ? d.getUint32(16, Endian.little) : 0;
    final masks = compression == 3 && headerSize == 40 ? 12 : 0;
    final paletteSize = colors * (headerSize == 12 ? 3 : 4);
    final pixelOffset = 14 + headerSize + masks + paletteSize;
    final out = Uint8List(14 + dib.length);
    final o = ByteData.sublistView(out);
    out[0] = 0x42;
    out[1] = 0x4D;
    o.setUint32(2, out.length, Endian.little);
    o.setUint32(10, pixelOffset, Endian.little);
    out.setRange(14, out.length, dib);
    return out;
  }

  // ---------------------------------------------------------- ZIP-based

  static DesignPreview _zipBased(
    DesignContainer c,
    String ext, {
    bool isDirectory = false,
  }) {
    final details = <String, String>{};
    final mimetype = c.readText('mimetype', maxSize: 256)?.trim();
    var kind = ext;
    if (mimetype == 'application/x-krita') kind = 'kra';
    if (mimetype == 'image/openraster') kind = 'ora';
    if (mimetype?.startsWith('application/vnd.adobe.sparkler') ?? false) {
      kind = 'xd';
    }
    var format = formatName(kind);
    details['Format'] = format;

    Uint8List? image;
    String? source;
    Uint8List? embeddedPdf;
    String? note;

    (Uint8List, String)? first(List<String> names, {int maxSize = 48 << 20}) {
      for (final n in names) {
        final e = c.find(n);
        if (e == null || e.isDirectory) continue;
        final bytes = c.read(e, maxSize: maxSize);
        if (bytes != null && imageSize(bytes) != null) return (bytes, n);
      }
      return null;
    }

    /// The biggest (in pixels) of [names]: a merged image can be smaller
    /// than the thumbnail when the app saved a placeholder.
    (Uint8List, String)? largest(List<String> names) {
      (Uint8List, String)? best;
      var bestPixels = -1;
      for (final n in names) {
        final hit = first([n], maxSize: 64 << 20);
        final size = hit == null ? null : imageSize(hit.$1);
        if (size != null && size.$1 * size.$2 > bestPixels) {
          best = hit;
          bestPixels = size.$1 * size.$2;
        }
      }
      return best;
    }

    switch (kind) {
      case 'fig':
        final hit = first(['thumbnail.png']);
        if (hit != null) (image, source) = (hit.$1, 'Embedded thumbnail');
        final meta = _json(c.readText('meta.json', maxSize: 1 << 20));
        if (meta is Map) {
          _put(details, 'File name', meta['file_name']);
          _put(details, 'Exported', meta['exported_at']);
          final client = meta['client_meta'];
          if (client is Map) {
            final r = client['render_coordinates'];
            if (r is Map && r['width'] is num && r['height'] is num) {
              details['Canvas area'] =
                  '${_num((r['width'] as num).toDouble())} × ${_num((r['height'] as num).toDouble())}';
            }
          }
        }
        final canvas = c.find('canvas.fig');
        if (canvas != null) {
          final h = c.readPrefix(canvas, 12);
          if (h != null && h.length >= 12 && _starts(h, 'fig-')) {
            details['Figma file version'] =
                '${ByteData.sublistView(h).getUint32(8, Endian.little)}';
          }
        }
      case 'sketch':
        final hit = first(['previews/preview.png']);
        if (hit != null) (image, source) = (hit.$1, 'Embedded preview');
        final meta = _json(c.readText('meta.json', maxSize: 8 << 20));
        if (meta is Map) {
          final pages = meta['pagesAndArtboards'];
          if (pages is Map) {
            final names = <String>[];
            var artboards = 0;
            for (final p in pages.values) {
              if (p is! Map) continue;
              if (p['name'] is String) names.add(p['name'] as String);
              final a = p['artboards'];
              if (a is Map) artboards += a.length;
            }
            details['Pages'] = '${pages.length}${names.isEmpty ? '' : ' (${_list(names)})'}';
            details['Artboards'] = '$artboards';
          }
          final app = meta['appVersion'] ?? meta['version'];
          if (app != null) details['Sketch version'] = '$app';
          final created = meta['created'];
          if (created is Map && created['appVersion'] != null) {
            details['Created with'] = 'Sketch ${created['appVersion']}';
          }
          final fonts = meta['fonts'];
          if (fonts is List && fonts.isNotEmpty) {
            details['Fonts'] = _list(fonts.map((f) => '$f'));
          }
        }
      case 'kra':
        final hit = largest(['mergedimage.png', 'preview.png']);
        if (hit != null) {
          (image, source) = (
            hit.$1,
            hit.$2 == 'mergedimage.png' ? 'Merged image' : 'Embedded thumbnail',
          );
        }
        final doc = c.readText('maindoc.xml', maxSize: 32 << 20);
        if (doc != null) {
          final imageTag = RegExp(r'<IMAGE\b[^>]*>').firstMatch(doc)?[0] ?? '';
          String? attr(String n) =>
              RegExp('\\b$n="([^"]*)"').firstMatch(imageTag)?[1];
          final w = attr('width'), h = attr('height');
          if (w != null && h != null) details['Dimensions'] = '$w × $h px';
          _put(details, 'Name', attr('name'));
          final cs = attr('colorspacename');
          if (cs != null) details['Color space'] = cs;
          final res = attr('x-res');
          if (res != null) details['Resolution'] = '${_num(double.tryParse(res) ?? 0)} ppi';
          final layers = RegExp(r'<layer\b').allMatches(doc).length;
          if (layers > 0) details['Layers'] = '$layers';
          final krita = RegExp(r'kritaVersion="([^"]*)"').firstMatch(doc)?[1];
          if (krita != null) details['Krita version'] = krita;
        }
        final info = c.readText('documentinfo.xml', maxSize: 1 << 20);
        if (info != null) {
          _put(details, 'Title', _xmlText(info, 'title'));
          _put(details, 'Author', _xmlText(info, 'full-name'));
          _put(details, 'Created', _xmlText(info, 'creation-date'));
          _put(details, 'Modified', _xmlText(info, 'date'));
        }
      case 'ora':
        final hit = largest(['mergedimage.png', 'Thumbnails/thumbnail.png']);
        if (hit != null) {
          (image, source) = (
            hit.$1,
            hit.$2 == 'mergedimage.png' ? 'Merged image' : 'Embedded thumbnail',
          );
        }
        final stack = c.readText('stack.xml', maxSize: 8 << 20);
        if (stack != null) {
          final tag = RegExp(r'<image\b[^>]*>').firstMatch(stack)?[0] ?? '';
          final w = RegExp(r'\bw="(\d+)"').firstMatch(tag)?[1];
          final h = RegExp(r'\bh="(\d+)"').firstMatch(tag)?[1];
          if (w != null && h != null) details['Dimensions'] = '$w × $h px';
          final layers = RegExp(r'<layer\b').allMatches(stack).length;
          if (layers > 0) details['Layers'] = '$layers';
        }
      case 'procreate':
        final hit = first(['QuickLook/Thumbnail.png', 'QuickLook/Thumbnail.jpg']);
        if (hit != null) (image, source) = (hit.$1, 'Embedded thumbnail');
        final archive = c.find('Document.archive');
        if (archive != null) {
          final data = c.read(archive, maxSize: 8 << 20);
          if (data != null) {
            final text = latin1.decode(data);
            final size = RegExp(r'\{(\d{2,5}), ?(\d{2,5})\}').firstMatch(text);
            if (size != null) {
              details['Canvas size'] = '${size[1]} × ${size[2]} px';
            }
          }
        }
        final layers = c.entries
            .map((e) => e.name.split('/').first)
            .where((n) => RegExp(r'^[0-9A-F-]{36}$', caseSensitive: false).hasMatch(n))
            .toSet()
            .length;
        if (layers > 0) details['Layers'] = '$layers';
        if (c.entries.any((e) => e.name.startsWith('video/'))) {
          details['Time-lapse'] = 'Included';
        }
      case 'cdr':
        final hit = first([
          'previews/thumbnail.png',
          'metadata/thumbnails/thumbnail.png',
          'metadata/thumbnails/thumbnail.bmp',
          'metadata/thumbnails/page1.bmp',
        ]);
        if (hit != null) (image, source) = (hit.$1, 'Embedded thumbnail');
        final riff = c.findAny(['content/riffData.cdr', 'content/root.dat']);
        if (riff != null) {
          final h = c.readPrefix(riff, 12);
          final v = h == null ? null : _cdrVersion(h);
          if (v != null) details['CorelDRAW version'] = v;
        }
        final meta = c.readText('metadata/metadata.xml', maxSize: 4 << 20);
        if (meta != null) {
          _put(details, 'Title', _xmlText(meta, 'dc:title'));
          _put(details, 'Created with', _xmlText(meta, 'xmp:CreatorTool'));
        }
      case 'xd':
        final hit = first([
          'preview.png',
          'thumbnail.png',
          ...c.entries
              .where((e) => e.name.startsWith('renditions/') && e.name.endsWith('.png'))
              .map((e) => e.name),
        ]);
        if (hit != null) (image, source) = (hit.$1, 'Embedded preview');
        final manifest = _json(c.readText('manifest', maxSize: 4 << 20));
        if (manifest is Map) {
          _put(details, 'Name', manifest['name']);
          var artboards = 0;
          void walk(Object? node) {
            if (node is Map) {
              final path = node['path'];
              if (path is String && path.startsWith('artboard-')) artboards++;
              walk(node['children']);
            } else if (node is List) {
              node.forEach(walk);
            }
          }

          walk(manifest['children']);
          if (artboards > 0) details['Artboards'] = '$artboards';
          final v = manifest['uxdesign#version'] ?? manifest['version'];
          if (v != null) details['XD format version'] = '$v';
        }
      case 'pages' || 'numbers':
        final hit = first([
          'preview.jpg',
          'QuickLook/Thumbnail.jpg',
          'QuickLook/Thumbnail.png',
          'preview-web.jpg',
          'preview-micro.jpg',
        ]);
        if (hit != null) (image, source) = (hit.$1, 'Embedded preview');
        final pdf = c.find('QuickLook/Preview.pdf');
        if (pdf != null) {
          final bytes = c.read(pdf, maxSize: 64 << 20);
          if (bytes != null && bytes.length > 64 && _starts(bytes, '%PDF')) {
            embeddedPdf = bytes;
          }
        }
        final iwa = c.entries.any((e) => e.name.endsWith('.iwa'));
        details['Package'] = iwa ? 'iWork 2013 or later' : "iWork '09";
        final history = c.readText('Metadata/BuildVersionHistory.plist',
                maxSize: 1 << 20) ??
            c.readText('buildVersionHistory.plist', maxSize: 1 << 20);
        if (history != null) {
          final builds = RegExp(r'<string>([^<]+)</string>')
              .allMatches(history)
              .map((m) => m[1]!)
              .toList();
          if (builds.isNotEmpty) details['Last saved by'] = builds.last;
        }
        if (image == null && embeddedPdf == null) {
          note = 'This document was saved without a preview.';
        }
      default:
        final hit = first([
          'thumbnail.png',
          'preview.png',
          'previews/preview.png',
          'Thumbnails/thumbnail.png',
          'QuickLook/Thumbnail.png',
          'QuickLook/Thumbnail.jpg',
          'preview.jpg',
          'mergedimage.png',
        ]);
        if (hit != null) (image, source) = (hit.$1, 'Embedded thumbnail');
    }
    final files = c.entries.where((e) => !e.isDirectory).length;
    details[isDirectory ? 'Package files' : 'Files in package'] = '$files';
    final damaged = c is ZipContainer && c.recovered;
    if (damaged) {
      details['Integrity'] = 'Incomplete or damaged (read what was readable)';
    }
    if (image == null && note == null && embeddedPdf == null) {
      note = damaged
          ? 'This file looks incomplete or damaged, and no preview could be '
              'recovered from it.'
          : 'No preview image was found in this file.';
    }
    format = details['Format'] ?? format;
    return _withImage(
      format: format,
      image: image,
      source: source,
      details: details,
      embeddedPdf: embeddedPdf,
      note: note,
    );
  }

  // ---------------------------------------------------------- CorelDRAW

  static String? _cdrVersion(Uint8List h) {
    if (h.length < 12 || !_starts(h, 'RIFF')) return null;
    final tag = _ascii(h, 8, 4);
    if (!tag.startsWith('CDR') && !tag.startsWith('cdr')) return null;
    final c = tag.codeUnitAt(3);
    final int v;
    if (c >= 0x30 && c <= 0x39) {
      v = c - 0x30;
    } else if (c >= 0x41 && c <= 0x5A) {
      v = c - 0x41 + 10;
    } else {
      return null;
    }
    const names = {
      13: 'X3',
      14: 'X4',
      15: 'X5',
      16: 'X6',
      17: 'X7',
      18: 'X8',
      19: '2017',
      20: '2018',
      21: '2019',
      22: '2020',
      23: '2021',
      24: '2022',
      25: '2023',
      26: '2024',
    };
    return names[v] == null ? 'Version $v' : '${names[v]} (version $v)';
  }

  static DesignPreview _cdrRiff(RandomBytes src, Uint8List head) {
    final details = <String, String>{'Format': 'CorelDRAW drawing (RIFF)'};
    final v = _cdrVersion(head);
    if (v != null) details['CorelDRAW version'] = v;
    // Older files keep a bitmap thumbnail in a "DISP" chunk.
    Uint8List? image;
    final disp = src.indexOf(ascii.encode('DISP'), end: math.min(src.length, 4 << 20));
    if (disp > 0) {
      final size = src.u32(disp + 4, littleEndian: true);
      if (size > 40 && size < (16 << 20)) {
        final data = src.read(disp + 8, size);
        for (var skip = 0; skip <= 8 && image == null; skip += 4) {
          if (data.length > skip + 40 &&
              ByteData.sublistView(data).getUint32(skip, Endian.little) == 40) {
            final bmp = _dibToBmp(Uint8List.sublistView(data, skip));
            if (bmp != null && imageSize(bmp) != null) image = bmp;
          }
        }
      }
    }
    return _withImage(
      format: 'CorelDRAW drawing',
      image: image,
      source: 'Embedded thumbnail',
      details: details,
      note: image == null
          ? 'Older CorelDRAW files have no preview that can be shown here.'
          : null,
    );
  }

  // ------------------------------------------------------------- Figma

  static DesignPreview _figBinary(RandomBytes src, Uint8List head) {
    final details = <String, String>{
      'Format': _starts(head, 'fig-jam') ? 'FigJam board (binary)' : 'Figma design (binary)',
    };
    if (head.length >= 12) {
      details['Figma file version'] =
          '${ByteData.sublistView(head).getUint32(8, Endian.little)}';
    }
    return DesignPreview(
      format: 'Figma design',
      details: details,
      note: 'This older Figma file format has no embedded preview. '
          'Re-export it from Figma to include a thumbnail.',
    );
  }

  // ----------------------------------------------------------- Affinity

  static DesignPreview _affinity(RandomBytes src, String ext) {
    final format = formatName(ext);
    final details = <String, String>{'Format': format};
    final png = _findPng(src, limit: 64 << 20);
    return _withImage(
      format: format,
      image: png,
      source: 'Embedded thumbnail',
      details: details,
      note: png == null ? 'No preview image was found in this file.' : null,
    );
  }

  /// The first complete PNG stream in [src].
  static Uint8List? _findPng(RandomBytes src, {required int limit}) {
    const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    var pos = 0;
    final end = math.min(src.length, limit);
    for (var guard = 0; guard < 64; guard++) {
      final at = src.indexOf(sig, start: pos, end: end);
      if (at < 0) return null;
      var p = at + 8;
      var ok = false;
      var first = true;
      for (var chunks = 0; chunks < 100000; chunks++) {
        final len = src.u32(p, littleEndian: false);
        final type = latin1.decode(src.read(p + 4, 4));
        if (len < 0 || p + 12 + len > src.length) break;
        if (first) {
          if (type != 'IHDR') break;
          final w = src.u32(p + 8, littleEndian: false);
          final h = src.u32(p + 12, littleEndian: false);
          if (w < 8 || h < 8 || w > 16384 || h > 16384) break;
          first = false;
        }
        p += 12 + len;
        if (type == 'IEND') {
          ok = true;
          break;
        }
      }
      if (ok && p - at < (64 << 20)) {
        return Uint8List.fromList(src.read(at, p - at));
      }
      pos = at + 8;
    }
    return null;
  }

  // ------------------------------------------------------------ Unknown

  static DesignPreview _unknown(RandomBytes src, String ext) {
    final format = formatName(ext);
    final details = <String, String>{'Format': format};
    final packets = XmpPacket.findIn(
      src,
      regions: [(0, 4 << 20), (src.length - (4 << 20), 4 << 20)],
      fullScan: false,
    );
    final thumb = _xmpDetails(packets, details);
    Uint8List? image = thumb?.bytes;
    var source = 'Embedded thumbnail (XMP)';
    if (image == null &&
        const {'afdesign', 'afphoto', 'afpub', 'procreate'}.contains(ext)) {
      image = _findPng(src, limit: 64 << 20);
      source = 'Embedded thumbnail';
    }
    return _withImage(
      format: format,
      image: image,
      source: source,
      details: details,
      note: image == null
          ? "This file's format isn't recognised, so no preview could be found."
          : null,
    );
  }

  // ------------------------------------------------------------ helpers

  /// Builds the result, converting images Flutter can't decode (TIFF) to
  /// PNG and recording the image size.
  static DesignPreview _withImage({
    required String format,
    required Uint8List? image,
    required String? source,
    required Map<String, String> details,
    bool pdfCompatible = false,
    bool postScript = false,
    Uint8List? embeddedPdf,
    String? note,
  }) {
    var bytes = image;
    if (bytes != null && _isTiff(bytes)) {
      try {
        final decoded = img.decodeTiff(bytes);
        bytes = decoded == null ? null : img.encodePng(decoded);
      } catch (_) {
        bytes = null;
      }
    }
    final size = bytes == null ? null : imageSize(bytes);
    if (bytes != null && size == null) bytes = null;
    if (size != null) {
      details['Preview'] = '${source ?? 'Embedded preview'}, '
          '${size.$1} × ${size.$2} px';
    }
    return DesignPreview(
      format: format,
      image: bytes,
      imageSource: bytes == null ? null : source,
      imageWidth: size?.$1,
      imageHeight: size?.$2,
      details: details,
      pdfCompatible: pdfCompatible,
      postScript: postScript,
      embeddedPdf: embeddedPdf,
      note: bytes == null ? note : null,
    );
  }

  /// (width, height) of a PNG, JPEG, GIF, BMP or TIFF image; null if
  /// [bytes] is not one of those.
  static (int, int)? imageSize(Uint8List bytes) {
    if (bytes.length < 24) return null;
    final d = ByteData.sublistView(bytes);
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E) {
      return (d.getUint32(16), d.getUint32(20));
    }
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      final info = JpegUtil.parseHeader(MemoryRandomBytes(bytes), 0);
      return info == null || !info.isDisplayable
          ? null
          : (info.width, info.height);
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
    }
    if (bytes[0] == 0x42 && bytes[1] == 0x4D && bytes.length >= 26) {
      final w = d.getInt32(18, Endian.little);
      final h = d.getInt32(22, Endian.little).abs();
      return w > 0 && h > 0 ? (w, h) : null;
    }
    if (_isTiff(bytes)) {
      try {
        final info = img.TiffDecoder().startDecode(bytes);
        return info == null ? null : (info.width, info.height);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static bool _isTiff(Uint8List b) =>
      b.length > 8 &&
      ((b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) ||
          (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A));

  static Object? _json(String? text) {
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static String? _xmlText(String xml, String tag) {
    final q = RegExp.escape(tag);
    final m = RegExp('<$q(?:\\s[^>]*)?>([^<]*)</$q>').firstMatch(xml);
    final v = m?[1]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static void _put(Map<String, String> details, String label, Object? value) {
    if (value == null) return;
    final v = '$value'.trim();
    if (v.isNotEmpty) details[label] = v;
  }

  static String _list(Iterable<String> items, {int max = 6}) {
    final list = items.where((s) => s.trim().isNotEmpty).toSet().toList();
    if (list.length <= max) return list.join(', ');
    return '${list.take(max).join(', ')} and ${list.length - max} more';
  }

  static String _num(double v) => v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'\.?0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');

  static String? _xmpDate(String? v) {
    if (v == null) return null;
    final m = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}(?::\d{2})?)').firstMatch(v);
    return m == null ? v : '${m[1]} ${m[2]}';
  }

  static bool _starts(List<int> b, String text) {
    if (b.length < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static String _ascii(List<int> b, int start, int length) {
    if (b.length < start + length) return '';
    return String.fromCharCodes(b.sublist(start, start + length));
  }

  static String _extension(String path) {
    final slash = math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    final dot = path.lastIndexOf('.');
    return dot > slash ? path.substring(dot + 1).toLowerCase() : '';
  }
}
