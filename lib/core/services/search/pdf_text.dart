import 'package:pdfrx/pdfrx.dart';

/// Reads a PDF's text; null when it can't (damaged, locked by a password).
typedef PdfTextReader = Future<String?> Function(String path);

/// PDFs' text for searching inside them, through pdfrx's PDFium worker:
/// PDFium isn't thread-safe, so the search's isolate can't call it itself
/// and hands PDFs back to the main isolate instead.
abstract final class PdfText {
  /// Sets PDFium up; tests use pdfrx's plain-Dart setup instead.
  static Future<void> Function() initialize = pdfrxFlutterInitialize;

  /// Pages read at most; a long book's first 300 pages are searched.
  static int maxPages = 300;

  /// A PDF that takes longer than this is passed over, so one stuck file
  /// doesn't hold the search up.
  static Duration timeout = const Duration(seconds: 30);

  static Future<String?> read(String path) => _read(path).timeout(timeout, onTimeout: () => null);

  static Future<String?> _read(String path) async {
    PdfDocument? document;
    try {
      await initialize();
      document = await PdfDocument.openFile(path);
      final out = StringBuffer();
      for (final page in document.pages.take(maxPages)) {
        final text = await page.loadText();
        if (text != null) out.writeln(text.fullText);
      }
      return out.toString();
    } catch (_) {
      return null;
    } finally {
      await document?.dispose();
    }
  }
}
