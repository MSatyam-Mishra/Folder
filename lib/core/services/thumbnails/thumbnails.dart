import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/core/formats/design_preview.dart';
import 'package:explorer/core/formats/raw_preview.dart';
import 'package:explorer/core/services/thumbnails/windows_shell_thumbnail.dart';
import 'package:explorer/features/viewer_design/services/design_pdf_renderer.dart';
import 'package:image/image.dart' as img;

/// Pictures of files for the file list, in place of their icons: the ones
/// File Explorer shows on Windows (photos, videos, and documents whose app
/// makes them), and everywhere the previews files carry (Office and
/// OpenDocument files, camera raws, design files), PDFs' first pages and
/// images Flutter can't decode itself (TIFF, PSD...).
///
/// A few are made at a time; results (and files without one) are kept for
/// the session.
abstract final class Thumbnails {
  /// Off in widget tests: no isolates or PDF engine there.
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Images Flutter decodes itself, shown straight from the file.
  static bool decodesDirectly(String path) {
    final ext = FileTypes.extensionOf(path);
    if (_direct.contains(ext)) return true;
    // Apple's and Android's codecs read HEIF and AVIF.
    return (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) && _heif.contains(ext);
  }

  static const _direct = {'jpg', 'jpeg', 'jfif', 'pjpeg', 'png', 'apng', 'gif', 'webp', 'bmp', 'wbmp', 'ico'};
  static const _heif = {'heic', 'heif', 'avif'};

  /// Whether a picture may exist for [path] (without looking at it).
  static bool mayHave(String path) {
    if (!enabled) return false;
    final kind = FileTypes.kindOf(path);
    if (Platform.isWindows && _windowsKinds.contains(kind)) return true;
    return _ownKinds.contains(kind) || _office.contains(FileTypes.extensionOf(path));
  }

  /// Types Windows (or the apps that read them) may have pictures for.
  static const _windowsKinds = {
    FileKind.image, FileKind.rasterImage, FileKind.cameraRaw, FileKind.video, FileKind.pdf,
    FileKind.word, FileKind.spreadsheet, FileKind.presentation, FileKind.design, FileKind.epub,
    FileKind.model3d, FileKind.svg, FileKind.legacyWord, FileKind.legacySpreadsheet,
    FileKind.legacyPresentation, FileKind.openDocumentText, FileKind.openDocumentSpreadsheet,
    FileKind.openDocumentPresentation,
  };

  /// Types this app makes pictures of itself.
  static const _ownKinds = {FileKind.rasterImage, FileKind.cameraRaw, FileKind.pdf, FileKind.design, FileKind.image};

  /// Office and OpenDocument files, which may carry a preview.
  static const _office = {
    'docx', 'docm', 'dotx', 'xlsx', 'xlsm', 'xltx', 'pptx', 'pptm', 'ppsx', 'potx',
    'odt', 'ott', 'ods', 'ots', 'odp', 'otp', 'odg',
  };

  static final _cache = <String, Uint8List?>{}; // in order of use
  static const _cacheSize = 600;
  static final _pending = <String, Future<Uint8List?>>{};
  static final _queue = Queue<_Job>();
  static int _running = 0;
  static const _parallel = 3;

  /// JPEG or PNG bytes for [path], [size] pixels on the long side, or null
  /// when there's no picture. [wanted] is asked before the work starts:
  /// rows scrolled away by then are skipped.
  static Future<Uint8List?> load(String path, int size, {bool Function()? wanted}) async {
    if (!mayHave(path)) return null;
    final FileStat stat;
    try {
      stat = await File(path).stat();
    } on FileSystemException {
      return null;
    }
    // Sizes go up in steps, so a row and a tile can share one.
    final step = size <= 96 ? 96 : (size <= 256 ? 256 : 512);
    final key = '$path|${stat.modified.millisecondsSinceEpoch}|${stat.size}|$step';
    if (_cache.containsKey(key)) {
      final hit = _cache.remove(key);
      _cache[key] = hit; // most recent last
      return hit;
    }
    final running = _pending[key];
    if (running != null) return running;
    final job = _Job(path, step, wanted);
    _queue.add(job);
    final future = job.done.future.then((bytes) {
      _pending.remove(key);
      // Skipped (scrolled away): try again next time.
      if (!job.skipped) {
        _cache[key] = bytes;
        while (_cache.length > _cacheSize) {
          _cache.remove(_cache.keys.first);
        }
      }
      return bytes;
    });
    _pending[key] = future;
    _next();
    return future;
  }

  static void _next() {
    while (_running < _parallel && _queue.isNotEmpty) {
      // The newest first: what's on screen now.
      final job = _queue.removeLast();
      if (job.wanted != null && !job.wanted!()) {
        job.skipped = true;
        job.done.complete(null);
        continue;
      }
      _running++;
      _make(job.path, job.size).catchError((Object _) => null).then((bytes) {
        _running--;
        job.done.complete(bytes);
        _next();
      });
    }
  }

  static Future<Uint8List?> _make(String path, int size) async {
    if (Platform.isWindows) {
      final shell = await Isolate.run(() => windowsShellThumbnail(path, size));
      if (shell != null) return shell;
    }
    final ext = FileTypes.extensionOf(path);
    switch (FileTypes.kindOf(path)) {
      case FileKind.pdf:
        return _pdf(path, size);
      case FileKind.rasterImage:
        return Isolate.run(() => _decoded(path, size));
      case FileKind.cameraRaw:
        return Isolate.run(() => RawPreview.previewImage(path, minLongSide: size));
      case FileKind.design:
        final preview = await Isolate.run(() => DesignPreviewReader.read(path));
        if (preview.image != null) return preview.image;
        return preview.pdfCompatible ? _pdf(path, size) : null;
      default:
        if (_office.contains(ext)) return Isolate.run(() => _officePreview(path));
        return null;
    }
  }

  /// Page 1 of a PDF, as PNG.
  static Future<Uint8List?> _pdf(String path, int size) async {
    final image = await DesignPdfRenderer.renderFirstPage(path, maxSide: size);
    if (image == null) return null;
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Images only the `image` package reads (TIFF, TGA, PSD...), made small.
  static Uint8List? _decoded(String path, int size) {
    final file = File(path);
    // Big files would take long and much memory for a small picture.
    if (file.lengthSync() > 64 << 20) return null;
    final image = img.decodeImage(file.readAsBytesSync());
    if (image == null) return null;
    final scaled = image.width >= image.height
        ? img.copyResize(image, width: size.clamp(1, image.width))
        : img.copyResize(image, height: size.clamp(1, image.height));
    return image.hasAlpha ? img.encodePng(scaled, level: 1) : img.encodeJpg(scaled, quality: 85);
  }

  /// The preview Office saves in docProps/ and OpenDocument in
  /// Thumbnails/ (JPEG or PNG; Windows metafiles are skipped).
  static Uint8List? _officePreview(String path) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      for (final name in const [
        'docProps/thumbnail.jpeg',
        'docProps/thumbnail.jpg',
        'docProps/thumbnail.png',
        'Thumbnails/thumbnail.png',
      ]) {
        final entry = archive.findFile(name);
        if (entry == null) continue;
        final bytes = entry.content;
        if (bytes is List<int> && bytes.isNotEmpty) return Uint8List.fromList(bytes);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      input.closeSync();
    }
  }
}

class _Job {
  _Job(this.path, this.size, this.wanted);

  final String path;
  final int size;
  final bool Function()? wanted;
  final done = Completer<Uint8List?>();
  bool skipped = false;
}
