import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// How a scan is saved.
enum ScanFormat {
  /// One PDF with every page.
  pdf,

  /// One JPEG per page.
  jpeg,
}

/// What the scanner made, in the app's cache until saved.
@immutable
class ScanResult {
  const ScanResult({this.pdf, this.pages = const []});

  factory ScanResult.fromMap(Map<Object?, Object?> map) => ScanResult(
        pdf: map['pdf'] as String?,
        pages: [for (final page in (map['pages'] as List?) ?? const []) page as String],
      );

  final String? pdf;
  final List<String> pages;

  int get pageCount => pages.length;
}

/// The scanner couldn't start; [message] says why in plain words.
class ScanUnavailable implements Exception {
  const ScanUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Google's document scanner from Play services (`DocumentScannerNative.kt`,
/// channel `explorer/document_scanner`): it shows the camera, finds the
/// page, straightens and cleans it up. Android only.
abstract final class DocumentScanner {
  @visibleForTesting
  static const channel = MethodChannel('explorer/document_scanner');

  static bool get supported => debugSupported ?? Platform.isAndroid;

  /// In place of the system check, for tests.
  @visibleForTesting
  static bool? debugSupported;

  /// Whether Play services is there to scan with.
  static Future<bool> available() async {
    if (!supported) return false;
    try {
      return await channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the scanner. Null when the user backs out; throws
  /// [ScanUnavailable] when it can't open.
  static Future<ScanResult?> scan(ScanFormat format) async {
    try {
      final map = await channel.invokeMapMethod<Object?, Object?>('scan', {
        'pdf': format == ScanFormat.pdf,
        'jpeg': format == ScanFormat.jpeg,
      });
      return map == null ? null : ScanResult.fromMap(map);
    } on PlatformException catch (e) {
      throw ScanUnavailable(switch (e.code) {
        'unavailable' => "The scanner isn't ready. It comes with Google Play services: check they're up to date and "
            "you're online, then try again.",
        'busy' => 'A scan is already open.',
        _ => "Couldn't scan: ${e.message ?? e.code}",
      });
    } on MissingPluginException {
      throw const ScanUnavailable('The document scanner needs Android.');
    }
  }

  /// "Scan 2026-11-13 14.05", for a scan made at [time].
  static String baseName(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Scan ${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}.${two(time.minute)}';
  }

  /// The names [scan] gets in [folder] as [format], none of them taken:
  /// `Scan 2026-11-13 14.05.pdf`, or `... 1.jpg`, `... 2.jpg` for pages,
  /// with ` (2)` and so on after the time when needed.
  static List<String> namesFor(ScanResult scan, ScanFormat format, String folder, DateTime time) {
    final base = baseName(time);
    List<String> names(String stem) {
      if (format == ScanFormat.pdf) return ['$stem.pdf'];
      if (scan.pageCount <= 1) return ['$stem.jpg'];
      return [for (var i = 1; i <= scan.pageCount; i++) '$stem $i.jpg'];
    }

    for (var n = 1;; n++) {
      final candidate = names(n == 1 ? base : '$base ($n)');
      if (candidate.every((name) => FileSystemEntity.typeSync(p.join(folder, name)) == FileSystemEntityType.notFound)) {
        return candidate;
      }
    }
  }

  /// Copies [scan] into [folder] as [format]; the paths saved. The scanner's
  /// own copies in the cache go afterwards.
  static Future<List<String>> save(ScanResult scan, ScanFormat format, String folder, {DateTime? time}) async {
    final sources = format == ScanFormat.pdf ? [if (scan.pdf != null) scan.pdf!] : scan.pages;
    if (sources.isEmpty) throw const ScanUnavailable('The scanner gave nothing to save.');
    final names = namesFor(scan, format, folder, time ?? DateTime.now());
    final saved = <String>[];
    for (var i = 0; i < sources.length; i++) {
      final target = p.join(folder, names[i]);
      await File(sources[i]).copy(target);
      saved.add(target);
    }
    await _clean(scan);
    return saved;
  }

  static Future<void> _clean(ScanResult scan) async {
    final any = scan.pdf ?? (scan.pages.isEmpty ? null : scan.pages.first);
    if (any == null) return;
    try {
      await File(any).parent.delete(recursive: true);
    } on FileSystemException {
      // The cache is emptied by Android anyway.
    }
  }
}
