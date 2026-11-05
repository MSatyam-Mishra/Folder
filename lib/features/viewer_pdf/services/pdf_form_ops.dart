import 'dart:ffi' hide Size;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/features/viewer_pdf/services/pdfium_native.dart';
import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium_bindings;
import 'package:pdfrx/pdfrx.dart' show PdfRect;

enum PdfFormFieldType {
  text,
  checkbox,
  radio,
  combo,
  list,
  button,
  signature,
  unknown,
}

/// One widget (on-page box) of an interactive form field.
class PdfFormField {
  const PdfFormField({
    required this.pageIndex,
    required this.annotIndex,
    required this.type,
    required this.name,
    required this.value,
    required this.bounds,
    this.options = const [],
    this.selected = const {},
    this.checked = false,
    this.readOnly = false,
    this.multiline = false,
  });

  final int pageIndex;
  final int annotIndex;
  final PdfFormFieldType type;
  final String name;
  final String value;

  /// In pdfrx page coordinates (unrotated, y up, relative to the page box).
  final PdfRect bounds;
  final List<String> options;
  final Set<int> selected;
  final bool checked;
  final bool readOnly;
  final bool multiline;

  bool get isEditable =>
      !readOnly &&
      const {
        PdfFormFieldType.text,
        PdfFormFieldType.checkbox,
        PdfFormFieldType.radio,
        PdfFormFieldType.combo,
        PdfFormFieldType.list,
      }.contains(type);
}

/// Reads and fills interactive (AcroForm) forms with PDFium's form engine,
/// which also redraws the fields' appearance. Works on bytes, on pdfrx's
/// PDFium worker.
abstract final class PdfFormOps {
  static Future<List<PdfFormField>> fields(Uint8List bytes) =>
      onPdfiumWorker(_fields, bytes);

  static Future<Uint8List> setText(
    Uint8List bytes,
    PdfFormField field,
    String value,
  ) => onPdfiumWorker(_change, (
    bytes: bytes,
    page: field.pageIndex,
    annot: field.annotIndex,
    action: 0,
    text: value,
    option: 0,
  ));

  /// Ticks or unticks a checkbox, or picks a radio button.
  static Future<Uint8List> toggle(Uint8List bytes, PdfFormField field) =>
      onPdfiumWorker(_change, (
        bytes: bytes,
        page: field.pageIndex,
        annot: field.annotIndex,
        action: 1,
        text: '',
        option: 0,
      ));

  static Future<Uint8List> select(
    Uint8List bytes,
    PdfFormField field,
    int option,
  ) => onPdfiumWorker(_change, (
    bytes: bytes,
    page: field.pageIndex,
    annot: field.annotIndex,
    action: 2,
    text: '',
    option: option,
  ));
}

/// A document with a form-fill environment.
T _withForm<T>(
  Uint8List bytes,
  T Function(NativeDocument doc, pdfium_bindings.FPDF_FORMHANDLE form) use,
) {
  final doc = NativeDocument.open(bytes);
  final info = calloc<pdfium_bindings.FPDF_FORMFILLINFO>();
  info.ref.version = 1;
  final form = pdfium.FPDFDOC_InitFormFillEnvironment(doc.handle, info);
  try {
    if (form == nullptr) throw const PdfiumException('This PDF has no form');
    return use(doc, form);
  } finally {
    if (form != nullptr) pdfium.FPDFDOC_ExitFormFillEnvironment(form);
    calloc.free(info);
    doc.close();
  }
}

/// Runs [use] on page [index] with the form loaded for it.
T _formPage<T>(
  NativeDocument doc,
  pdfium_bindings.FPDF_FORMHANDLE form,
  int index,
  T Function(pdfium_bindings.FPDF_PAGE page, ({double x, double y}) origin) use,
) => doc.withPage(index, (page) {
  pdfium.FORM_OnAfterLoadPage(page, form);
  try {
    final origin = using((arena) {
      final rect = arena<FS_RECTF>();
      if (pdfium.FPDF_GetPageBoundingBox(page, rect) == 0) {
        return (x: 0.0, y: 0.0);
      }
      return (
        x: math.min(rect.ref.left, rect.ref.right),
        y: math.min(rect.ref.bottom, rect.ref.top),
      );
    });
    return use(page, origin);
  } finally {
    pdfium.FORM_OnBeforeClosePage(page, form);
  }
});

String _wide(
  int Function(Pointer<pdfium_bindings.FPDF_WCHAR> buffer, int length) read,
  Arena arena,
) {
  final size = read(nullptr, 0);
  if (size <= 2) return '';
  final buffer = arena<Uint8>(size);
  read(buffer.cast(), size);
  return readWideString(buffer.cast(), size);
}

List<PdfFormField> _fields(Uint8List bytes) => _withForm(bytes, (doc, form) {
  final result = <PdfFormField>[];
  for (var p = 0; p < doc.pageCount; p++) {
    _formPage(doc, form, p, (page, origin) {
      using((arena) {
        final rect = arena<FS_RECTF>();
        for (var i = 0; i < pdfium.FPDFPage_GetAnnotCount(page); i++) {
          final annot = pdfium.FPDFPage_GetAnnot(page, i);
          if (annot == nullptr) continue;
          try {
            if (pdfium.FPDFAnnot_GetSubtype(annot) !=
                pdfium_bindings.FPDF_ANNOT_WIDGET) {
              continue;
            }
            if (pdfium.FPDFAnnot_GetRect(annot, rect) == 0) continue;
            final flags = pdfium.FPDFAnnot_GetFormFieldFlags(form, annot);
            final type = switch (pdfium.FPDFAnnot_GetFormFieldType(
              form,
              annot,
            )) {
              pdfium_bindings.FPDF_FORMFIELD_TEXTFIELD => PdfFormFieldType.text,
              pdfium_bindings.FPDF_FORMFIELD_CHECKBOX =>
                PdfFormFieldType.checkbox,
              pdfium_bindings.FPDF_FORMFIELD_RADIOBUTTON =>
                PdfFormFieldType.radio,
              pdfium_bindings.FPDF_FORMFIELD_COMBOBOX => PdfFormFieldType.combo,
              pdfium_bindings.FPDF_FORMFIELD_LISTBOX => PdfFormFieldType.list,
              pdfium_bindings.FPDF_FORMFIELD_PUSHBUTTON =>
                PdfFormFieldType.button,
              pdfium_bindings.FPDF_FORMFIELD_SIGNATURE =>
                PdfFormFieldType.signature,
              _ => PdfFormFieldType.unknown,
            };
            final optionCount = pdfium.FPDFAnnot_GetOptionCount(form, annot);
            final r = rect.ref;
            result.add(
              PdfFormField(
                pageIndex: p,
                annotIndex: i,
                type: type,
                name: _wide(
                  (b, l) =>
                      pdfium.FPDFAnnot_GetFormFieldName(form, annot, b, l),
                  arena,
                ),
                value: _wide(
                  (b, l) =>
                      pdfium.FPDFAnnot_GetFormFieldValue(form, annot, b, l),
                  arena,
                ),
                bounds: PdfRect(
                  math.min(r.left, r.right) - origin.x,
                  math.max(r.top, r.bottom) - origin.y,
                  math.max(r.left, r.right) - origin.x,
                  math.min(r.top, r.bottom) - origin.y,
                ),
                options: [
                  for (var o = 0; o < optionCount; o++)
                    _wide(
                      (b, l) =>
                          pdfium.FPDFAnnot_GetOptionLabel(form, annot, o, b, l),
                      arena,
                    ),
                ],
                selected: {
                  for (var o = 0; o < optionCount; o++)
                    if (pdfium.FPDFAnnot_IsOptionSelected(form, annot, o) != 0)
                      o,
                },
                checked: pdfium.FPDFAnnot_IsChecked(form, annot) != 0,
                readOnly: flags & pdfium_bindings.FPDF_FORMFLAG_READONLY != 0,
                multiline:
                    flags & pdfium_bindings.FPDF_FORMFLAG_TEXT_MULTILINE != 0,
              ),
            );
          } finally {
            pdfium.FPDFPage_CloseAnnot(annot);
          }
        }
      });
    });
  }
  return result;
});

Uint8List _change(
  ({Uint8List bytes, int page, int annot, int action, String text, int option})
  m,
) => _withForm(m.bytes, (doc, form) {
  _formPage(doc, form, m.page, (page, origin) {
    final annot = pdfium.FPDFPage_GetAnnot(page, m.annot);
    if (annot == nullptr) throw const PdfiumException('The field is gone');
    try {
      using((arena) {
        switch (m.action) {
          case 0: // Text.
            pdfium.FORM_SetFocusedAnnot(form, annot);
            pdfium.FORM_SelectAllText(form, page);
            pdfium.FORM_ReplaceSelection(form, page, wideString(m.text, arena));
          case 1: // Click the middle of a checkbox or radio button.
            final rect = arena<FS_RECTF>();
            pdfium.FPDFAnnot_GetRect(annot, rect);
            final x = (rect.ref.left + rect.ref.right) / 2;
            final y = (rect.ref.top + rect.ref.bottom) / 2;
            pdfium.FORM_OnLButtonDown(form, page, 0, x, y);
            pdfium.FORM_OnLButtonUp(form, page, 0, x, y);
          case 2: // Pick a list or combo box option.
            pdfium.FORM_SetFocusedAnnot(form, annot);
            if (pdfium.FORM_SetIndexSelected(form, page, m.option, 1) == 0) {
              throw const PdfiumException('The option could not be picked');
            }
        }
        pdfium.FORM_ForceToKillFocus(form);
      });
    } finally {
      pdfium.FPDFPage_CloseAnnot(annot);
    }
  });
  return doc.save();
});
