import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:folders/core/services/remote/cloud/cloud_oauth.dart';

/// A request the fake server got.
class Seen {
  Seen(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List body;

  String get path => uri.path;

  @override
  String toString() => '$method $uri';
}

/// A canned failure for the next request(s) that match.
class Fault {
  Fault(this.matches, {this.status = 500, this.headers = const {}, this.body = '', this.times = 1, this.drop = false});

  final bool Function(Seen request) matches;
  final int status;
  final Map<String, String> headers;
  final String body;
  int times;

  /// Closes the connection without answering.
  final bool drop;
}

typedef FakeHandler = Future<void> Function(Seen request, HttpResponse response);

/// A local HTTP server standing in for a cloud service: logs every request,
/// checks the bearer token, can fail on purpose, and serves a token endpoint
/// at `/token` that hands out `token1`, `token2`... and refresh tokens.
class FakeCloud {
  FakeCloud(this.handler);

  final FakeHandler handler;
  late HttpServer _server;
  final List<Seen> seen = [];
  final List<Fault> faults = [];

  /// The token the API accepts; null accepts any.
  String? validToken = 'token0';

  /// Whether `/token` hands out a new refresh token each time (Microsoft).
  bool rotateRefresh = false;
  String refreshToken = 'refresh0';
  int _issued = 0;

  /// Codes `/token` accepts for the code flow: code → PKCE challenge.
  final Map<String, (String challenge, String redirect)> codes = {};

  String get base => 'http://127.0.0.1:${_server.port}';
  int get port => _server.port;

  Future<FakeCloud> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
    return this;
  }

  Future<void> close() => _server.close(force: true);

  List<Seen> requests(String method, [String? pathPart]) =>
      [for (final s in seen) if (s.method == method && (pathPart == null || s.path.contains(pathPart))) s];

  Future<void> _serve(HttpRequest request) async {
    final body = BytesBuilder(copy: false);
    await for (final chunk in request) {
      body.add(chunk);
    }
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(','));
    final s = Seen(request.method, request.uri, headers, body.takeBytes());
    seen.add(s);
    final response = request.response;
    for (final fault in faults) {
      if (fault.times > 0 && fault.matches(s)) {
        fault.times--;
        if (fault.drop) {
          final socket = await response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        response.statusCode = fault.status;
        fault.headers.forEach(response.headers.set);
        response.write(fault.body);
        await response.close();
        return;
      }
    }
    if (s.path == '/token') return _token(s, response);
    try {
      await handler(s, response);
    } on Object catch (e, st) {
      response.statusCode = 599;
      response.write('fake failed: $e\n$st');
      await response.close();
    }
  }

  /// True when the request had the valid token; else answers 401.
  Future<bool> authorized(Seen s, HttpResponse response, {Object? body}) async {
    if (validToken == null || s.headers['authorization'] == 'Bearer $validToken') return true;
    await json(response, body ?? {'error': 'invalid_token'}, status: 401);
    return false;
  }

  Future<void> _token(Seen s, HttpResponse response) async {
    final form = Uri.splitQueryString(utf8.decode(s.body));
    switch (form['grant_type']) {
      case 'refresh_token':
        if (form['refresh_token'] != refreshToken) {
          return json(response, {'error': 'invalid_grant'}, status: 400);
        }
      case 'authorization_code':
        final expected = codes.remove(form['code']);
        final verifier = form['code_verifier'] ?? '';
        final challenge = base64Url.encode(sha256Of(verifier)).replaceAll('=', '');
        if (expected == null || expected.$1 != challenge || expected.$2 != form['redirect_uri']) {
          return json(response, {'error': 'invalid_grant'}, status: 400);
        }
      default:
        return json(response, {'error': 'unsupported_grant_type'}, status: 400);
    }
    validToken = 'token${++_issued}';
    final newRefresh = form['grant_type'] == 'authorization_code' || rotateRefresh;
    if (newRefresh) refreshToken = 'refresh$_issued';
    await json(response, {
      'access_token': validToken,
      'token_type': 'bearer',
      'expires_in': 3600,
      if (newRefresh) 'refresh_token': refreshToken,
    });
  }

  CloudOAuthConfig oauth({
    String service = 'Fake',
    String clientSecret = '',
    String redirectHost = '127.0.0.1',
    int redirectPort = 0,
    bool exactPort = false,
    bool scopeOnRefresh = false,
    List<String> scopes = const ['files'],
  }) =>
      CloudOAuthConfig(
        service: service,
        authorizeUrl: Uri.parse('$base/authorize'),
        tokenUrl: Uri.parse('$base/token'),
        clientId: 'client',
        clientSecret: clientSecret,
        scopes: scopes,
        redirectHost: redirectHost,
        redirectPort: redirectPort,
        exactPort: exactPort,
        scopeOnRefresh: scopeOnRefresh,
      );
}

Future<void> json(HttpResponse response, Object? value, {int status = 200, Map<String, String> headers = const {}}) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  headers.forEach(response.headers.set);
  response.write(jsonEncode(value));
  await response.close();
}

Future<void> bytes(HttpResponse response, List<int> data, {int status = 200}) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.binary;
  response.contentLength = data.length;
  response.add(data);
  await response.close();
}

/// [data] or the part a Range header asks for, as a server would send it.
Future<void> ranged(Seen s, HttpResponse response, List<int> data) async {
  final range = s.headers['range'];
  if (range == null) return bytes(response, data);
  final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
  final start = int.parse(m[1]!);
  if (start >= data.length) {
    response.statusCode = 416;
    return response.close();
  }
  final end = m[2]!.isEmpty ? data.length - 1 : int.parse(m[2]!).clamp(0, data.length - 1);
  response.headers.set('content-range', 'bytes $start-$end/${data.length}');
  return bytes(response, data.sublist(start, end + 1), status: 206);
}

List<int> sha256Of(String text) => sha256.convert(ascii.encode(text)).bytes;

/// Plays the browser: opens the sign-in page and follows its redirect back
/// to the app, as a person signing in would.
Future<bool> fakeBrowser(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    await response.drain<void>();
    return true;
  } finally {
    client.close(force: true);
  }
}

/// A stream of [data] in pieces of [piece] bytes, like a file being read.
Stream<List<int>> pieces(List<int> data, [int piece = 7000]) async* {
  for (var i = 0; i < data.length; i += piece) {
    yield data.sublist(i, i + piece > data.length ? data.length : i + piece);
  }
}

Uint8List sample(int length, [int seed = 1]) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed * 7 + (i >> 8)) & 0xff));
