import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/remote/known_hosts.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart' show remoteError;
import 'package:folders/core/services/remote/webdav/http_auth.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:xml/xml.dart';

/// "WebDAV" in "Add a place".
final webdavProtocol = RemoteProtocolInfo(
  protocol: RemoteProtocol.webdav,
  label: 'WebDAV',
  description: 'Nextcloud, ownCloud, NAS, web servers',
  icon: LucideIcons.globe,
  hostHint: 'cloud.example.com, or the whole address',
  options: const [
    RemoteOptionField(
      key: 'https',
      label: 'Secure connection (HTTPS)',
      defaultValue: 'true',
    ),
    RemoteOptionField(
      key: 'path',
      label: 'Address path',
      kind: RemoteOptionKind.text,
      description: "The server's WebDAV address after the host, if any",
      hint: '/remote.php/dav/files/me',
    ),
  ],
  create: (connection, secrets) => WebDavFileSystem(connection, secrets),
);

const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/>'
    '</d:prop></d:propfind>';

/// What the server answered: the status, its headers and, unless streamed,
/// the body.
class _Answer {
  _Answer(this.response, this.body);

  final HttpClientResponse response;
  final String body;

  int get status => response.statusCode;
}

/// [RemoteFileSystem] over WebDAV (HTTP or HTTPS): PROPFIND to list, GET
/// with Range to read (so videos can seek), PUT, MKCOL, DELETE and MOVE;
/// Basic and Digest sign-in. A certificate this device doesn't trust (a
/// NAS's own) can be trusted on first use.
class WebDavFileSystem implements RemoteFileSystem {
  WebDavFileSystem(this.connection, this.secrets, {RemoteKnownHosts? knownHosts})
      : knownHosts = knownHosts ?? RemoteKnownHosts.instance {
    final host = connection.host.trim();
    if (host.contains('://')) {
      final uri = Uri.parse(host);
      _base = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: connection.port ?? (uri.hasPort ? uri.port : null),
        path: _trimSlash(uri.path),
      );
    } else {
      final https = connection.options['https'] != 'false';
      final slash = host.indexOf('/');
      final name = slash < 0 ? host : host.substring(0, slash);
      final extra = slash < 0 ? '' : host.substring(slash);
      final hostPart = Uri.parse('${https ? 'https' : 'http'}://$name');
      _base = Uri(
        scheme: https ? 'https' : 'http',
        host: hostPart.host,
        port: connection.port ?? (hostPart.hasPort ? hostPart.port : null),
        path: _trimSlash('$extra/${connection.options['path'] ?? ''}'),
      );
    }
  }

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;
  final RemoteKnownHosts knownHosts;

  late final Uri _base;
  HttpClient? _client;
  HttpAuthenticator? _auth;
  TlsTrust? _trust;

  /// The server's address for the place's root (`https://host/dav`).
  Uri get baseUri => _base;

  static String _trimSlash(String path) {
    final normal = RemotePaths.normalize(path);
    return normal == '/' ? '' : normal;
  }

  /// The address of [path], with a slash at the end for a folder.
  Uri _uri(String path, {bool folder = false}) {
    final segments = RemotePaths.normalize(path).split('/').where((s) => s.isNotEmpty);
    final base = _base.path;
    final tail = segments.map(Uri.encodeComponent).join('/');
    var full = '$base/$tail';
    if (folder && !full.endsWith('/')) full = '$full/';
    return _base.replace(path: full);
  }

  /// The place's path of a `href` in a PROPFIND answer.
  String? _pathOf(String href) {
    final uri = Uri.tryParse(href.trim());
    if (uri == null) return null;
    final decoded = Uri.decodeComponent(uri.path);
    final base = Uri.decodeComponent(_base.path);
    if (!decoded.startsWith(base)) return null;
    return RemotePaths.normalize(decoded.substring(base.length));
  }

  @override
  Future<void> connect() async {
    await close();
    final password = await secrets.read('password') ?? '';
    _auth = HttpAuthenticator(connection.username, password);
    final trust = _trust = _base.scheme == 'https' ? TlsTrust(_base.host, _base.port, known: knownHosts) : null;
    await trust?.prepare();
    _client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 30)
      ..maxConnectionsPerHost = 4
      ..userAgent = 'Folders'
      ..badCertificateCallback = trust == null ? null : (certificate, host, port) => trust.onBadCertificate(certificate);
    // Signs in now, so a wrong password shows at once.
    await stat('/');
  }

  HttpClient get _http {
    final client = _client;
    if (client == null) throw const RemoteException(RemoteErrorKind.network, 'The connection to the server closed.');
    return client;
  }

  /// Sends a request, answering a sign-in challenge once; [stream] keeps
  /// the body to be read by the caller.
  Future<_Answer> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    bool stream = false,
  }) async {
    for (var attempt = 0;; attempt++) {
      final HttpClientResponse response;
      try {
        final request = await _http.openUrl(method, uri).timeout(const Duration(seconds: 30));
        request.followRedirects = method == 'GET';
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        headers.forEach(request.headers.set);
        final authorization = _auth?.authorization(method, _requestTarget(uri));
        if (authorization != null) request.headers.set(HttpHeaders.authorizationHeader, authorization);
        if (body != null) {
          final bytes = utf8.encode(body);
          request.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          request.contentLength = bytes.length;
          request.add(bytes);
        }
        response = await request.close().timeout(const Duration(seconds: 60));
      } catch (e) {
        throw _trust?.failure() ?? remoteError(e);
      }
      if (response.statusCode == 401 && attempt == 0 && _takeChallenge(response)) {
        await response.drain<void>();
        continue;
      }
      if (stream) return _Answer(response, '');
      final text = await utf8.decodeStream(response).timeout(const Duration(seconds: 60));
      return _Answer(response, text);
    }
  }

  bool _takeChallenge(HttpClientResponse response) {
    final headers = response.headers[HttpHeaders.wwwAuthenticateHeader] ?? const [];
    return _auth?.accept(HttpChallenge.parseAll(headers)) ?? false;
  }

  static String _requestTarget(Uri uri) => uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

  RemoteException _failure(int status, String path, {String what = ''}) {
    final name = RemotePaths.nameOf(path);
    return switch (status) {
      401 => const RemoteException(RemoteErrorKind.auth, 'The server refused the user name or password.'),
      403 => RemoteException(RemoteErrorKind.permission, 'The server didn\'t allow it${name.isEmpty ? '' : ' for "$name"'}.'),
      404 || 410 => RemoteException(RemoteErrorKind.notFound, name.isEmpty ? 'The address was not found on the server.' : '"$name" isn\'t there any more.'),
      405 || 412 => RemoteException(RemoteErrorKind.alreadyExists, '"$name" is already there'),
      409 => RemoteException(RemoteErrorKind.notFound, 'The folder of "$name" isn\'t there any more.'),
      423 => RemoteException(RemoteErrorKind.permission, '"$name" is locked on the server.'),
      507 => const RemoteException(RemoteErrorKind.other, 'The server has no room left.'),
      501 => const RemoteException(RemoteErrorKind.unsupported, "The server can't do that."),
      _ => RemoteException(RemoteErrorKind.other, 'The server answered $status$what.'),
    };
  }

  List<RemoteEntry> _parse(String body) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } catch (_) {
      throw const RemoteException(RemoteErrorKind.other, "The server's answer couldn't be read: is this a WebDAV address?");
    }
    final entries = <RemoteEntry>[];
    for (final response in document.findAllElements('response', namespace: 'DAV:')) {
      final href = response.findElements('href', namespace: 'DAV:').firstOrNull?.innerText;
      final path = href == null ? null : _pathOf(href);
      if (path == null) continue;
      XmlElement? prop;
      for (final propstat in response.findElements('propstat', namespace: 'DAV:')) {
        final status = propstat.findElements('status', namespace: 'DAV:').firstOrNull?.innerText ?? '';
        if (status.contains(' 200')) prop = propstat.findElements('prop', namespace: 'DAV:').firstOrNull;
      }
      if (prop == null) continue;
      final isDirectory = prop
              .findElements('resourcetype', namespace: 'DAV:')
              .firstOrNull
              ?.findElements('collection', namespace: 'DAV:')
              .isNotEmpty ??
          false;
      final size = int.tryParse(prop.findElements('getcontentlength', namespace: 'DAV:').firstOrNull?.innerText.trim() ?? '');
      final modifiedText = prop.findElements('getlastmodified', namespace: 'DAV:').firstOrNull?.innerText.trim();
      DateTime? modified;
      if (modifiedText != null && modifiedText.isNotEmpty) {
        try {
          modified = HttpDate.parse(modifiedText).toLocal();
        } catch (_) {}
      }
      entries.add(RemoteEntry(
        path: path,
        isDirectory: isDirectory,
        size: isDirectory ? 0 : size ?? 0,
        modified: modified,
        mimeType: prop.findElements('getcontenttype', namespace: 'DAV:').firstOrNull?.innerText.trim(),
      ));
    }
    return entries;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final folder = RemotePaths.normalize(path);
    final answer = await _send('PROPFIND', _uri(folder, folder: true), headers: {'Depth': '1'}, body: _propfindBody);
    if (answer.status != 207) throw _failure(answer.status, folder);
    final entries = _parse(answer.body);
    final self = entries.where((e) => e.path == folder).firstOrNull;
    if (self != null && !self.isDirectory) {
      throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(folder)}" isn\'t a folder.');
    }
    return [for (final e in entries) if (e.path != folder && RemotePaths.parentOf(e.path) == folder) e];
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    final normal = RemotePaths.normalize(path);
    final answer = await _send('PROPFIND', _uri(normal, folder: normal == '/'), headers: {'Depth': '0'}, body: _propfindBody);
    if (answer.status != 207) throw _failure(answer.status, normal);
    final entries = _parse(answer.body);
    if (entries.isEmpty) throw _failure(404, normal);
    final e = entries.first;
    return RemoteEntry(path: normal, isDirectory: e.isDirectory, size: e.size, modified: e.modified, mimeType: e.mimeType);
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    final normal = RemotePaths.normalize(path);
    if (end != null && end <= start) return;
    final ranged = start > 0 || end != null;
    final answer = await _send(
      'GET',
      _uri(normal),
      headers: {if (ranged) HttpHeaders.rangeHeader: 'bytes=$start-${end == null ? '' : end - 1}'},
      stream: true,
    );
    final response = answer.response;
    if (answer.status != 200 && answer.status != 206) {
      await response.drain<void>().catchError((_) {});
      if (answer.status == 416) return;
      throw _failure(answer.status, normal);
    }
    // A server that ignores Range sends it all: skipped up to [start].
    var skip = answer.status == 200 ? start : 0;
    int? left = end == null ? null : end - start;
    try {
      await for (final chunk in response.timeout(const Duration(minutes: 2))) {
        var part = chunk;
        if (skip > 0) {
          if (part.length <= skip) {
            skip -= part.length;
            continue;
          }
          part = part.sublist(skip);
          skip = 0;
        }
        if (left != null) {
          if (part.length >= left) {
            if (left > 0) yield part.sublist(0, left);
            left = 0;
            break;
          }
          left -= part.length;
        }
        yield part;
      }
    } catch (e) {
      throw remoteError(e);
    }
  }

  @override
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  }) async {
    final normal = RemotePaths.normalize(path);
    // A stream can't be sent twice: signed in first, if not yet.
    if (!(_auth?.ready ?? false) || !overwrite) {
      try {
        await stat(normal);
        if (!overwrite) {
          throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(normal)}" is already there');
        }
      } on RemoteException catch (e) {
        if (e.kind != RemoteErrorKind.notFound) rethrow;
      }
    }
    final uri = _uri(normal);
    final HttpClientResponse response;
    try {
      final request = await _http.openUrl('PUT', uri).timeout(const Duration(seconds: 30));
      request.followRedirects = false;
      if (!overwrite) request.headers.set(HttpHeaders.ifNoneMatchHeader, '*');
      final authorization = _auth?.authorization('PUT', _requestTarget(uri));
      if (authorization != null) request.headers.set(HttpHeaders.authorizationHeader, authorization);
      request.headers.contentType = ContentType.binary;
      if (length != null) {
        request.contentLength = length;
      } else {
        request.headers.chunkedTransferEncoding = true;
      }
      var sent = 0;
      await request.addStream(data.map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent);
        return chunk;
      }));
      response = await request.close().timeout(const Duration(minutes: 5));
    } catch (e) {
      throw e is RemoteException ? e : (_trust?.failure() ?? remoteError(e));
    }
    await response.drain<void>().catchError((_) {});
    if (response.statusCode == 401 && _takeChallenge(response)) {
      // A stale sign-in: the copy is tried again with the new one.
      throw const RemoteException(RemoteErrorKind.network, 'The server asked to sign in again.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) throw _failure(response.statusCode, normal);
  }

  @override
  Future<void> createDirectory(String path) async {
    final normal = RemotePaths.normalize(path);
    final answer = await _send('MKCOL', _uri(normal, folder: true));
    if (answer.status < 200 || answer.status >= 300) throw _failure(answer.status, normal);
  }

  @override
  Future<void> delete(String path) async {
    final normal = RemotePaths.normalize(path);
    final entry = await stat(normal);
    final answer = await _send('DELETE', _uri(normal, folder: entry.isDirectory));
    if (answer.status < 200 || answer.status >= 300) throw _failure(answer.status, normal);
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = RemotePaths.normalize(from);
    final target = RemotePaths.normalize(to);
    final entry = await stat(source);
    final answer = await _send(
      'MOVE',
      _uri(source, folder: entry.isDirectory),
      headers: {
        'Destination': _uri(target, folder: entry.isDirectory).toString(),
        // Only the case changed: the server may see the same name.
        'Overwrite': source.toLowerCase() == target.toLowerCase() ? 'T' : 'F',
      },
    );
    if (answer.status < 200 || answer.status >= 300) throw _failure(answer.status, target);
  }

  @override
  Future<void> close() async {
    _client?.close(force: true);
    _client = null;
  }
}
