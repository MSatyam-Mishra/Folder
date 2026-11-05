import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:folder/core/files/file_types.dart';
import 'package:folder/core/services/http_range.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Resolves a mount-relative path (no leading slash, `/` separated) to bytes,
/// or null for 404.
typedef ContentResolver = FutureOr<Uint8List?> Function(String path);

/// A loopback-only HTTP server that lets WebView-based viewers load local
/// content with working relative URLs (EPUB CSS/images/fonts, glTF `.bin`
/// buffers, OBJ `.mtl` materials and textures, bundled JS libraries...).
///
/// Every URL carries a random per-run token and a random mount id, so other
/// apps on the device can't enumerate files through the port.
///
/// Files from [mountDirectory] are streamed from disk (never read whole
/// into memory) and honour HTTP `Range` requests, so video seeking and large
/// models start immediately. Bundled assets from [mountAssets] are served
/// with long-lived cache headers from one stable mount per prefix, so the
/// WebView can reuse (and keep compiled) libraries like three.js between
/// opens. Everything else is `no-store`, so edited user files are never
/// served stale.
///
/// ```dart
/// final server = LocalContentServer.instance;
/// final viewer = await server.mountAssets('assets/viewer3d');
/// final model = await server.mountDirectory(file.parent.path);
/// webView.loadUrl(viewer.resolve('index.html?src=${model.resolve(name)}'));
/// // later, in dispose():
/// server.unmount(model);
/// ```
class LocalContentServer {
  LocalContentServer._();

  static final LocalContentServer instance = LocalContentServer._();

  static const _noStore = 'no-store';
  static const _immutable = 'public, max-age=31536000, immutable';

  HttpServer? _server;
  Future<HttpServer>? _starting;
  final String _token = _randomId(24);
  final Map<String, _Mount> _mounts = {};
  final Map<String, Future<Uri>> _assetMounts = {};

  Future<HttpServer> _ensureStarted() {
    final running = _server;
    if (running != null) return Future.value(running);
    return _starting ??= shelf_io
        .serve(_handle, InternetAddress.loopbackIPv4, 0)
        .then((server) {
      // Only applies to responses without a Content-Length (none of ours),
      // so ranges are never compressed.
      server.autoCompress = true;
      _server = server;
      return server;
    }).whenComplete(() => _starting = null);
  }

  /// File types a web page needs for its own rendering: markup, styles,
  /// scripts, images, fonts and media. Documents, databases, archives etc.
  /// next to the page are not included.
  static const webPageExtensions = {
    'html', 'htm', 'xhtml', 'shtml', 'css', 'js', 'mjs', 'json', 'map',
    'xml', 'svg', 'png', 'jpg', 'jpeg', 'jfif', 'gif', 'webp', 'bmp', 'ico',
    'avif', 'apng', 'woff', 'woff2', 'ttf', 'otf', 'eot', 'mp4', 'webm',
    'ogg', 'ogv', 'oga', 'mp3', 'wav', 'm4a', 'aac', 'flac', 'vtt', 'wasm',
  };

  /// File types a rendered Markdown document can embed.
  static const imageAndMediaExtensions = {
    'svg', 'png', 'jpg', 'jpeg', 'jfif', 'gif', 'webp', 'bmp', 'ico', 'avif',
    'apng', 'mp4', 'webm', 'ogg', 'ogv', 'oga', 'mp3', 'wav', 'm4a',
  };

  /// Serves files under [rootDir]; requests can't escape the directory.
  ///
  /// When [allowedExtensions] (lower-case, no dot) is given, only files with
  /// those extensions are served and everything else is a 404. Viewers that
  /// render untrusted pages should pass the narrowest set they need, so page
  /// scripts can't read unrelated files that happen to sit nearby.
  Future<Uri> mountDirectory(String rootDir, {Set<String>? allowedExtensions}) {
    final root = p.normalize(p.absolute(rootDir));
    return _mount(_Mount(
      (path) async {
        if (allowedExtensions != null &&
            !allowedExtensions.contains(FileTypes.extensionOf(path))) {
          return null;
        }
        final target = p.normalize(p.join(root, p.joinAll(path.split('/'))));
        if (target != root && !p.isWithin(root, target)) return null;
        final file = File(target);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) return null;
        return _FileContent(file, stat.size);
      },
      cacheControl: _noStore,
    ));
  }

  /// Serves Flutter assets under [assetPrefix] (e.g. `assets/viewer3d`).
  ///
  /// Assets can't change while the app runs, so every call for the same
  /// prefix returns the same base URL and responses are cacheable; the
  /// WebView then reuses its cached (and compiled) copies on the next open.
  /// [unmount] is a no-op for these shared mounts.
  Future<Uri> mountAssets(String assetPrefix) {
    final prefix = assetPrefix.endsWith('/') ? assetPrefix : '$assetPrefix/';
    final existing = _assetMounts[prefix];
    if (existing != null) return existing;
    final future = _mount(_Mount(
      (path) async {
        try {
          final data = await rootBundle.load('$prefix$path');
          return _BytesContent(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        } catch (_) {
          return null;
        }
      },
      cacheControl: _immutable,
      shared: true,
    ));
    _assetMounts[prefix] = future;
    future.catchError((Object _) {
      _assetMounts.remove(prefix);
      return Uri();
    });
    return future;
  }

  /// Serves an in-memory map of files (e.g. an unpacked archive).
  Future<Uri> mountMemory(Map<String, Uint8List> files) =>
      mount((path) => files[path]);

  /// Registers a custom [resolver]; returns the mount's base URL (ending in
  /// `/`). Resolve relative paths against it with [Uri.resolve].
  ///
  /// Responses are `no-store` unless [immutable] is true, which marks them
  /// cacheable for as long as the app runs (only for content that can't
  /// change behind the same URL).
  Future<Uri> mount(ContentResolver resolver, {bool immutable = false}) =>
      _mount(_Mount(
        (path) async {
          final bytes = await resolver(path);
          return bytes == null ? null : _BytesContent(bytes);
        },
        cacheControl: immutable ? _immutable : _noStore,
      ));

  Future<Uri> _mount(_Mount mount) async {
    final server = await _ensureStarted();
    final id = _randomId(12);
    _mounts[id] = mount;
    return Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/$_token/$id/',
    );
  }

  /// Removes a mount created by one of the `mount*` methods.
  void unmount(Uri base) {
    final segments = base.pathSegments;
    if (segments.length < 2) return;
    final mount = _mounts[segments[1]];
    if (mount == null || mount.shared) return;
    _mounts.remove(segments[1]);
  }

  Future<Response> _handle(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405);
    }
    final segments = request.url.pathSegments;
    if (segments.length < 3 || segments[0] != _token) {
      return Response.notFound(null);
    }
    final mount = _mounts[segments[1]];
    if (mount == null) return Response.notFound(null);

    final path = segments.sublist(2).join('/');
    try {
      final content = await mount.resolve(path);
      if (content == null) return Response.notFound(null);
      final length = content.length;
      final headers = <String, String>{
        HttpHeaders.contentTypeHeader: _contentType(path),
        HttpHeaders.cacheControlHeader: mount.cacheControl,
        HttpHeaders.acceptRangesHeader: 'bytes',
      };

      var start = 0, end = length, status = 200;
      final rangeHeader = request.headers[HttpHeaders.rangeHeader];
      if (rangeHeader != null) {
        final range = parseByteRange(rangeHeader, length);
        if (range == unsatisfiableRange) {
          return Response(
            416,
            headers: {HttpHeaders.contentRangeHeader: 'bytes */$length'},
          );
        }
        if (range != null) {
          (start, end) = range;
          status = 206;
          headers[HttpHeaders.contentRangeHeader] =
              'bytes $start-${end - 1}/$length';
        }
      }
      headers[HttpHeaders.contentLengthHeader] = '${end - start}';
      return Response(
        status,
        body: request.method == 'HEAD' ? null : content.read(start, end),
        headers: headers,
      );
    } catch (e, st) {
      debugPrint('LocalContentServer: $path failed: $e\n$st');
      return Response.internalServerError();
    }
  }

  static String _contentType(String path) {
    final mime = FileTypes.mimeTypeOf(path);
    return mime.startsWith('text/') ||
            mime.endsWith('javascript') ||
            mime.endsWith('+xml')
        ? '$mime; charset=utf-8'
        : mime;
  }

  static String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }
}

class _Mount {
  _Mount(this.resolve, {required this.cacheControl, this.shared = false});

  final Future<_Content?> Function(String path) resolve;
  final String cacheControl;

  /// Shared by every caller (asset mounts): never removed by [unmount].
  final bool shared;
}

abstract class _Content {
  int get length;

  /// Bytes `[start, end)`.
  Stream<List<int>> read(int start, int end);
}

class _BytesContent implements _Content {
  _BytesContent(this.bytes);

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Stream<List<int>> read(int start, int end) =>
      Stream.value(Uint8List.sublistView(bytes, start, end));
}

class _FileContent implements _Content {
  _FileContent(this.file, this.length);

  final File file;

  @override
  final int length;

  @override
  Stream<List<int>> read(int start, int end) => file.openRead(start, end);
}
