import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folder/core/services/local_content_server.dart';
import 'package:path_provider/path_provider.dart';

import '../book/book_source.dart';
import '../book/document_preparer.dart';
import '../book/html_text.dart';
import 'reader_assets.dart';

/// Serves one open book to the reader WebView through the shared loopback
/// [LocalContentServer], so relative CSS/image/font/SVG references resolve
/// naturally.
///
/// Spine documents are loaded through virtual siblings
/// (`chapter.xhtml__er.xhtml` / `__er.html`) whose extension picks the
/// parser (XHTML vs HTML) and whose markup carries the injected reader.
class ReaderSession {
  ReaderSession(this.source) {
    final spine = source.info.spine;
    for (var i = 0; i < spine.length; i++) {
      _spineByPath.putIfAbsent(spine[i].path.toLowerCase(), () => i);
    }
  }

  final BookSource source;
  final Map<String, int> _spineByPath = {};
  final Map<int, PreparedDocument> _prepared = {};
  final Map<int, Future<PreparedDocument>> _preparing = {};
  final Set<int> _forceHtml = {};
  Uri? _base;
  bool _disposed = false;

  /// Config JSON inlined into the next served document.
  String configJson = 'null';

  static const xhtmlSuffix = '__er.xhtml';
  static const htmlSuffix = '__er.html';
  static const _maxCached = 8;

  static Future<String?>? _cacheDir;

  /// Directory for the parsed-structure cache (resolved once per process;
  /// null if unavailable).
  static Future<String?> cacheDirectory() => _cacheDir ??= () async {
        try {
          final base = await getApplicationCacheDirectory();
          return '${base.path}${Platform.pathSeparator}ebook_structure';
        } catch (_) {
          return null;
        }
      }();

  Uri get base => _base!;

  Future<Uri> start() async {
    return _base ??= await LocalContentServer.instance.mount(_resolve);
  }

  void dispose() {
    _disposed = true;
    final b = _base;
    if (b != null) LocalContentServer.instance.unmount(b);
    _base = null;
    _prepared.clear();
  }

  /// Encodes a config map so it can sit inside an inline script/CDATA.
  static String encodeConfig(Map<String, dynamic> config) => jsonEncode(config)
      .replaceAll('<', r'<')
      .replaceAll('>', r'>')
      .replaceAll('&', r'&')
      .replaceAll(String.fromCharCode(0x2028), r' ')
      .replaceAll(String.fromCharCode(0x2029), r' ');

  int? spineIndexForPath(String path) {
    final canonical = source.canonicalPath(path) ?? path;
    return _spineByPath[canonical.toLowerCase()];
  }

  /// Retries [index] with the forgiving HTML parser. Returns false if it
  /// was already rendered as HTML.
  bool forceHtml(int index) {
    if (!_forceHtml.add(index)) return false;
    _prepared.remove(index);
    return true;
  }

  /// Prepares spine [index] (cached; concurrent calls share the work). Safe
  /// to call before [start].
  Future<PreparedDocument> prepare(int index) {
    final cached = _prepared.remove(index);
    if (cached != null) {
      _prepared[index] = cached; // most recently used
      return Future.value(cached);
    }
    return _preparing[index] ??=
        _doPrepare(index).whenComplete(() => _preparing.remove(index));
  }

  Future<PreparedDocument> _doPrepare(int index) async {
    final item = source.info.spine[index];
    final doc = await source.prepare(
      item.path,
      DocumentPrepareRequest(
        bytes: Uint8List(0),
        path: item.path,
        mediaType: item.mediaType,
        readerCss: kReaderCss,
        readerJs: kReaderJs,
        fixedLayout: item.fixedLayout,
        forceHtml: _forceHtml.contains(index),
      ),
    );
    if (_disposed) return doc;
    _prepared[index] = doc;
    while (_prepared.length > _maxCached) {
      _prepared.remove(_prepared.keys.first);
    }
    return doc;
  }

  /// URL the WebView loads for spine [index].
  Uri documentUrl(int index, PreparedDocument doc) {
    final path = source.info.spine[index].path;
    final suffix = doc.xhtml ? xhtmlSuffix : htmlSuffix;
    return Uri.parse('$base${BookPaths.encode(path)}$suffix');
  }

  /// Maps a URL inside this book back to `(spineIndex?, path, fragment)`.
  (int?, String, String?)? resolveBookUrl(Uri url) {
    final b = _base;
    if (b == null ||
        url.host != b.host ||
        url.port != b.port ||
        !url.path.startsWith(b.path)) {
      return null;
    }
    var rel = url.path
        .substring(b.path.length)
        .split('/')
        .map(BookPaths.safeDecode)
        .join('/');
    for (final s in const [xhtmlSuffix, htmlSuffix]) {
      if (rel.endsWith(s)) rel = rel.substring(0, rel.length - s.length);
    }
    final fragment =
        url.fragment.isEmpty ? null : BookPaths.safeDecode(url.fragment);
    return (spineIndexForPath(rel), rel, fragment);
  }

  Future<Uint8List?> _resolve(String path) async {
    for (final suffix in const [xhtmlSuffix, htmlSuffix]) {
      if (!path.endsWith(suffix)) continue;
      final index = spineIndexForPath(path.substring(0, path.length - suffix.length));
      if (index == null) break;
      try {
        final doc = await prepare(index);
        return doc.withConfig(configJson);
      } catch (e) {
        return Uint8List.fromList(utf8.encode(
          '<!DOCTYPE html><html><body><p>${HtmlText.escape('$e')}</p></body></html>',
        ));
      }
    }
    try {
      return await source.readResource(path);
    } catch (_) {
      return null;
    }
  }
}
