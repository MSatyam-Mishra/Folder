import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:folders/core/services/remote/remote_fs.dart';

/// Waits between retries; tests pass one that doesn't.
typedef CloudSleep = Future<void> Function(Duration delay);

/// Turns a refused request into plain words, for one service.
typedef CloudErrorReader = RemoteException Function(int status, String body);

/// Supplies the bearer token of a signed-in account and renews it.
abstract class CloudAuth {
  /// A token that hasn't expired, renewed first if it's about to.
  Future<String> accessToken();

  /// The service refused [used]: renews it, unless another call already did.
  /// Throws [RemoteException] with [RemoteErrorKind.auth] if it can't.
  Future<void> renew(String used);
}

/// A token that never changes, for the calls made right after signing in.
class FixedCloudAuth implements CloudAuth {
  const FixedCloudAuth(this.token);

  final String token;

  @override
  Future<String> accessToken() async => token;

  @override
  Future<void> renew(String used) async =>
      throw const RemoteException(RemoteErrorKind.auth, 'The sign-in was refused. Try signing in again.');
}

class CloudResponse {
  CloudResponse(this.statusCode, this.headers, this.body);

  final int statusCode;
  final HttpHeaders headers;
  final Uint8List body;

  String get text => utf8.decode(body, allowMalformed: true);

  /// The body as a JSON object; empty if it isn't one.
  Map<String, Object?> get json => jsonObject(text);
}

/// [text] as a JSON object; empty if it isn't one.
Map<String, Object?> jsonObject(String text) {
  try {
    final value = jsonDecode(text);
    if (value is Map<String, Object?>) return value;
  } on FormatException {
    // Not JSON (an HTML error page...).
  }
  return const {};
}

/// HTTP for the cloud services: adds the bearer token, renews it once when
/// it's refused, waits and tries again when the service is busy (429, 503,
/// honouring Retry-After), and turns failures into [RemoteException]s.
class CloudHttp {
  CloudHttp({
    required this.service,
    required this.errorOf,
    this.auth,
    this.retryIf,
    CloudSleep? sleep,
    this.maxRetries = 5,
    HttpClient? client,
  })  : sleep = sleep ?? _wait,
        _client = client ?? _newClient();

  /// "Google Drive", for messages.
  final String service;
  final CloudErrorReader errorOf;
  final CloudAuth? auth;

  /// More statuses worth trying again (Google's 403 rate limits...).
  final bool Function(int status, String body)? retryIf;
  final CloudSleep sleep;
  final int maxRetries;
  final HttpClient _client;

  /// Longer than this and the user is told to come back later instead.
  static const maxRetryAfter = Duration(minutes: 2);

  static Future<void> _wait(Duration delay) => Future<void>.delayed(delay);

  static HttpClient _newClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..idleTimeout = const Duration(seconds: 30)
    ..userAgent = 'Folders';

  final _random = Random();

  RemoteException get networkError =>
      RemoteException(RemoteErrorKind.network, "Couldn't reach $service. Check the internet connection and try again.");

  RemoteException get authError =>
      RemoteException(RemoteErrorKind.auth, 'Your sign-in to $service has expired. Sign in again.');

  /// Sends a request and reads the whole answer. Statuses of 400 and above
  /// throw, unless listed in [accept].
  ///
  /// [idempotent] requests are also tried again after a dropped connection or
  /// a 500/502/504; others only when the service said it didn't take them
  /// (429, 503), so nothing is done twice.
  Future<CloudResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    bool authorized = true,
    bool idempotent = true,
    Set<int> accept = const {},
  }) async {
    final response = await open(method, url,
        headers: headers, body: body, authorized: authorized, idempotent: idempotent, accept: accept);
    return CloudResponse(response.statusCode, response.headers, await readAll(response));
  }

  /// Like [send], but hands back the response before its body is read, for
  /// downloads. Read it through [guard] so a dropped connection becomes a
  /// [RemoteException].
  Future<HttpClientResponse> open(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    List<int>? body,
    bool authorized = true,
    bool idempotent = true,
    Set<int> accept = const {},
  }) async {
    var renewed = false;
    for (var attempt = 0;; attempt++) {
      final token = authorized && auth != null ? await auth!.accessToken() : null;
      final HttpClientResponse response;
      try {
        final request = await _client.openUrl(method, url);
        request.followRedirects = method == 'GET';
        headers.forEach(request.headers.set);
        if (token != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        } else if (method != 'GET' && method != 'HEAD') {
          request.contentLength = 0;
        }
        // Generous for big chunks on slow links: a minute plus 25 kB/s.
        final limit = Duration(seconds: 60 + (body?.length ?? 0) ~/ 25000);
        response = await request.close().timeout(limit);
      } on Object catch (e) {
        if (e is! IOException && e is! TimeoutException) rethrow;
        if (idempotent && attempt < maxRetries) {
          await sleep(_backoff(attempt));
          continue;
        }
        throw networkError;
      }

      final status = response.statusCode;
      if (status < 400 || accept.contains(status)) return response;

      final text = utf8.decode(await readAll(response), allowMalformed: true);
      if (status == 401 && token != null) {
        if (renewed) throw authError;
        renewed = true;
        await auth!.renew(token);
        continue;
      }
      final busy = status == 429 || status == 503 || (retryIf?.call(status, text) ?? false);
      final failed = status == 500 || status == 502 || status == 504;
      if ((busy || (failed && idempotent)) && attempt < maxRetries) {
        final asked = retryAfter(response.headers);
        if (asked != null && asked > maxRetryAfter) {
          final minutes = (asked.inSeconds / 60).ceil();
          throw RemoteException(RemoteErrorKind.other,
              '$service is busy and asks to wait. Try again in $minutes minute${minutes == 1 ? '' : 's'}.');
        }
        await sleep(asked ?? _backoff(attempt));
        continue;
      }
      if (status == 401) throw authError;
      throw errorOf(status, text);
    }
  }

  /// [stream] with dropped connections turned into [RemoteException]s.
  Stream<List<int>> guard(Stream<List<int>> stream) => stream.handleError(
        (Object e) => throw networkError,
        test: (e) => e is IOException || e is TimeoutException,
      );

  Future<Uint8List> readAll(Stream<List<int>> stream) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in guard(stream)) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// 1, 2, 4... seconds, up to 32, with a little jitter.
  Duration _backoff(int attempt) =>
      Duration(milliseconds: 1000 * (1 << min(attempt, 5)) + _random.nextInt(500));

  /// Retry-After as seconds or an HTTP date; null when absent or unreadable.
  static Duration? retryAfter(HttpHeaders headers) {
    final value = headers.value('retry-after')?.trim();
    if (value == null || value.isEmpty) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: max(seconds, 0));
    try {
      final at = HttpDate.parse(value);
      final wait = at.difference(DateTime.now().toUtc());
      return wait.isNegative ? Duration.zero : wait;
    } on Object {
      return null;
    }
  }

  void close() => _client.close(force: true);
}

/// Reads a stream in pieces of a set size, for chunked uploads.
class ChunkReader {
  ChunkReader(Stream<List<int>> stream) : _source = StreamIterator(stream);

  final StreamIterator<List<int>> _source;
  List<int> _rest = const [];
  int _at = 0;

  /// Bytes handed out so far.
  int position = 0;

  /// Up to [size] bytes; fewer only at the end, and none after it.
  Future<Uint8List> next(int size) async {
    final out = BytesBuilder(copy: false);
    while (out.length < size && !await atEnd()) {
      final take = min(size - out.length, _rest.length - _at);
      final rest = _rest;
      out.add(rest is Uint8List
          ? Uint8List.sublistView(rest, _at, _at + take)
          : Uint8List.fromList(rest.sublist(_at, _at + take)));
      _at += take;
    }
    position += out.length;
    return out.takeBytes();
  }

  /// Whether everything has been read.
  Future<bool> atEnd() async {
    while (_at >= _rest.length) {
      if (!await _source.moveNext()) return true;
      _rest = _source.current;
      _at = 0;
    }
    return false;
  }

  Future<void> cancel() => _source.cancel();
}

/// A stream of [source]'s bytes from [start] up to [end], for services that
/// can't send part of a file (exported Google Docs).
Stream<List<int>> sliceBytes(Stream<List<int>> source, int start, int? end) async* {
  var at = 0;
  await for (final chunk in source) {
    final from = max(start - at, 0);
    final to = end == null ? chunk.length : min(end - at, chunk.length);
    at += chunk.length;
    if (from < to) yield from == 0 && to == chunk.length ? chunk : chunk.sublist(from, to);
    if (end != null && at >= end) return;
  }
}
