import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:folder/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:folder/features/viewer_pdf/services/pdf_encryption.dart';
import 'package:folder/features/viewer_pdf/services/pdfium_native.dart';
import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;

/// Structural PDF edits built on PDFium.
///
/// Every operation takes the current document bytes and returns new bytes.
/// The work runs on pdfrx's PDFium worker isolate so large documents don't
/// freeze the UI. Each entry point is a top-level function taking plain
/// data, which keeps the messages sendable.
abstract final class PdfDocumentOps {
  /// Checks whether [bytes] can be opened, optionally with [password].
  static Future<PdfProbeResult> probe(Uint8List bytes, {String? password}) =>
      onPdfiumWorker(_probe, (bytes: bytes, password: password));

  /// Removes the open password so the viewer and the editors can work on a
  /// plain copy. The password is re-applied with [encrypt] when saving.
  static Future<Uint8List> decrypt(Uint8List bytes, String password) =>
      onPdfiumWorker(_decrypt, (bytes: bytes, password: password));

  /// Protects the document with [password] (AES-256), used both as the open
  /// password and the permissions password.
  static Future<Uint8List> encrypt(Uint8List bytes, String password) async {
    // A full rewrite by PDFium first: a regular file the encryptor can walk.
    final plain = await onPdfiumWorker(_rewrite, bytes);
    return Isolate.run(() => PdfEncryption.encrypt(plain, password));
  }

  static Future<List<PdfPageMeta>> pageMetas(Uint8List bytes) =>
      onPdfiumWorker(_pageMetas, bytes);

  /// Rotates the pages at [indices] by [quarterTurns] clockwise.
  static Future<Uint8List> rotatePages(
    Uint8List bytes,
    Set<int> indices,
    int quarterTurns,
  ) => onPdfiumWorker(_rotatePages, (
    bytes: bytes,
    indices: indices.toList(),
    turns: quarterTurns,
  ));

  static Future<Uint8List> deletePages(Uint8List bytes, Set<int> indices) =>
      onPdfiumWorker(_deletePages, (bytes: bytes, indices: indices.toList()));

  /// Inserts a blank page at [index], sized like its neighbour.
  static Future<Uint8List> insertBlankPage(Uint8List bytes, int index) =>
      onPdfiumWorker(_insertBlankPage, (bytes: bytes, index: index));

  /// Applies a page-manager plan (reorder, rotate, delete and insert blank
  /// pages) in one pass.
  static Future<Uint8List> applyPagePlan(
    Uint8List bytes,
    List<PagePlanEntry> plan,
  ) => onPdfiumWorker(_applyPagePlan, (
    bytes: bytes,
    plan: [
      for (final e in plan)
        (
          source: e.sourceIndex,
          turns: e.quarterTurns,
          width: e.blankSize?.width,
          height: e.blankSize?.height,
        ),
    ],
  ));

  /// Returns a new PDF made of the pages at [indices] (kept in document
  /// order), with their annotations and links.
  static Future<Uint8List> extractPages(Uint8List bytes, Set<int> indices) =>
      onPdfiumWorker(_extractPages, (bytes: bytes, indices: indices.toList()));

  /// Inserts the pages of [other] at [index] (end of document when null),
  /// with their annotations.
  static Future<Uint8List> insertPdf(
    Uint8List bytes,
    Uint8List other, {
    String? otherPassword,
    int? index,
  }) => onPdfiumWorker(_insertPdf, (
    bytes: bytes,
    other: other,
    password: otherPassword,
    index: index,
  ));

  /// Draws [marks] permanently onto the page at [pageIndex].
  static Future<Uint8List> drawOnPage(
    Uint8List bytes,
    int pageIndex,
    List<PageMark> marks,
  ) async {
    // Images are made PDF-friendly (and fonts read) off the worker, which
    // only does the PDFium calls.
    final prepared = await Isolate.run(
      () => [for (final mark in marks) _prepare(mark)],
    );
    return onPdfiumWorker(_drawOnPage, (
      bytes: bytes,
      page: pageIndex,
      marks: prepared,
      font: prepared.any((m) => m.text != null && !_isWinAnsi(m.text!))
          ? _systemFontBytes()
          : null,
    ));
  }

  /// Whether [drawOnPage] can write [text] as real PDF text: Western text
  /// with the standard font, or Latin, Greek and Cyrillic when a system
  /// TrueType font is available (embedded in the file). Other scripts and emoji have to be placed as an image.
  static bool canEmbedText(String text) {
    if (_isWinAnsi(text)) return true;
    for (final rune in text.runes) {
      if (!_isWinAnsi(String.fromCharCode(rune)) &&
          !_coveredBySystemFont(rune)) {
        return false;
      }
    }
    return _systemFontPath() != null;
  }

  /// Bytes to embed for an image picked on the page canvas.
  ///
  /// PNG files and upright JPEGs are kept as they are. Anything else (HEIC,
  /// AVIF, WebP, camera JPEGs with an EXIF rotation...) is re-encoded from
  /// [decoded], which the platform decoder already turned the right way up;
  /// PDF ignores EXIF orientation.
  static Future<Uint8List> imageForPdf(Uint8List bytes, Image decoded) async {
    final isJpeg = _isJpeg(bytes);
    if (_isPng(bytes) || (isJpeg && _jpegOrientation(bytes) <= 1)) {
      return bytes;
    }
    const maxSide = 2400;
    final longest = math.max(decoded.width, decoded.height);
    Image? scaled;
    if (longest > maxSide) {
      final k = maxSide / longest;
      final width = math.max(1, (decoded.width * k).round());
      final height = math.max(1, (decoded.height * k).round());
      final recorder = PictureRecorder();
      Canvas(recorder).drawImageRect(
        decoded,
        Rect.fromLTWH(
          0,
          0,
          decoded.width.toDouble(),
          decoded.height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      scaled = await picture.toImage(width, height);
      picture.dispose();
    }
    try {
      final source = scaled ?? decoded;
      final data = await source.toByteData(
        format: ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw const FormatException('Unsupported image');
      final rgba = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final width = source.width;
      final height = source.height;
      return await Isolate.run(() => _encodeRgba(rgba, width, height));
    } finally {
      scaled?.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Worker entry points. Keep these top-level so messages stay sendable.
// ---------------------------------------------------------------------------

typedef _Bytes = Uint8List;

PdfProbeResult _probe(({_Bytes bytes, String? password}) m) {
  NativeDocument? doc;
  try {
    doc = NativeDocument.open(m.bytes, password: m.password);
    return PdfProbeResult(PdfOpenStatus.ok, pageCount: doc.pageCount);
  } on PdfiumException catch (e) {
    if (e.isPasswordError) {
      return const PdfProbeResult(PdfOpenStatus.needsPassword);
    }
    return PdfProbeResult(PdfOpenStatus.invalid, message: e.message);
  } finally {
    doc?.close();
  }
}

Uint8List _decrypt(({_Bytes bytes, String password}) m) {
  final doc = NativeDocument.open(m.bytes, password: m.password);
  try {
    return doc.save(removeSecurity: true);
  } finally {
    doc.close();
  }
}

Uint8List _rewrite(_Bytes bytes) => _edit(bytes, (_) {});

Uint8List _edit(_Bytes bytes, void Function(NativeDocument doc) change) {
  final doc = NativeDocument.open(bytes);
  try {
    change(doc);
    return doc.save();
  } finally {
    doc.close();
  }
}

/// A page's visible area (media box ∩ crop box) in PDF user space, and its
/// clockwise display rotation in quarter turns.
class _PageGeometry {
  _PageGeometry(this.left, this.bottom, this.width, this.height, this.turns);

  factory _PageGeometry.of(pdfium_bindings.FPDF_PAGE page) {
    final rect = calloc<FS_RECTF>();
    try {
      double left = 0, bottom = 0, width, height;
      if (pdfium.FPDF_GetPageBoundingBox(page, rect) != 0) {
        left = math.min(rect.ref.left, rect.ref.right);
        bottom = math.min(rect.ref.bottom, rect.ref.top);
        width = (rect.ref.right - rect.ref.left).abs();
        height = (rect.ref.top - rect.ref.bottom).abs();
      } else {
        width = pdfium.FPDF_GetPageWidthF(page);
        height = pdfium.FPDF_GetPageHeightF(page);
      }
      final turns = pdfium.FPDFPage_GetRotation(page) % 4;
      // PDFium reports the rotated size when there's no box to read.
      if (left == 0 && bottom == 0 && turns.isOdd && rect.ref.right == 0) {
        (width, height) = (height, width);
      }
      return _PageGeometry(left, bottom, width, height, turns);
    } finally {
      calloc.free(rect);
    }
  }

  final double left, bottom, width, height;
  final int turns;

  PdfPageMeta get meta =>
      PdfPageMeta(width: width, height: height, rotation: turns * 90);

  /// A point in display coordinates (points, origin top-left, rotation
  /// applied) in PDF user space.
  Offset toPdf(Offset display) {
    final (dx, dy) = (display.dx, display.dy);
    final (x, y) = switch (turns) {
      1 => (dy, dx),
      2 => (width - dx, dy),
      3 => (width - dy, height - dx),
      _ => (dx, height - dy),
    };
    return Offset(left + x, bottom + y);
  }

  /// Direction of the display's x axis in PDF space, as (cos, sin).
  (double, double) get axis => switch (turns) {
    1 => (0, 1),
    2 => (-1, 0),
    3 => (0, -1),
    _ => (1, 0),
  };
}

List<PdfPageMeta> _pageMetas(_Bytes bytes) {
  final doc = NativeDocument.open(bytes);
  try {
    return [
      for (var i = 0; i < doc.pageCount; i++)
        doc.withPage(i, (page) => _PageGeometry.of(page).meta),
    ];
  } finally {
    doc.close();
  }
}

void _rotate(NativeDocument doc, int index, int turns) {
  doc.withPage(index, (page) {
    final current = pdfium.FPDFPage_GetRotation(page);
    pdfium.FPDFPage_SetRotation(page, ((current + turns) % 4 + 4) % 4);
  });
}

Uint8List _rotatePages(({_Bytes bytes, List<int> indices, int turns}) m) =>
    _edit(m.bytes, (doc) {
      for (final i in m.indices) {
        _rotate(doc, i, m.turns);
      }
    });

Uint8List _deletePages(({_Bytes bytes, List<int> indices}) m) =>
    _edit(m.bytes, (doc) {
      final sorted = m.indices.toSet().toList()..sort((a, b) => b - a);
      if (sorted.length >= doc.pageCount) {
        throw StateError('A PDF needs at least one page');
      }
      for (final i in sorted) {
        pdfium.FPDFPage_Delete(doc.handle, i);
      }
    });

Uint8List _insertBlankPage(({_Bytes bytes, int index}) m) =>
    _edit(m.bytes, (doc) {
      final count = doc.pageCount;
      final at = m.index.clamp(0, count);
      var size = const Size(595.28, 841.89); // A4
      if (count > 0) {
        size = doc.withPage(
          math.min(at, count - 1),
          (page) => _PageGeometry.of(page).meta.displaySize,
        );
      }
      _newPage(doc, at, size);
    });

void _newPage(NativeDocument doc, int at, Size size) {
  final page = pdfium.FPDFPage_New(doc.handle, at, size.width, size.height);
  if (page == nullptr) throw const PdfiumException('Could not add a page');
  pdfium.FPDF_ClosePage(page);
}

typedef _PlanEntry = ({int? source, int turns, double? width, double? height});

Uint8List _applyPagePlan(({_Bytes bytes, List<_PlanEntry> plan}) m) {
  final plan = m.plan;
  if (plan.isEmpty) throw StateError('A PDF needs at least one page');
  return _edit(m.bytes, (doc) {
    final count = doc.pageCount;
    final order = [
      for (final e in plan)
        if (e.source != null) e.source!,
    ];
    if (order.toSet().length != order.length) {
      throw StateError('A page appears twice in the plan');
    }
    for (final e in plan) {
      if (e.source != null && e.turns % 4 != 0) {
        _rotate(doc, e.source!, e.turns);
      }
    }

    // Drop pages that aren't in the plan, then put the rest in plan order.
    final kept = order.toSet();
    for (var i = count - 1; i >= 0; i--) {
      if (!kept.contains(i)) pdfium.FPDFPage_Delete(doc.handle, i);
    }
    final survivors = [
      for (var i = 0; i < count; i++)
        if (kept.contains(i)) i,
    ];
    final position = {
      for (var i = 0; i < survivors.length; i++) survivors[i]: i,
    };
    final newOrder = [for (final source in order) position[source]!];
    var identity = true;
    for (var i = 0; i < newOrder.length; i++) {
      if (newOrder[i] != i) identity = false;
    }
    if (!identity) {
      final indices = calloc<Int>(newOrder.length);
      try {
        for (var i = 0; i < newOrder.length; i++) {
          indices[i] = newOrder[i];
        }
        if (pdfium.FPDF_MovePages(doc.handle, indices, newOrder.length, 0) ==
            0) {
          throw const PdfiumException('Pages could not be reordered');
        }
      } finally {
        calloc.free(indices);
      }
    }

    for (var i = 0; i < plan.length; i++) {
      final e = plan[i];
      if (e.source == null) {
        _newPage(doc, math.min(i, doc.pageCount), Size(e.width!, e.height!));
      }
    }
  });
}

Uint8List _extractPages(({_Bytes bytes, List<int> indices}) m) =>
    _edit(m.bytes, (doc) {
      final keep = m.indices.toSet();
      for (var i = doc.pageCount - 1; i >= 0; i--) {
        if (!keep.contains(i)) pdfium.FPDFPage_Delete(doc.handle, i);
      }
    });

Uint8List _insertPdf(
  ({_Bytes bytes, _Bytes other, String? password, int? index}) m,
) {
  final other = NativeDocument.open(m.other, password: m.password);
  try {
    return _edit(m.bytes, (doc) {
      final at = (m.index ?? doc.pageCount).clamp(0, doc.pageCount);
      final ok = pdfium.FPDF_ImportPagesByIndex(
        doc.handle,
        other.handle,
        nullptr,
        0,
        at,
      );
      if (ok == 0) throw const PdfiumException('The pages could not be copied');
    });
  } finally {
    other.close();
  }
}

// ---------------------------------------------------------------------------
// Drawing on a page
// ---------------------------------------------------------------------------

/// A [PageMark] reduced to sendable data the worker can draw directly.
typedef _Mark = ({
  List<double>? points,
  int argb,
  double width,
  String? text,
  double x,
  double y,
  double fontSize,
  Uint8List? jpeg,
  Uint8List? rgba,
  int pixelWidth,
  int pixelHeight,
  double rectWidth,
  double rectHeight,
});

_Mark _prepare(PageMark mark) {
  int argb(Color c, [double opacity = 1]) =>
      ((c.a * opacity * 255).round().clamp(0, 255) << 24) |
      ((c.r * 255).round() << 16) |
      ((c.g * 255).round() << 8) |
      (c.b * 255).round();
  switch (mark) {
    case InkMark():
      return (
        points: [
          for (final p in mark.points) ...[p.dx, p.dy],
        ],
        argb: argb(mark.color, mark.opacity),
        width: mark.width,
        text: null,
        x: 0,
        y: 0,
        fontSize: 0,
        jpeg: null,
        rgba: null,
        pixelWidth: 0,
        pixelHeight: 0,
        rectWidth: 0,
        rectHeight: 0,
      );
    case TextMark():
      return (
        points: null,
        argb: argb(mark.color),
        width: 0,
        text: mark.text,
        x: mark.position.dx,
        y: mark.position.dy,
        fontSize: mark.fontSize,
        jpeg: null,
        rgba: null,
        pixelWidth: 0,
        pixelHeight: 0,
        rectWidth: 0,
        rectHeight: 0,
      );
    case ImageMark():
      final image = _pdfFriendlyImage(mark.bytes);
      return (
        points: null,
        argb: 0,
        width: 0,
        text: null,
        x: mark.rect.left,
        y: mark.rect.bottom,
        fontSize: 0,
        jpeg: image.jpeg,
        rgba: image.rgba,
        pixelWidth: image.width,
        pixelHeight: image.height,
        rectWidth: mark.rect.width,
        rectHeight: mark.rect.height,
      );
  }
}

Uint8List _drawOnPage(
  ({_Bytes bytes, int page, List<_Mark> marks, Uint8List? font}) m,
) => _edit(m.bytes, (doc) {
  final fonts = _Fonts(doc, m.font);
  try {
    doc.withPage(m.page, (page) {
      final geometry = _PageGeometry.of(page);
      for (final mark in m.marks) {
        if (mark.points != null) {
          _drawInk(page, geometry, mark);
        } else if (mark.text != null) {
          _drawText(doc, page, geometry, mark, fonts);
        } else {
          _drawImage(doc, page, geometry, mark);
        }
      }
      if (pdfium.FPDFPage_GenerateContent(page) == 0) {
        throw const PdfiumException('The page could not be updated');
      }
    });
  } finally {
    fonts.close();
  }
});

/// Fonts for one drawing session, each loaded (and embedded) at most once.
class _Fonts {
  _Fonts(this._doc, this._trueType);

  final NativeDocument _doc;
  final Uint8List? _trueType;
  pdfium_bindings.FPDF_FONT? _standard;
  pdfium_bindings.FPDF_FONT? _embedded;

  /// Helvetica for Western text, else the system font (embedded).
  pdfium_bindings.FPDF_FONT forText(String text) {
    final bytes = _trueType;
    if (!_isWinAnsi(text) && bytes != null) {
      return _embedded ??= using<pdfium_bindings.FPDF_FONT>((arena) {
        final data = arena<Uint8>(bytes.length);
        data.asTypedList(bytes.length).setAll(0, bytes);
        return pdfium.FPDFText_LoadFont(
          _doc.handle,
          data,
          bytes.length,
          pdfium_bindings.FPDF_FONT_TRUETYPE,
          1,
        );
      });
    }
    return _standard ??= using<pdfium_bindings.FPDF_FONT>(
      (arena) => pdfium.FPDFText_LoadStandardFont(
        _doc.handle,
        'Helvetica'.toNativeUtf8(allocator: arena).cast(),
      ),
    );
  }

  void close() {
    for (final font in [_standard, _embedded]) {
      if (font != null && font != nullptr) pdfium.FPDFFont_Close(font);
    }
  }
}

(int, int, int, int) _channels(int argb) =>
    ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF);

void _drawInk(pdfium_bindings.FPDF_PAGE page, _PageGeometry g, _Mark mark) {
  final points = mark.points!;
  if (points.isEmpty) return;
  final (r, gr, b, a) = _channels(mark.argb);
  final start = g.toPdf(Offset(points[0], points[1]));
  if (points.length == 2) {
    // A dot: a filled circle (four Bézier quarters).
    final radius = mark.width / 2;
    const k = 0.5523;
    final c = start;
    final path = pdfium.FPDFPageObj_CreateNewPath(c.dx + radius, c.dy);
    pdfium.FPDFPath_BezierTo(
      path,
      c.dx + radius,
      c.dy + radius * k,
      c.dx + radius * k,
      c.dy + radius,
      c.dx,
      c.dy + radius,
    );
    pdfium.FPDFPath_BezierTo(
      path,
      c.dx - radius * k,
      c.dy + radius,
      c.dx - radius,
      c.dy + radius * k,
      c.dx - radius,
      c.dy,
    );
    pdfium.FPDFPath_BezierTo(
      path,
      c.dx - radius,
      c.dy - radius * k,
      c.dx - radius * k,
      c.dy - radius,
      c.dx,
      c.dy - radius,
    );
    pdfium.FPDFPath_BezierTo(
      path,
      c.dx + radius * k,
      c.dy - radius,
      c.dx + radius,
      c.dy - radius * k,
      c.dx + radius,
      c.dy,
    );
    pdfium.FPDFPath_Close(path);
    pdfium.FPDFPageObj_SetFillColor(path, r, gr, b, a);
    pdfium.FPDFPath_SetDrawMode(path, pdfium_bindings.FPDF_FILLMODE_WINDING, 0);
    pdfium.FPDFPage_InsertObject(page, path);
    return;
  }
  final path = pdfium.FPDFPageObj_CreateNewPath(start.dx, start.dy);
  for (var i = 2; i + 1 < points.length; i += 2) {
    final p = g.toPdf(Offset(points[i], points[i + 1]));
    pdfium.FPDFPath_LineTo(path, p.dx, p.dy);
  }
  pdfium.FPDFPageObj_SetStrokeColor(path, r, gr, b, a);
  pdfium.FPDFPageObj_SetStrokeWidth(path, mark.width);
  pdfium.FPDFPageObj_SetLineCap(path, pdfium_bindings.FPDF_LINECAP_ROUND);
  pdfium.FPDFPageObj_SetLineJoin(path, pdfium_bindings.FPDF_LINEJOIN_ROUND);
  pdfium.FPDFPath_SetDrawMode(path, pdfium_bindings.FPDF_FILLMODE_NONE, 1);
  pdfium.FPDFPage_InsertObject(page, path);
}

void _drawText(
  NativeDocument doc,
  pdfium_bindings.FPDF_PAGE page,
  _PageGeometry g,
  _Mark mark,
  _Fonts fonts,
) {
  final text = mark.text!;
  if (text.trim().isEmpty) return;
  final font = fonts.forText(text);
  if (font == nullptr) throw const PdfiumException('No font for this text');
  {
    final (r, gr, b, a) = _channels(mark.argb);
    final (cos, sin) = g.axis;
    final size = mark.fontSize;
    final ascent = size * 0.8;
    final lineHeight = size * 1.2;
    var top = mark.y;
    for (final line in text.split('\n')) {
      if (line.isNotEmpty) {
        final obj = pdfium.FPDFPageObj_CreateTextObj(doc.handle, font, size);
        using((arena) => pdfium.FPDFText_SetText(obj, wideString(line, arena)));
        pdfium.FPDFPageObj_SetFillColor(obj, r, gr, b, a);
        final origin = g.toPdf(Offset(mark.x, top + ascent));
        pdfium.FPDFPageObj_Transform(
          obj,
          cos,
          sin,
          -sin,
          cos,
          origin.dx,
          origin.dy,
        );
        pdfium.FPDFPage_InsertObject(page, obj);
      }
      top += lineHeight;
    }
  }
}

void _drawImage(
  NativeDocument doc,
  pdfium_bindings.FPDF_PAGE page,
  _PageGeometry g,
  _Mark mark,
) {
  final obj = pdfium.FPDFPageObj_NewImageObj(doc.handle);
  final jpeg = mark.jpeg;
  if (jpeg != null) {
    final file = MemoryFileAccess(jpeg);
    try {
      if (pdfium.FPDFImageObj_LoadJpegFileInline(
            nullptr,
            0,
            obj,
            file.access,
          ) ==
          0) {
        throw const PdfiumException('The image could not be read');
      }
    } finally {
      file.dispose();
    }
  } else {
    final rgba = mark.rgba!;
    final w = mark.pixelWidth, h = mark.pixelHeight;
    final pixels = malloc<Uint8>(w * h * 4);
    try {
      // PDFium bitmaps are BGRA.
      final out = pixels.asTypedList(w * h * 4);
      for (var i = 0; i < out.length; i += 4) {
        out[i] = rgba[i + 2];
        out[i + 1] = rgba[i + 1];
        out[i + 2] = rgba[i];
        out[i + 3] = rgba[i + 3];
      }
      final bitmap = pdfium.FPDFBitmap_CreateEx(
        w,
        h,
        pdfium_bindings.FPDFBitmap_BGRA,
        pixels.cast(),
        w * 4,
      );
      try {
        if (pdfium.FPDFImageObj_SetBitmap(nullptr, 0, obj, bitmap) == 0) {
          throw const PdfiumException('The image could not be added');
        }
      } finally {
        pdfium.FPDFBitmap_Destroy(bitmap);
      }
    } finally {
      malloc.free(pixels);
    }
  }
  // Unit square → the rect, upright in display orientation.
  final (cos, sin) = g.axis;
  final origin = g.toPdf(Offset(mark.x, mark.y)); // display bottom-left
  final w = mark.rectWidth, h = mark.rectHeight;
  pdfium.FPDFImageObj_SetMatrix(
    obj,
    w * cos,
    w * sin,
    -h * sin,
    h * cos,
    origin.dx,
    origin.dy,
  );
  pdfium.FPDFPage_InsertObject(page, obj);
}

// ---------------------------------------------------------------------------
// Fonts and images
// ---------------------------------------------------------------------------

/// Characters the standard PDF fonts can show (WinAnsiEncoding): Latin-1
/// plus typographic punctuation, the euro sign and a few letters.
const _winAnsiExtras = {
  0x20AC,
  0x201A,
  0x0192,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x02C6,
  0x2030,
  0x0160,
  0x2039,
  0x0152,
  0x017D,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0x02DC,
  0x2122,
  0x0161,
  0x203A,
  0x0153,
  0x017E,
  0x0178,
};

bool _isWinAnsi(String text) => text.runes.every(
  (r) => (r <= 0xFF && (r < 0x80 || r > 0x9F)) || _winAnsiExtras.contains(r),
);

/// Ranges the [_systemFontCandidates] all cover beyond Latin-1: Latin
/// Extended, Greek, Cyrillic, Vietnamese, punctuation and currency signs.
bool _coveredBySystemFont(int rune) =>
    (rune >= 0x0100 && rune <= 0x024F) ||
    (rune >= 0x0370 && rune <= 0x03FF) ||
    (rune >= 0x0400 && rune <= 0x04FF) ||
    (rune >= 0x1E00 && rune <= 0x1EFF) ||
    (rune >= 0x2010 && rune <= 0x205E) ||
    (rune >= 0x20A0 && rune <= 0x20BF) ||
    rune == 0x2116 ||
    rune == 0x2122;

String? _cachedSystemFontPath;
bool _systemFontLooked = false;

Uint8List? _systemFontBytes() {
  final path = _systemFontPath();
  if (path == null) return null;
  try {
    return File(path).readAsBytesSync();
  } catch (_) {
    return null;
  }
}

/// First readable system font of [_systemFontCandidates], or null (always on
/// iOS, where system fonts can't be read).
String? _systemFontPath() {
  if (!_systemFontLooked) {
    _systemFontLooked = true;
    for (final path in _systemFontCandidates()) {
      try {
        if (File(path).existsSync()) {
          _cachedSystemFontPath = path;
          break;
        }
      } catch (_) {
        // Try the next candidate.
      }
    }
  }
  return _cachedSystemFontPath;
}

List<String> _systemFontCandidates() {
  if (Platform.isAndroid) {
    return const [
      '/system/fonts/Roboto-Regular.ttf',
      '/system/fonts/NotoSans-Regular.ttf',
      '/system/fonts/DroidSans.ttf',
    ];
  }
  if (Platform.isWindows) {
    final root = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return ['$root\\Fonts\\arial.ttf', '$root\\Fonts\\segoeui.ttf'];
  }
  if (Platform.isMacOS) {
    return const [
      '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
      '/System/Library/Fonts/Supplemental/Arial.ttf',
      '/Library/Fonts/Arial Unicode.ttf',
    ];
  }
  if (Platform.isLinux) {
    return const [
      '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
      '/usr/share/fonts/TTF/DejaVuSans.ttf',
    ];
  }
  return const [];
}

bool _isPng(Uint8List bytes) =>
    bytes.length > 8 &&
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

bool _isJpeg(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;

/// EXIF orientation of a JPEG (1 = upright), or 1 when there is none.
int _jpegOrientation(Uint8List bytes) {
  try {
    return img.decodeJpgExif(bytes)?.imageIfd.orientation ?? 1;
  } catch (_) {
    return 1;
  }
}

/// Straight RGBA pixels as JPEG when fully opaque (photos), else PNG.
Uint8List _encodeRgba(Uint8List rgba, int width, int height) {
  var opaque = true;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 0xFF) {
      opaque = false;
      break;
    }
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  return opaque ? img.encodeJpg(image, quality: 88) : img.encodePng(image);
}

/// JPEGs are embedded as they are (scaled down when huge); everything else
/// becomes RGBA pixels, kept with their transparency.
({Uint8List? jpeg, Uint8List? rgba, int width, int height}) _pdfFriendlyImage(
  Uint8List bytes,
) {
  const maxSide = 2400;
  if (_isJpeg(bytes) && bytes.length <= 1536 * 1024) {
    final info = img.JpegDecoder().startDecode(bytes);
    if (info != null) {
      return (jpeg: bytes, rgba: null, width: info.width, height: info.height);
    }
  }
  var decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Unsupported image');
  if (math.max(decoded.width, decoded.height) > maxSide) {
    decoded = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxSide)
        : img.copyResize(decoded, height: maxSide);
  }
  if (!decoded.hasAlpha && _isJpeg(bytes)) {
    return (
      jpeg: img.encodeJpg(decoded, quality: 88),
      rgba: null,
      width: decoded.width,
      height: decoded.height,
    );
  }
  final rgba = decoded.convert(numChannels: 4, format: img.Format.uint8);
  return (
    jpeg: null,
    rgba: rgba.getBytes(order: img.ChannelOrder.rgba),
    width: rgba.width,
    height: rgba.height,
  );
}
