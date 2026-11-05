import 'dart:ffi' hide Size;
import 'dart:math' as math;
import 'dart:ui';

import 'package:folder/features/viewer_pdf/services/pdfium_native.dart';
import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart';

/// Text markup annotations made from a text selection.
enum PdfMarkupKind {
  highlight(pdfium_bindings.FPDF_ANNOT_HIGHLIGHT),
  underline(pdfium_bindings.FPDF_ANNOT_UNDERLINE),
  strikeout(pdfium_bindings.FPDF_ANNOT_STRIKEOUT),
  squiggly(pdfium_bindings.FPDF_ANNOT_SQUIGGLY);

  const PdfMarkupKind(this.subtype);
  final int subtype;
}

/// An annotation found by [PdfAnnotationOps.hitTest].
class PdfAnnotationInfo {
  const PdfAnnotationInfo({
    required this.pageIndex,
    required this.index,
    required this.subtype,
    required this.bounds,
    required this.color,
    required this.contents,
  });

  final int pageIndex;

  /// Position in the page's /Annots (changes when annotations are removed).
  final int index;
  final int subtype;

  /// In pdfrx page coordinates (unrotated, y up, relative to the page box).
  final PdfRect bounds;
  final Color color;
  final String contents;

  bool get isNote => subtype == pdfium_bindings.FPDF_ANNOT_TEXT;
}

/// Adds and edits annotations in a document open in the viewer, in place.
///
/// Coordinates are pdfrx page coordinates (unrotated, y up, relative to the
/// visible page box), as in [PdfPageText.charRects].
abstract final class PdfAnnotationOps {
  /// Annotation types the viewer can select, recolour and delete.
  static const editableSubtypes = {
    pdfium_bindings.FPDF_ANNOT_TEXT,
    pdfium_bindings.FPDF_ANNOT_HIGHLIGHT,
    pdfium_bindings.FPDF_ANNOT_UNDERLINE,
    pdfium_bindings.FPDF_ANNOT_SQUIGGLY,
    pdfium_bindings.FPDF_ANNOT_STRIKEOUT,
    pdfium_bindings.FPDF_ANNOT_INK,
    pdfium_bindings.FPDF_ANNOT_SQUARE,
    pdfium_bindings.FPDF_ANNOT_CIRCLE,
    pdfium_bindings.FPDF_ANNOT_FREETEXT,
    pdfium_bindings.FPDF_ANNOT_LINE,
    pdfium_bindings.FPDF_ANNOT_STAMP,
  };

  /// Marks up the text covered by [lines] (one rect per line of text).
  static Future<void> addMarkup(
    PdfDocument document,
    int pageIndex,
    PdfMarkupKind kind,
    List<PdfRect> lines,
    Color color,
  ) => document.useNativeDocumentHandle(
    (handle) => _withPage(handle, pageIndex, (page, origin) {
      if (lines.isEmpty) return;
      final annot = pdfium.FPDFPage_CreateAnnot(page, kind.subtype);
      if (annot == nullptr) {
        throw const PdfiumException('The annotation could not be added');
      }
      try {
        _setColor(annot, color);
        using((arena) {
          final quad = arena<FS_QUADPOINTSF>();
          var bounds = lines.first;
          for (final line in lines) {
            bounds = bounds.merge(line);
            final l = line.left + origin.dx, r = line.right + origin.dx;
            final t = line.top + origin.dy, b = line.bottom + origin.dy;
            quad.ref
              ..x1 = l
              ..y1 = t
              ..x2 = r
              ..y2 = t
              ..x3 = l
              ..y3 = b
              ..x4 = r
              ..y4 = b;
            pdfium.FPDFAnnot_AppendAttachmentPoints(annot, quad);
          }
          _setRect(annot, bounds, origin, arena);
          pdfium.FPDFAnnot_SetFlags(
            annot,
            pdfium_bindings.FPDF_ANNOT_FLAG_PRINT,
          );
          _setDate(annot, arena);
        });
      } finally {
        pdfium.FPDFPage_CloseAnnot(annot);
      }
    }),
  );

  /// Adds a sticky note whose icon's top-left corner is at [at].
  static Future<void> addNote(
    PdfDocument document,
    int pageIndex,
    PdfPoint at,
    String text,
    Color color,
  ) => document.useNativeDocumentHandle(
    (handle) => _withPage(handle, pageIndex, (page, origin) {
      final annot = pdfium.FPDFPage_CreateAnnot(
        page,
        pdfium_bindings.FPDF_ANNOT_TEXT,
      );
      if (annot == nullptr) {
        throw const PdfiumException('The note could not be added');
      }
      try {
        _setColor(annot, color);
        using((arena) {
          _setRect(
            annot,
            PdfRect(at.x, at.y, at.x + 20, at.y - 20),
            origin,
            arena,
          );
          pdfium.FPDFAnnot_SetStringValue(
            annot,
            'Contents'.toNativeUtf8(allocator: arena).cast(),
            wideString(text, arena),
          );
          // Print, NoZoom, NoRotate: an icon that stays the same size.
          pdfium.FPDFAnnot_SetFlags(annot, 4 | 8 | 16);
          _setDate(annot, arena);
        });
      } finally {
        pdfium.FPDFPage_CloseAnnot(annot);
      }
    }),
  );

  /// The top-most editable annotation at [at], if any.
  static Future<PdfAnnotationInfo?> hitTest(
    PdfDocument document,
    int pageIndex,
    PdfPoint at, {
    double tolerance = 3,
  }) => document.useNativeDocumentHandle(
    (handle) => _withPage(handle, pageIndex, (page, origin) {
      return using((arena) {
        final x = at.x + origin.dx, y = at.y + origin.dy;
        final rect = arena<FS_RECTF>();
        final quad = arena<FS_QUADPOINTSF>();
        bool contains(double l, double t, double r, double b) =>
            x >= math.min(l, r) - tolerance &&
            x <= math.max(l, r) + tolerance &&
            y >= math.min(t, b) - tolerance &&
            y <= math.max(t, b) + tolerance;

        for (var i = pdfium.FPDFPage_GetAnnotCount(page) - 1; i >= 0; i--) {
          final annot = pdfium.FPDFPage_GetAnnot(page, i);
          if (annot == nullptr) continue;
          try {
            final subtype = pdfium.FPDFAnnot_GetSubtype(annot);
            if (!editableSubtypes.contains(subtype)) continue;
            if (pdfium.FPDFAnnot_GetRect(annot, rect) == 0) continue;
            final r = rect.ref;
            var hit = contains(r.left, r.top, r.right, r.bottom);
            final quads = pdfium.FPDFAnnot_CountAttachmentPoints(annot);
            if (hit && quads > 0) {
              hit = false;
              for (var q = 0; q < quads && !hit; q++) {
                if (pdfium.FPDFAnnot_GetAttachmentPoints(annot, q, quad) == 0) {
                  continue;
                }
                final p = quad.ref;
                hit = contains(
                  math.min(p.x1, p.x3),
                  math.max(p.y1, p.y2),
                  math.max(p.x2, p.x4),
                  math.min(p.y3, p.y4),
                );
              }
            }
            if (!hit) continue;
            return PdfAnnotationInfo(
              pageIndex: pageIndex,
              index: i,
              subtype: subtype,
              bounds: PdfRect(
                math.min(r.left, r.right) - origin.dx,
                math.max(r.top, r.bottom) - origin.dy,
                math.max(r.left, r.right) - origin.dx,
                math.min(r.top, r.bottom) - origin.dy,
              ),
              color: _getColor(annot, arena),
              contents: _getString(annot, 'Contents', arena),
            );
          } finally {
            pdfium.FPDFPage_CloseAnnot(annot);
          }
        }
        return null;
      });
    }),
  );

  static Future<void> setColor(
    PdfDocument document,
    PdfAnnotationInfo info,
    Color color,
  ) => _withAnnot(document, info, (annot) {
    _setColor(annot, color);
    // Drop the old appearance so PDFium draws it again in the new colour.
    pdfium.FPDFAnnot_SetAP(
      annot,
      pdfium_bindings.FPDF_ANNOT_APPEARANCEMODE_NORMAL,
      nullptr,
    );
  });

  static Future<void> setContents(
    PdfDocument document,
    PdfAnnotationInfo info,
    String text,
  ) => _withAnnot(document, info, (annot) {
    using((arena) {
      pdfium.FPDFAnnot_SetStringValue(
        annot,
        'Contents'.toNativeUtf8(allocator: arena).cast(),
        wideString(text, arena),
      );
    });
  });

  static Future<void> remove(PdfDocument document, PdfAnnotationInfo info) =>
      document.useNativeDocumentHandle(
        (handle) => _withPage(handle, info.pageIndex, (page, _) {
          if (pdfium.FPDFPage_RemoveAnnot(page, info.index) == 0) {
            throw const PdfiumException('The annotation could not be removed');
          }
        }),
      );

  // -------------------------------------------------------------------------

  static Future<void> _withAnnot(
    PdfDocument document,
    PdfAnnotationInfo info,
    void Function(pdfium_bindings.FPDF_ANNOTATION annot) change,
  ) => document.useNativeDocumentHandle(
    (handle) => _withPage(handle, info.pageIndex, (page, _) {
      final annot = pdfium.FPDFPage_GetAnnot(page, info.index);
      if (annot == nullptr) {
        throw const PdfiumException('The annotation is gone');
      }
      try {
        change(annot);
      } finally {
        pdfium.FPDFPage_CloseAnnot(annot);
      }
    }),
  );

  /// Runs [use] on page [index] of the document at [handle], with the
  /// origin of the page's visible box (what pdfrx coordinates are relative
  /// to).
  static T _withPage<T>(
    int handle,
    int index,
    T Function(pdfium_bindings.FPDF_PAGE page, Offset origin) use,
  ) => NativeDocument.borrow(handle).withPage(index, (page) {
    final origin = using((arena) {
      final rect = arena<FS_RECTF>();
      if (pdfium.FPDF_GetPageBoundingBox(page, rect) == 0) return Offset.zero;
      return Offset(
        math.min(rect.ref.left, rect.ref.right),
        math.min(rect.ref.bottom, rect.ref.top),
      );
    });
    return use(page, origin);
  });

  static void _setColor(pdfium_bindings.FPDF_ANNOTATION annot, Color color) {
    pdfium.FPDFAnnot_SetColor(
      annot,
      pdfium_bindings.FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color,
      (color.r * 255).round(),
      (color.g * 255).round(),
      (color.b * 255).round(),
      (color.a * 255).round(),
    );
  }

  static Color _getColor(pdfium_bindings.FPDF_ANNOTATION annot, Arena arena) {
    final c = arena<UnsignedInt>(4);
    final ok = pdfium.FPDFAnnot_GetColor(
      annot,
      pdfium_bindings.FPDFANNOT_COLORTYPE.FPDFANNOT_COLORTYPE_Color,
      c,
      c + 1,
      c + 2,
      c + 3,
    );
    if (ok == 0) return const Color(0xFFFFEB3B);
    return Color.fromARGB(c[3], c[0], c[1], c[2]);
  }

  static String _getString(
    pdfium_bindings.FPDF_ANNOTATION annot,
    String key,
    Arena arena,
  ) {
    final k = key.toNativeUtf8(allocator: arena).cast<Char>();
    final size = pdfium.FPDFAnnot_GetStringValue(annot, k, nullptr, 0);
    if (size <= 2) return '';
    final buffer = arena<Uint8>(size);
    pdfium.FPDFAnnot_GetStringValue(annot, k, buffer.cast(), size);
    return readWideString(buffer.cast(), size);
  }

  static void _setRect(
    pdfium_bindings.FPDF_ANNOTATION annot,
    PdfRect bounds,
    Offset origin,
    Arena arena,
  ) {
    final rect = arena<FS_RECTF>();
    rect.ref
      ..left = bounds.left + origin.dx
      ..right = bounds.right + origin.dx
      ..top = bounds.top + origin.dy
      ..bottom = bounds.bottom + origin.dy;
    pdfium.FPDFAnnot_SetRect(annot, rect);
  }

  static void _setDate(pdfium_bindings.FPDF_ANNOTATION annot, Arena arena) {
    final now = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final date =
        "D:${now.year}${two(now.month)}${two(now.day)}"
        "${two(now.hour)}${two(now.minute)}${two(now.second)}Z";
    pdfium.FPDFAnnot_SetStringValue(
      annot,
      'M'.toNativeUtf8(allocator: arena).cast(),
      wideString(date, arena),
    );
  }
}
