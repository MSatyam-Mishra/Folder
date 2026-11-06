import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/file_server/file_server_assets.dart';
import 'package:folders/core/services/file_server/file_server_page.dart';
import 'package:folders/core/services/file_server/lan_address.dart';
import 'package:folders/core/services/file_server/zip_stream.dart';
import 'package:folders/core/services/http_range.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

export 'package:folders/core/services/file_server/file_server_page.dart'
    show WebTheme;

/// What the web pages need from the app: file icons, the font, the logo and
/// image thumbnails.
abstract interface class FileServerResources {
  /// Id of the icon for a file called [name] on a light or [dark] page.
  String iconFor(String name, {required bool dark});

  /// Icon id for folders.
  String get folderIcon;

  /// SVG markup for an id from [iconFor] or [folderIcon].
  Future<String?> iconSvg(String id);

  /// The page font (TrueType), or null to use system fonts.
  Future<Uint8List?> font();

  /// A JPEG of [file] at most [size] pixels on its long side, or null when
  /// the file can't be decoded.
  Future<Uint8List?> thumbnail(File file, int size);
}

/// Shares a folder with browsers on the local network.
///
/// Folders get a page in the app's style (search, sort, list and grid views,
/// a photo/video viewer, ZIP downloads, optional uploads); files are
/// streamed with HTTP range support, so videos seek and downloads resume.
/// Nothing outside the shared folder can be reached.
class HttpFileServer {
  HttpFileServer({required this.resources});

  final FileServerResources resources;

  static const _assets = '/__explorer';
  static const _immutable = 'public, max-age=31536000, immutable';

  HttpServer? _server;
  late String _root;
  late String _realRoot;
  late String _rootLabel;
  late WebTheme _theme;
  String _deviceName = '';
  List<String> _urls = const [];
  final String _version = _randomId(8);
  final _received = StreamController<String>.broadcast();

  /// Whether browsers may upload files into the shared folder.
  bool get allowUploads => _allowUploads && _only == null;
  set allowUploads(bool value) => _allowUploads = value;
  bool _allowUploads = false;

  /// When set, only these items of the folder are shared (names at its top
  /// level), read-only.
  Set<String>? _only;

  bool get isRunning => _server != null;

  /// Best address to open, e.g. `http://192.168.1.20:8080`.
  String? get url => _urls.isEmpty ? null : _urls.first;

  /// Every address the server can be reached at, best first.
  List<String> get urls => _urls;

  /// Paths of files uploaded from a browser.
  Stream<String> get received => _received.stream;

  /// Starts sharing [directory]; returns [url]. Uses the first free port
  /// from [port].
  Future<String> start(
    String directory, {
    required WebTheme theme,
    String? deviceName,
    bool allowUploads = false,
    int port = 8080,
    Iterable<String>? only,
  }) async {
    await stop();
    _root = p.normalize(p.absolute(directory));
    _only = only == null ? null : {for (final path in only) p.basename(path)};
    try {
      _realRoot = await Directory(_root).resolveSymbolicLinks();
    } on FileSystemException {
      _realRoot = _root;
    }
    _rootLabel = _labelFor(_root);
    _theme = theme;
    _deviceName = deviceName ?? '';
    this.allowUploads = allowUploads;

    HttpServer? server;
    for (final candidate in [for (var i = 0; i < 10; i++) port + i, 0]) {
      try {
        server = await shelf_io.serve(
          _handle,
          InternetAddress.anyIPv4,
          candidate,
          poweredByHeader: null,
        );
        break;
      } on SocketException {
        if (candidate == 0) rethrow;
      }
    }
    server!.autoCompress = true;
    _server = server;
    final addresses = await lanAddresses();
    _urls = [
      for (final ip in addresses.isEmpty ? ['127.0.0.1'] : addresses)
        'http://$ip:${server.port}',
    ];
    return _urls.first;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _urls = const [];
    await server?.close(force: true);
  }

  Future<Response> _handle(Request request) async {
    final path = '/${request.url.path}';
    try {
      if (path == _assets || path.startsWith('$_assets/')) {
        return await _asset(request, path.substring(_assets.length));
      }
      final target = await _resolve(request.url.pathSegments);
      if (target == null) return _error(request, 404);
      final stat = await FileStat.stat(target);
      final isDirectory = stat.type == FileSystemEntityType.directory;
      if (stat.type == FileSystemEntityType.notFound) {
        return _error(request, 404);
      }

      switch (request.method) {
        case 'GET' || 'HEAD':
          if (!isDirectory) return await _file(request, target, stat);
          if (!path.endsWith('/')) {
            final query = request.url.hasQuery ? '?${request.url.query}' : '';
            return Response.found('${request.requestedUri.path}/$query');
          }
          if (request.url.queryParameters.containsKey('zip')) {
            return await _zip(request, target, stat);
          }
          return await _listing(request, target);
        case 'POST'
            when isDirectory &&
                request.url.queryParameters.containsKey('upload'):
          return await _upload(request, target);
        default:
          return Response(405, headers: {'allow': 'GET, HEAD'});
      }
    } catch (e, st) {
      debugPrint('HttpFileServer: $path failed: $e\n$st');
      return _error(request, 500);
    }
  }

  /// Whether [path], listed under [dir], is shared (see [_only]).
  bool _shared(String dir, String path) {
    final only = _only;
    if (only == null || dir != _root) return true;
    return only.contains(p.split(p.relative(path, from: _root)).first);
  }

  /// Maps URL path segments to a path inside the shared folder, or null if
  /// they'd leave it (`..`, encoded slashes, symlinks pointing outside).
  Future<String?> _resolve(List<String> segments) async {
    final parts = <String>[];
    for (final s in segments) {
      if (s.isEmpty) continue;
      if (s == '.' ||
          s == '..' ||
          s.contains('/') ||
          s.contains(r'\') ||
          s.contains('\u0000')) {
        return null;
      }
      parts.add(s);
    }
    final target = p.joinAll([_root, ...parts]);
    if (target != _root && !p.isWithin(_root, target)) return null;
    if (_only != null && parts.isNotEmpty && !_only!.contains(parts.first)) return null;
    try {
      final real = await File(target).resolveSymbolicLinks();
      if (real != _realRoot && !p.isWithin(_realRoot, real)) return null;
    } on FileSystemException {
      return null;
    }
    return target;
  }

  Future<Response> _listing(Request request, String dir) async {
    final entities = await Directory(dir)
        .list(followLinks: false)
        .handleError((Object _) {})
        .where((e) => _shared(dir, e.path))
        .toList();
    final countChildren = entities.length <= 400;
    final entries =
        (await Future.wait(
          entities.map((entity) async {
            try {
              final stat = await entity.stat();
              final name = p.basename(entity.path);
              return switch (stat.type) {
                FileSystemEntityType.directory => PageEntry(
                  name: name,
                  isDirectory: true,
                  size: 0,
                  modified: stat.modified,
                  icon: _assetUrl('icon/${resources.folderIcon}.svg'),
                  iconDark: _assetUrl('icon/${resources.folderIcon}.svg'),
                  children: countChildren
                      ? await _countChildren(entity.path)
                      : null,
                  kind: 'folder',
                  action: EntryAction.browse,
                ),
                FileSystemEntityType.file => _fileEntry(name, stat),
                _ => null,
              };
            } catch (_) {
              return null;
            }
          }),
        )).nonNulls.toList()..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

    final relative = p.split(p.relative(dir, from: _root));
    final parts = relative.length == 1 && relative.first == '.'
        ? const <String>[]
        : relative;
    final crumbs = [const Crumb('', '/')];
    var href = '/';
    for (final part in parts) {
      href += '${Uri.encodeComponent(part)}/';
      crumbs.add(Crumb(part, href));
    }
    crumbs[0] = Crumb(_rootLabel, '/');

    final html = renderDirectoryPage(
      title: parts.isEmpty ? _rootLabel : parts.last,
      crumbs: crumbs,
      entries: entries,
      uploads: allowUploads,
      theme: _theme,
      assets: _assets,
      version: _version,
      deviceName: _deviceName,
    );
    return _html(request, 200, html);
  }

  PageEntry _fileEntry(String name, FileStat stat) {
    final ext = FileTypes.extensionOf(name);
    final href = Uri.encodeComponent(name);
    final version = stat.modified.millisecondsSinceEpoch.toRadixString(36);
    final thumbnail = _thumbnailExtensions.contains(ext) && stat.size > 0
        ? '$href?thumb=360&v=$version'
        : ext == 'svg'
        ? href
        : null;
    final (kind, action) = _nativeImages.contains(ext)
        ? ('image', EntryAction.view)
        : _thumbnailExtensions.contains(ext)
        ? ('image', EntryAction.view)
        : _videos.contains(ext)
        ? ('video', EntryAction.view)
        : _audio.contains(ext)
        ? ('audio', EntryAction.view)
        : _showsInBrowser(name)
        ? ('file', EntryAction.tab)
        : ('file', EntryAction.download);
    return PageEntry(
      name: name,
      isDirectory: false,
      size: stat.size,
      modified: stat.modified,
      icon: _assetUrl('icon/${resources.iconFor(name, dark: false)}.svg'),
      iconDark: _assetUrl('icon/${resources.iconFor(name, dark: true)}.svg'),
      kind: kind,
      action: action,
      thumbnail: thumbnail,
      fullImage: kind == 'image' && !_nativeImages.contains(ext)
          ? '$href?thumb=2048&v=$version'
          : null,
    );
  }

  static Future<int?> _countChildren(String dir) async {
    try {
      return await Directory(
        dir,
      ).list(followLinks: false).length.timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  Future<Response> _file(Request request, String path, FileStat stat) async {
    final query = request.url.queryParameters;
    if (query.containsKey('thumb')) {
      return _thumbnail(request, path, stat, int.tryParse(query['thumb']!));
    }
    final length = stat.size;
    final etag =
        '"${length.toRadixString(36)}-'
        '${stat.modified.millisecondsSinceEpoch.toRadixString(36)}"';
    final headers = <String, String>{
      HttpHeaders.contentTypeHeader: _contentType(path),
      HttpHeaders.acceptRangesHeader: 'bytes',
      HttpHeaders.lastModifiedHeader: HttpDate.format(stat.modified),
      HttpHeaders.etagHeader: etag,
      HttpHeaders.cacheControlHeader: 'no-cache',
      'content-disposition': _disposition(
        p.basename(path),
        attachment: query.containsKey('download'),
      ),
      'x-content-type-options': 'nosniff',
      // Pages and SVGs from the folder can't script this page or upload.
      if (_activeContent.contains(FileTypes.extensionOf(path)))
        'content-security-policy':
            'sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads',
    };
    final rangeHeader = request.headers[HttpHeaders.rangeHeader];
    if (rangeHeader == null &&
        request.headers[HttpHeaders.ifNoneMatchHeader] == etag) {
      return Response.notModified(headers: {HttpHeaders.etagHeader: etag});
    }

    var start = 0, end = length, status = 200;
    if (rangeHeader != null &&
        (request.headers[HttpHeaders.ifRangeHeader] ?? etag) == etag) {
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
      body: request.method == 'HEAD' || start == end
          ? null
          : File(path).openRead(start, end),
      headers: headers,
    );
  }

  Future<Response> _thumbnail(
    Request request,
    String path,
    FileStat stat,
    int? size,
  ) async {
    final ext = FileTypes.extensionOf(path);
    if (!_thumbnailExtensions.contains(ext) || stat.size > 80 << 20) {
      return Response.notFound(null);
    }
    final bytes = await resources.thumbnail(
      File(path),
      (size ?? 360).clamp(64, 2048),
    );
    if (bytes == null) return Response.notFound(null);
    return Response.ok(
      request.method == 'HEAD' ? null : bytes,
      headers: {
        HttpHeaders.contentTypeHeader: 'image/jpeg',
        HttpHeaders.contentLengthHeader: '${bytes.length}',
        HttpHeaders.cacheControlHeader: 'private, max-age=86400',
      },
    );
  }

  Future<Response> _zip(Request request, String dir, FileStat stat) async {
    final label = dir == _root ? _rootLabel : p.basename(dir);
    final entries = <ZipStreamEntry>[
      ZipStreamEntry.directory(label, stat.modified),
    ];
    final listing = Directory(dir)
        .list(recursive: true, followLinks: false)
        .handleError((Object _) {})
        .where((e) => _shared(dir, e.path));
    await for (final entity in listing) {
      if (entity is Link) continue;
      final name =
          '$label/${p.split(p.relative(entity.path, from: dir)).join('/')}';
      try {
        final s = await entity.stat();
        if (entity is Directory) {
          entries.add(ZipStreamEntry.directory(name, s.modified));
        } else if (entity is File) {
          entries.add(ZipStreamEntry.file(name, entity, s.size, s.modified));
        }
      } on FileSystemException {
        // Unreadable: leave it out.
      }
    }
    final zip = ZipStream(entries);
    return Response.ok(
      request.method == 'HEAD' ? null : zip.stream(),
      headers: {
        HttpHeaders.contentTypeHeader: 'application/zip',
        HttpHeaders.contentLengthHeader: '${zip.length}',
        HttpHeaders.cacheControlHeader: 'no-store',
        'content-disposition': _disposition('$label.zip', attachment: true),
      },
    );
  }

  Future<Response> _upload(Request request, String dir) async {
    if (!allowUploads) {
      return _json(403, {'error': 'Uploads are turned off on the phone'});
    }
    // Only this page may upload: a custom header can't be sent cross-site
    // without a CORS preflight, which this server never approves.
    final origin = request.headers['origin'];
    if (origin != null &&
        Uri.tryParse(origin)?.authority != request.requestedUri.authority) {
      return _json(403, {'error': 'Not allowed'});
    }
    final rawName = request.headers['x-file-name'];
    String? name;
    try {
      name = rawName == null ? null : _safeName(Uri.decodeComponent(rawName));
    } on ArgumentError {
      name = null;
    }
    if (name == null) return _json(400, {'error': 'Invalid file name'});

    final partial = File(p.join(dir, '.$name.${_randomId(6)}.part'));
    final sink = partial.openWrite();
    try {
      await sink.addStream(request.read());
      await sink.close();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        await partial.delete();
      } catch (_) {}
      return _json(500, {'error': 'Upload interrupted'});
    }
    final target = await _unusedPath(dir, name);
    await partial.rename(target);
    _received.add(target);
    return _json(201, {'name': p.basename(target)});
  }

  Future<Response> _asset(Request request, String path) async {
    final (String type, Object? body) = switch (path) {
      '/app.css' => ('text/css; charset=utf-8', fileServerCss),
      '/app.js' => ('text/javascript; charset=utf-8', fileServerJs),
      '/logo.svg' => ('image/svg+xml', _logo),
      '/geist.ttf' => ('font/ttf', await resources.font()),
      _ when path.startsWith('/icon/') && path.endsWith('.svg') => (
        'image/svg+xml',
        await resources.iconSvg(
          path.substring('/icon/'.length, path.length - '.svg'.length),
        ),
      ),
      _ => ('', null),
    };
    if (body == null) return Response.notFound(null);
    return Response.ok(
      request.method == 'HEAD'
          ? null
          // A stream (no Content-Length) lets the server gzip text.
          : body is String
          ? Stream.value(utf8.encode(body))
          : body,
      headers: {
        HttpHeaders.contentTypeHeader: type,
        HttpHeaders.cacheControlHeader: _immutable,
        'x-content-type-options': 'nosniff',
      },
    );
  }

  Response _error(Request request, int status) {
    final (title, message) = switch (status) {
      404 => (
        'Not found',
        'This file or folder doesn’t exist, or is outside the shared folder.',
      ),
      _ => ('Something went wrong', 'The phone couldn’t open this. Try again.'),
    };
    if (!(request.headers['accept'] ?? '').contains('text/html')) {
      return Response(status, body: title);
    }
    return _html(
      request,
      status,
      renderMessagePage(
        status: status,
        title: title,
        message: message,
        theme: _theme,
        assets: _assets,
        version: _version,
        deviceName: _deviceName,
      ),
    );
  }

  Response _html(Request request, int status, String html) => Response(
    status,
    body: request.method == 'HEAD' ? null : Stream.value(utf8.encode(html)),
    headers: {
      HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
      HttpHeaders.cacheControlHeader: 'no-store',
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
    },
  );

  static Response _json(int status, Map<String, Object?> body) => Response(
    status,
    body: jsonEncode(body),
    headers: {HttpHeaders.contentTypeHeader: 'application/json'},
  );

  String _assetUrl(String path) => '$_assets/$path?v=$_version';

  static String _labelFor(String path) {
    final name = p.basename(path);
    if (name.isEmpty || name == '0' || name == p.separator) {
      return 'Internal storage';
    }
    return name;
  }

  /// [name] without path parts or characters file systems reject, or null
  /// if nothing usable is left.
  static String? _safeName(String name) {
    final base = name.split(RegExp(r'[/\\]')).last;
    final cleaned = base
        .replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
    return cleaned.length > 200
        ? cleaned.substring(cleaned.length - 200)
        : cleaned;
  }

  /// `photo.jpg`, or `photo (1).jpg` etc. if that's taken.
  static Future<String> _unusedPath(String dir, String name) async {
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var candidate = p.join(dir, name);
    for (
      var i = 1;
      await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.notFound;
      i++
    ) {
      candidate = p.join(dir, '$stem ($i)$ext');
    }
    return candidate;
  }

  static String _disposition(String name, {required bool attachment}) {
    final ascii = name.replaceAll(RegExp(r'[^\x20-\x7e]|["\\]'), '_');
    return '${attachment ? 'attachment' : 'inline'}; filename="$ascii"; '
        "filename*=UTF-8''${Uri.encodeComponent(name)}";
  }

  static String _contentType(String path) {
    final kind = FileTypes.kindOf(path);
    var mime = FileTypes.mimeTypeOf(path);
    if (mime == 'application/octet-stream') {
      mime = lookupMimeType(path) ?? mime;
    }
    // Show source code and other text in the browser instead of
    // downloading it.
    if (const {
          FileKind.code,
          FileKind.text,
          FileKind.markdown,
        }.contains(kind) &&
        !mime.startsWith('text/html')) {
      mime = 'text/plain';
    }
    return mime.startsWith('text/') ||
            mime.endsWith('javascript') ||
            mime.endsWith('json') ||
            mime.endsWith('+xml')
        ? '$mime; charset=utf-8'
        : mime;
  }

  static bool _showsInBrowser(String name) {
    final type = _contentType(name);
    return type.startsWith('text/') ||
        type.startsWith('application/pdf') ||
        type.startsWith('application/json') ||
        type.startsWith('image/');
  }

  static const _nativeImages = {
    'jpg',
    'jpeg',
    'jfif',
    'pjpeg',
    'png',
    'apng',
    'gif',
    'webp',
    'avif',
    'bmp',
    'ico',
    'svg',
  };

  /// Images the app can make thumbnails of (HEIC: browsers mostly can't
  /// show it, so the viewer gets a converted copy).
  static const _thumbnailExtensions = {
    'jpg',
    'jpeg',
    'jfif',
    'pjpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
  };

  static const _videos = {'mp4', 'm4v', 'webm', 'mov', 'ogv', 'mkv', '3gp'};

  static const _audio = {
    'mp3',
    'm4a',
    'aac',
    'wav',
    'ogg',
    'oga',
    'opus',
    'flac',
    'weba',
  };

  static const _activeContent = {
    'html',
    'htm',
    'xhtml',
    'shtml',
    'svg',
    'svgz',
    'xml',
    'xsl',
    'xslt',
  };

  static String _randomId(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(
        length,
        (_) => chars.codeUnitAt(random.nextInt(chars.length)),
      ),
    );
  }

  /// The app icon (assets/branding/source/icon_rounded.svg).
  static const _logo =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="64 64 896 896"><defs>'
      '<linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#60A5FA"/><stop offset="0.45" stop-color="#2563EB"/><stop offset="1" stop-color="#1E40AF"/></linearGradient>'
      '<radialGradient id="hl" cx="0.25" cy="0.15" r="0.75"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>'
      '<rect x="64" y="64" width="896" height="896" rx="200" fill="url(#g)"/><rect x="64" y="64" width="896" height="896" rx="200" fill="url(#hl)"/>'
      '<g transform="translate(512 512) scale(0.92) translate(-512 -512)">'
      '<path d="M298 300 H420 Q444 300 460 318 L492 352 H726 Q762 352 762 388 V664 Q762 700 726 700 H298 Q262 700 262 664 V336 Q262 300 298 300 Z" fill="#FFFFFF" fill-opacity="0.55"/>'
      '<path d="M330 440 H772 Q812 440 802 478 L754 666 Q745 700 710 700 H280 Q248 700 257 668 L300 466 Q306 440 330 440 Z" fill="#FFFFFF"/>'
      '</g></svg>';
}
