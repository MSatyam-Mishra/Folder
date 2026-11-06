// HTTP(S) client side of LocalSend protocol v2: register, info,
// prepare-upload, upload, cancel.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/localsend/localsend_identity.dart';
import 'package:folders/core/services/localsend/localsend_models.dart';

/// Cancels in-flight requests.
class LsCancelToken {
  bool _cancelled = false;
  final _callbacks = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final cb in List.of(_callbacks)) {
      try {
        cb();
      } catch (_) {}
    }
    _callbacks.clear();
  }

  /// Returns a function that unregisters [callback].
  void Function() onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _callbacks.add(callback);
    return () => _callbacks.remove(callback);
  }
}

class LsRegisterResult {
  const LsRegisterResult(this.info, this.certificateFingerprint);

  /// Peer info; in HTTPS mode its fingerprint is the certificate's.
  final LsDeviceInfo info;
  final String? certificateFingerprint;
}

class LsPrepareResult {
  const LsPrepareResult(this.sessionId, this.tokens);

  final String sessionId;

  /// fileId -> token, only for the files the receiver accepted.
  final Map<String, String> tokens;
}

class LsClient {
  /// [expectedFingerprint] pins the HTTPS peer certificate (upper/lower case
  /// hex SHA-256). Without it any certificate is accepted (discovery), and
  /// the fingerprint is read off the response.
  LsClient(
    this.identity, {
    this.expectedFingerprint,
    Duration connectTimeout = const Duration(seconds: 5),
  }) : _http = HttpClient(context: identity.clientContext()) {
    _http
      ..connectionTimeout = connectTimeout
      ..idleTimeout = const Duration(seconds: 10)
      ..maxConnectionsPerHost = 8
      ..userAgent = 'Folders-LocalSend/1.0'
      ..findProxy = ((_) => 'DIRECT')
      ..badCertificateCallback = _acceptCertificate;
  }

  final LsIdentity identity;
  final String? expectedFingerprint;
  final HttpClient _http;
  bool _fingerprintMismatch = false;

  bool _acceptCertificate(X509Certificate cert, String host, int port) {
    // LocalSend peers use self-signed certificates: identity is the
    // certificate fingerprint, not a CA chain.
    final expected = expectedFingerprint;
    if (expected == null || expected.isEmpty) return true;
    final ok = lsFingerprintOfDer(cert.der) == expected.toUpperCase();
    if (!ok) _fingerprintMismatch = true;
    return ok;
  }

  void close({bool force = true}) => _http.close(force: force);

  static X509Certificate? _certificateOf(HttpClientResponse response) {
    try {
      return response.certificate;
    } catch (_) {
      return null;
    }
  }

  LsException _mapError(Object e) {
    if (e is LsException) return e;
    if (e is TimeoutException) return const LsException(LsErrorKind.timeout);
    if (e is HandshakeException || e is TlsException) {
      if (_fingerprintMismatch) {
        return const LsException(LsErrorKind.fingerprintMismatch);
      }
      return LsException(LsErrorKind.tls, e.toString());
    }
    if (e is SocketException) {
      return LsException(
        LsErrorKind.unreachable,
        e.osError?.message ?? e.message,
      );
    }
    if (e is HttpException) {
      return LsException(LsErrorKind.unreachable, e.message);
    }
    if (e is FileSystemException) {
      return LsException(LsErrorKind.io, e.message);
    }
    return LsException(LsErrorKind.unknown, e.toString());
  }

  Future<(int, String, X509Certificate?)> _postJson(
    Uri uri,
    Object? body, {
    Duration? timeout,
    LsCancelToken? cancel,
  }) async {
    HttpClientRequest? request;
    void Function()? unregister;
    Future<(int, String, X509Certificate?)> run() async {
      request = await _http.postUrl(uri);
      final req = request!;
      unregister = cancel?.onCancel(
        () => req.abort(const LsException(LsErrorKind.cancelled)),
      );
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      } else {
        req.contentLength = 0;
      }
      final response = await req.close();
      // Read the certificate before the body: once the peer closes the
      // connection (it may answer with `connection: close`) it is gone.
      final cert = _certificateOf(response);
      final text = await utf8.decodeStream(response);
      return (response.statusCode, text, cert);
    }

    try {
      if (cancel?.isCancelled ?? false) {
        throw const LsException(LsErrorKind.cancelled);
      }
      final future = run();
      return timeout == null ? await future : await future.timeout(timeout);
    } catch (e) {
      if (e is TimeoutException) request?.abort();
      if (cancel?.isCancelled ?? false) {
        throw const LsException(LsErrorKind.cancelled);
      }
      throw _mapError(e);
    } finally {
      unregister?.call();
    }
  }

  /// `POST /register`: announces [self] to the peer and returns its info.
  Future<LsRegisterResult> register({
    required String host,
    required int port,
    required LsProtocol protocol,
    required LsDeviceInfo self,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final uri = Uri(
      scheme: protocol.name,
      host: host,
      port: port,
      path: '${LsConst.apiPrefix}/register',
    );
    final (status, body, cert) = await _postJson(
      uri,
      self.toRegisterJson(),
      timeout: timeout,
    );
    if (status != 200) throw LsException.fromStatus(status, body);
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const LsException(LsErrorKind.protocol, 'register: invalid JSON');
    }
    var info = LsDeviceInfo.tryParse(json, port: port, protocol: protocol);
    if (info == null) {
      throw const LsException(LsErrorKind.protocol, 'register: missing fields');
    }
    // The response does not carry port/protocol: they are the ones we used.
    info = info.copyWith(port: port, protocol: protocol);
    String? certFingerprint;
    if (cert != null) {
      certFingerprint = lsFingerprintOfDer(cert.der);
      info = info.copyWith(fingerprint: certFingerprint);
    }
    return LsRegisterResult(info, certFingerprint);
  }

  /// `GET /info` (debugging / legacy).
  Future<LsDeviceInfo> info({
    required String host,
    required int port,
    required LsProtocol protocol,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final uri = Uri(
      scheme: protocol.name,
      host: host,
      port: port,
      path: '${LsConst.apiPrefix}/info',
    );
    try {
      final request = await _http.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final cert = _certificateOf(response);
      final body = await utf8.decodeStream(response).timeout(timeout);
      if (response.statusCode != 200) {
        throw LsException.fromStatus(response.statusCode, body);
      }
      var info = LsDeviceInfo.tryParse(
        jsonDecode(body),
        port: port,
        protocol: protocol,
      );
      if (info == null) throw const LsException(LsErrorKind.protocol, 'info');
      info = info.copyWith(port: port, protocol: protocol);
      if (cert != null) {
        info = info.copyWith(fingerprint: lsFingerprintOfDer(cert.der));
      }
      return info;
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// `POST /prepare-upload`. Waits for the receiver's decision (no timeout:
  /// a person decides). Returns null on 204 (nothing to transfer).
  Future<LsPrepareResult?> prepareUpload({
    required LsDevice device,
    required LsDeviceInfo self,
    required List<LsFileDto> files,
    String? pin,
    LsCancelToken? cancel,
  }) async {
    final uri = device.uri(
      'prepare-upload',
      pin == null || pin.isEmpty ? null : {'pin': pin},
    );
    final payload = {
      'info': self.toRegisterJson(),
      'files': {for (final f in files) f.id: f.toJson()},
    };
    final (status, body, _) = await _postJson(uri, payload, cancel: cancel);
    if (status == 204) return null;
    if (status != 200) {
      throw LsException.fromStatus(
        status,
        body,
        pinSent: pin != null && pin.isNotEmpty,
      );
    }
    try {
      final json = jsonDecode(body) as Map;
      final sessionId = json['sessionId'] as String;
      final tokens = <String, String>{};
      (json['files'] as Map).forEach((k, v) {
        if (k is String && v is String) tokens[k] = v;
      });
      return LsPrepareResult(sessionId, tokens);
    } catch (_) {
      throw const LsException(
        LsErrorKind.protocol,
        'prepare-upload: invalid response',
      );
    }
  }

  /// `POST /upload`: streams [file] to the receiver.
  Future<void> upload({
    required LsDevice device,
    required String sessionId,
    required String fileId,
    required String token,
    required File file,
    required int size,
    void Function(int sentBytes)? onProgress,
    LsCancelToken? cancel,
  }) async {
    final uri = device.uri('upload', {
      'sessionId': sessionId,
      'fileId': fileId,
      'token': token,
    });
    void Function()? unregister;
    StreamSubscription<List<int>>? fileSub;
    // Completes with an error on cancel. Needed because a write blocked on a
    // receiver that stopped reading does not end when the request is aborted.
    final aborted = Completer<Never>();
    aborted.future.ignore();
    Future<T> abortable<T>(Future<T> future) =>
        Future.any<T>([future, aborted.future]);
    try {
      if (cancel?.isCancelled ?? false) {
        throw const LsException(LsErrorKind.cancelled);
      }
      final req = await _http.postUrl(uri);
      unregister = cancel?.onCancel(() {
        req.abort(const LsException(LsErrorKind.cancelled));
        unawaited(fileSub?.cancel());
        if (!aborted.isCompleted) {
          aborted.completeError(const LsException(LsErrorKind.cancelled));
        }
      });
      req.headers.contentType = ContentType.binary;
      req.contentLength = size;
      var sent = 0;
      var lastReport = 0;
      late final StreamController<List<int>> body;
      body = StreamController<List<int>>(
        onListen: () {
          fileSub = file.openRead().listen(
            (chunk) {
              sent += chunk.length;
              if (onProgress != null &&
                  (sent - lastReport >= 256 * 1024 || sent == size)) {
                lastReport = sent;
                onProgress(sent);
              }
              body.add(chunk);
            },
            onError: body.addError,
            onDone: body.close,
          );
        },
        onPause: () => fileSub?.pause(),
        onResume: () => fileSub?.resume(),
        onCancel: () => fileSub?.cancel(),
      );
      Object? streamError;
      try {
        await abortable(req.addStream(body.stream));
      } catch (e) {
        if (aborted.isCompleted) rethrow;
        // The receiver may have answered (and closed) early, e.g. 403 after a
        // cancel: still try to read its response below.
        streamError = e;
      }
      final HttpClientResponse response;
      try {
        response = await abortable(req.close());
      } catch (e) {
        if (aborted.isCompleted) rethrow;
        throw streamError ?? e;
      }
      final text = await abortable(utf8.decodeStream(response));
      if (response.statusCode != 200) {
        throw LsException.fromStatus(response.statusCode, text, upload: true);
      }
      if (streamError != null) throw streamError;
      onProgress?.call(size);
    } catch (e) {
      if (cancel?.isCancelled ?? false) {
        throw const LsException(LsErrorKind.cancelled);
      }
      throw _mapError(e);
    } finally {
      unregister?.call();
      unawaited(fileSub?.cancel());
    }
  }

  /// `POST /cancel`. Without [sessionId] it cancels a pending prepare-upload
  /// request from this device. Best effort.
  Future<void> cancel({required LsDevice device, String? sessionId}) async {
    try {
      await _postJson(
        device.uri(
          'cancel',
          sessionId == null ? null : {'sessionId': sessionId},
        ),
        null,
        timeout: const Duration(seconds: 3),
      );
    } catch (e) {
      LsLog.d('cancel request to ${device.ip} failed: $e');
    }
  }
}
