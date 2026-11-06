// HTTP(S) server side of LocalSend protocol v2 (receiving files):
// register, info, prepare-upload, upload, cancel.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folders/core/services/localsend/localsend_hash.dart';
import 'package:folders/core/services/localsend/localsend_identity.dart';
import 'package:folders/core/services/localsend/localsend_models.dart';
import 'package:folders/core/services/localsend/localsend_names.dart';
import 'package:path/path.dart' as p;

enum LsReceiveFileStatus { queued, receiving, done, failed, skipped }

class LsReceiveFile {
  LsReceiveFile(this.dto, this.token);

  final LsFileDto dto;
  final String token;
  LsReceiveFileStatus status = LsReceiveFileStatus.queued;
  int received = 0;
  int attempts = 0;
  String? savedPath;
  String? error;

  bool get isFinal =>
      status == LsReceiveFileStatus.done ||
      status == LsReceiveFileStatus.failed ||
      status == LsReceiveFileStatus.skipped;
}

enum LsReceiveState {
  receiving,
  finished,
  cancelledBySender,
  cancelledByReceiver,
  stalled,
}

/// An accepted incoming transfer.
class LsReceiveSession {
  LsReceiveSession({
    required this.id,
    required this.senderIp,
    required this.sender,
    required this.destination,
    required this.files,
  }) : startedAt = DateTime.now();

  final String id;
  final String senderIp;
  final LsDeviceInfo sender;
  final String destination;

  /// Accepted files by id.
  final Map<String, LsReceiveFile> files;
  final DateTime startedAt;
  DateTime? endedAt;
  LsReceiveState state = LsReceiveState.receiving;

  final Set<String> _reserved = {};
  final _cancelCallbacks = <void Function()>[];
  DateTime _lastActivity = DateTime.now();
  int _inFlight = 0;

  bool get isActive => state == LsReceiveState.receiving;
  int get totalBytes => files.values.fold(0, (s, f) => s + f.dto.size);
  int get receivedBytes => files.values.fold(
    0,
    (s, f) =>
        s + (f.status == LsReceiveFileStatus.done ? f.dto.size : f.received),
  );
  int get doneCount =>
      files.values.where((f) => f.status == LsReceiveFileStatus.done).length;
  int get failedCount =>
      files.values.where((f) => f.status == LsReceiveFileStatus.failed).length;
  List<String> get savedPaths => [
    for (final f in files.values)
      if (f.savedPath != null) f.savedPath!,
  ];

  void _cancel(LsReceiveState newState, {bool abortUploads = true}) {
    if (!isActive) return;
    state = newState;
    endedAt = DateTime.now();
    for (final f in files.values) {
      if (!f.isFinal) {
        f.status = LsReceiveFileStatus.failed;
        f.error ??= 'Cancelled';
      }
    }
    if (abortUploads) _abortUploads();
  }

  /// Closes the connections of uploads still in progress.
  void _abortUploads() {
    for (final cb in List.of(_cancelCallbacks)) {
      try {
        cb();
      } catch (_) {}
    }
    _cancelCallbacks.clear();
  }
}

/// A transfer offer waiting for the user's decision.
class LsIncomingRequest {
  LsIncomingRequest({
    required this.sessionId,
    required this.senderIp,
    required this.sender,
    required this.files,
  });

  final String sessionId;
  final String senderIp;
  final LsDeviceInfo sender;
  final List<LsFileDto> files;
  final Completer<void> _cancelled = Completer<void>();

  int get totalSize => files.fold(0, (s, f) => s + f.size);

  /// Completes when the sender withdraws the request before a decision.
  Future<void> get cancelled => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;
}

class LsReceiveDecision {
  const LsReceiveDecision.accept([this.fileIds]) : accepted = true;
  const LsReceiveDecision.decline() : accepted = false, fileIds = null;

  final bool accepted;

  /// Subset to accept; null means all offered files.
  final Set<String>? fileIds;
}

class LsServer {
  LsServer({required this.identity, required this.selfInfo});

  final LsIdentity identity;

  /// Our current device info (alias may change while running).
  final LsDeviceInfo Function() selfInfo;

  /// A device registered with us (`POST /register`).
  void Function(String ip, LsDeviceInfo info)? onRegister;

  /// Decides on incoming transfers. Without it every request is declined.
  Future<LsReceiveDecision> Function(LsIncomingRequest request)? onIncoming;

  /// Session progress and state changes (progress is throttled).
  void Function(LsReceiveSession session)? onSessionChanged;

  /// `POST /cancel` for a session we do not manage: the peer cancels a
  /// transfer we are sending to it.
  void Function(String ip, String? sessionId)? onForeignCancel;

  HttpServer? _server;
  bool _https = true;
  String? _pin;
  String _destination = '';
  final Map<String, int> _pinFailures = {};
  LsIncomingRequest? _pending;
  LsReceiveSession? _session;
  Timer? _watchdog;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  static const _maxPinAttempts = 3;
  static const _maxUploadAttempts = 3;
  static const _maxJsonBody = 64 * 1024 * 1024;
  static const _stallTimeout = Duration(seconds: 90);

  /// An upload that receives no data for this long fails.
  static Duration uploadIdleTimeout = const Duration(seconds: 60);
  static const tempFolderName = '.localsend_incoming';

  bool get isRunning => _server != null;
  int? get port => _server?.port;
  bool get https => _https;
  LsReceiveSession? get session => _session;
  LsIncomingRequest? get pendingRequest => _pending;

  /// Changes PIN / destination without restarting.
  void update({String? pin, String? destination}) {
    _pin = (pin == null || pin.isEmpty) ? null : pin;
    if (destination != null) _destination = destination;
  }

  Future<void> start({
    required int port,
    required bool https,
    String? pin,
    required String destination,
  }) async {
    await stop();
    _https = https;
    update(pin: pin, destination: destination);
    final server = https
        ? await HttpServer.bindSecure(
            InternetAddress.anyIPv4,
            port,
            identity.serverContext(),
          )
        : await HttpServer.bind(InternetAddress.anyIPv4, port);
    server
      ..idleTimeout = const Duration(seconds: 30)
      ..autoCompress = false
      ..serverHeader = null;
    server.defaultResponseHeaders.clear();
    _server = server;
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object e) => LsLog.d('server error: $e'),
    );
    _watchdog = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkStall(),
    );
    LsLog.d('server listening on ${server.port} (${https ? 'https' : 'http'})');
  }

  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    final pending = _pending;
    if (pending != null && !pending._cancelled.isCompleted) {
      pending._cancelled.complete();
    }
    _pending = null;
    final session = _session;
    if (session != null && session.isActive) {
      session._cancel(LsReceiveState.cancelledByReceiver);
      _notify(session, force: true);
    }
    _session = null;
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// The receiving user cancels the current transfer: new uploads are
  /// refused at once. Returns the session so the caller can tell the sender
  /// (`POST /cancel` to the sender's server). With [abortUploads] false,
  /// uploads in progress keep their connection until [abortUploads] is
  /// called, so the sender learns about the cancel before its uploads break.
  LsReceiveSession? cancelSession({bool abortUploads = true}) {
    final session = _session;
    if (session == null || !session.isActive) return null;
    session._cancel(
      LsReceiveState.cancelledByReceiver,
      abortUploads: abortUploads,
    );
    _session = null;
    _notify(session, force: true);
    if (abortUploads) unawaited(_cleanupTemp(session));
    return session;
  }

  void abortUploads(LsReceiveSession session) {
    session._abortUploads();
    unawaited(_cleanupTemp(session));
  }

  void _checkStall() {
    final session = _session;
    if (session == null || !session.isActive || session._inFlight > 0) return;
    if (DateTime.now().difference(session._lastActivity) > _stallTimeout) {
      LsLog.d('receive session ${session.id} stalled');
      session._cancel(LsReceiveState.stalled);
      _session = null;
      _notify(session, force: true);
      unawaited(_cleanupTemp(session));
    }
  }

  void _notify(LsReceiveSession session, {bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastNotify) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastNotify = now;
    try {
      onSessionChanged?.call(session);
    } catch (e) {
      LsLog.d('onSessionChanged failed: $e');
    }
  }

  // ---------------------------------------------------------------- routing

  Future<void> _handle(HttpRequest request) async {
    final ip = request.connectionInfo?.remoteAddress.address ?? '';
    final path = request.uri.path;
    try {
      if (!path.startsWith('${LsConst.apiPrefix}/')) {
        return await _error(request, HttpStatus.notFound, 'Not found');
      }
      final route = path.substring(LsConst.apiPrefix.length + 1);
      switch (route) {
        case 'register':
          return await _requirePost(request, () => _register(request, ip));
        case 'info':
          return await _sendJson(
            request,
            HttpStatus.ok,
            selfInfo().toInfoJson(),
          );
        case 'prepare-upload':
          return await _requirePost(request, () => _prepareUpload(request, ip));
        case 'upload':
          return await _requirePost(request, () => _upload(request, ip));
        case 'cancel':
          return await _requirePost(request, () => _cancelRoute(request, ip));
        default:
          return await _error(request, HttpStatus.notFound, 'Not found');
      }
    } catch (e, st) {
      LsLog.d('request $path from $ip failed: $e\n$st');
      try {
        await _error(request, HttpStatus.internalServerError, 'Internal error');
      } catch (_) {}
    }
  }

  Future<void> _requirePost(HttpRequest r, Future<void> Function() handler) {
    if (r.method != 'POST') {
      return _error(r, HttpStatus.methodNotAllowed, 'Method not allowed');
    }
    return handler();
  }

  Future<void> _sendJson(HttpRequest r, int status, Object body) async {
    final bytes = utf8.encode(jsonEncode(body));
    r.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..contentLength = bytes.length
      ..add(bytes);
    await r.response.close();
  }

  Future<void> _error(HttpRequest r, int status, String message) =>
      _sendJson(r, status, {'message': message});

  Future<void> _empty(HttpRequest r, int status) async {
    r.response
      ..statusCode = status
      ..contentLength = 0;
    await r.response.close();
  }

  Future<Object?> _readJson(HttpRequest r) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in r) {
      builder.add(chunk);
      if (builder.length > _maxJsonBody) {
        throw const FormatException('body too large');
      }
    }
    return jsonDecode(utf8.decode(builder.takeBytes()));
  }

  // ---------------------------------------------------------------- routes

  Future<void> _register(HttpRequest r, String ip) async {
    Object? json;
    try {
      json = await _readJson(r);
    } on FormatException {
      return _error(r, HttpStatus.badRequest, 'Invalid body');
    }
    final info = LsDeviceInfo.tryParse(json);
    if (info == null) return _error(r, HttpStatus.badRequest, 'Invalid body');
    try {
      onRegister?.call(ip, info);
    } catch (e) {
      LsLog.d('onRegister failed: $e');
    }
    return _sendJson(r, HttpStatus.ok, selfInfo().toInfoJson());
  }

  Future<void> _prepareUpload(HttpRequest r, String ip) async {
    // PIN first (like the official implementation), before the body.
    final pin = _pin;
    if (pin != null) {
      final failures = _pinFailures[ip] ?? 0;
      if (failures >= _maxPinAttempts) {
        await r.drain<void>();
        return _error(r, HttpStatus.tooManyRequests, 'Too many requests');
      }
      final given = r.uri.queryParameters['pin'];
      if (given == null) {
        await r.drain<void>();
        return _error(r, HttpStatus.unauthorized, 'PIN required');
      }
      if (given != pin) {
        _pinFailures[ip] = failures + 1;
        await r.drain<void>();
        return _error(r, HttpStatus.unauthorized, 'Invalid PIN');
      }
      _pinFailures.remove(ip);
    }

    Object? json;
    try {
      json = await _readJson(r);
    } on FormatException {
      return _error(r, HttpStatus.badRequest, 'Invalid body');
    }
    if (json is! Map) return _error(r, HttpStatus.badRequest, 'Invalid body');
    final info = LsDeviceInfo.tryParse(json['info']);
    final rawFiles = json['files'];
    if (info == null || rawFiles is! Map || rawFiles.isEmpty) {
      return _error(r, HttpStatus.badRequest, 'Invalid body');
    }
    final files = <LsFileDto>[];
    for (final entry in rawFiles.entries) {
      final dto = LsFileDto.tryParse(entry.value);
      if (dto == null) return _error(r, HttpStatus.badRequest, 'Invalid body');
      files.add(dto);
    }
    if (files.map((f) => f.id).toSet().length != files.length) {
      return _error(r, HttpStatus.badRequest, 'Duplicate file ids');
    }

    if (_pending != null || (_session?.isActive ?? false)) {
      return _error(r, HttpStatus.conflict, 'Blocked by another session');
    }

    final request = LsIncomingRequest(
      sessionId: lsRandomId(),
      senderIp: ip,
      sender: info,
      files: files,
    );
    _pending = request;

    // The decision may take long. dart:io does not report a client that
    // disconnects while the server has not answered yet, so the socket is
    // detached and watched: official senders withdraw a pending request by
    // just closing the connection.
    Socket? socket;
    try {
      socket = await r.response.detachSocket(writeHeaders: false);
      socket.listen(
        (_) {},
        onDone: () => _withdraw(request),
        onError: (Object _) => _withdraw(request),
        cancelOnError: true,
      );
    } catch (e) {
      LsLog.d('detachSocket failed: $e');
      _withdraw(request);
    }

    LsReceiveDecision decision;
    try {
      final decide = onIncoming;
      if (decide == null || request.isCancelled) {
        decision = const LsReceiveDecision.decline();
      } else {
        decision = await Future.any([
          decide(request),
          request.cancelled.then((_) => const LsReceiveDecision.decline()),
        ]);
      }
    } catch (e) {
      LsLog.d('decision failed: $e');
      decision = const LsReceiveDecision.decline();
    }
    if (_pending == request) _pending = null;
    if (socket == null) return;

    if (request.isCancelled) {
      return _rawRespond(socket, 403, {'message': 'Cancelled by sender'});
    }
    if (!decision.accepted) {
      return _rawRespond(socket, 403, {'message': 'Rejected'});
    }
    if (_server == null) {
      return _rawRespond(socket, 500, {'message': 'Stopped'});
    }
    final ids = decision.fileIds;
    final accepted = {
      for (final f in files)
        if (ids == null || ids.contains(f.id))
          f.id: LsReceiveFile(f, lsRandomId()),
    };
    if (accepted.isEmpty) return _rawRespond(socket, 204, null);

    final session = LsReceiveSession(
      id: request.sessionId,
      senderIp: ip,
      sender: info,
      destination: _destination,
      files: accepted,
    );
    _session = session;
    _notify(session, force: true);
    return _rawRespond(socket, 200, {
      'sessionId': session.id,
      'files': {for (final e in accepted.entries) e.key: e.value.token},
    });
  }

  void _withdraw(LsIncomingRequest request) {
    if (_pending == request && !request._cancelled.isCompleted) {
      request._cancelled.complete();
    }
  }

  /// Writes a complete HTTP/1.1 response to a detached socket and closes it.
  Future<void> _rawRespond(Socket socket, int status, Object? json) async {
    final body = json == null ? const <int>[] : utf8.encode(jsonEncode(json));
    final reason = switch (status) {
      200 => 'OK',
      204 => 'No Content',
      403 => 'Forbidden',
      _ => 'Internal Server Error',
    };
    final head = StringBuffer('HTTP/1.1 $status $reason\r\n');
    if (json != null) {
      head.write('content-type: application/json; charset=utf-8\r\n');
    }
    if (status != 204) {
      head.write('content-length: ${body.length}\r\n');
    }
    head.write('connection: close\r\n\r\n');
    try {
      socket.add(ascii.encode(head.toString()));
      if (body.isNotEmpty) socket.add(body);
      await socket.flush();
      await socket.close();
    } catch (_) {
      socket.destroy();
    }
  }

  Future<void> _cancelRoute(HttpRequest r, String ip) async {
    await r.drain<void>();
    final sessionId = r.uri.queryParameters['sessionId'];
    final pending = _pending;
    if (pending != null &&
        pending.senderIp == ip &&
        (sessionId == null || sessionId == pending.sessionId)) {
      if (!pending._cancelled.isCompleted) pending._cancelled.complete();
      return _empty(r, HttpStatus.ok);
    }
    final session = _session;
    if (session != null &&
        session.isActive &&
        session.senderIp == ip &&
        sessionId == session.id) {
      session._cancel(LsReceiveState.cancelledBySender);
      _session = null;
      _notify(session, force: true);
      unawaited(_cleanupTemp(session));
      return _empty(r, HttpStatus.ok);
    }
    try {
      onForeignCancel?.call(ip, sessionId);
    } catch (e) {
      LsLog.d('onForeignCancel failed: $e');
    }
    return _empty(r, HttpStatus.ok);
  }

  Future<void> _upload(HttpRequest r, String ip) async {
    final q = r.uri.queryParameters;
    final sessionId = q['sessionId'];
    final fileId = q['fileId'];
    final token = q['token'];
    if (sessionId == null || fileId == null || token == null) {
      await r.drain<void>();
      return _error(r, HttpStatus.badRequest, 'Missing parameters');
    }
    final session = _session;
    final file = session?.files[fileId];
    if (session == null ||
        !session.isActive ||
        session.id != sessionId ||
        session.senderIp != ip ||
        file == null ||
        file.token != token ||
        file.status != LsReceiveFileStatus.queued) {
      // Do not read the body: the connection is closed after the answer.
      return _error(r, HttpStatus.forbidden, 'Invalid token or IP address');
    }

    file
      ..status = LsReceiveFileStatus.receiving
      ..received = 0
      ..attempts += 1
      ..error = null;
    session._inFlight++;
    session._lastActivity = DateTime.now();
    _notify(session, force: true);

    final tempDir = Directory(p.join(session.destination, tempFolderName));
    final temp = File(
      p.join(tempDir.path, '${session.id}_${file.dto.id}.part'),
    );
    RandomAccessFile? raf;
    var cancelled = false;
    try {
      await tempDir.create(recursive: true);
      raf = await temp.open(mode: FileMode.write);
      final out = raf;
      final buffer = BytesBuilder(copy: false);
      var received = 0;
      var lastChunk = DateTime.now();
      final done = Completer<void>();
      late final StreamSubscription<Uint8List> sub;
      void onSessionCancelled() {
        cancelled = true;
        if (!done.isCompleted) {
          done.completeError(const LsException(LsErrorKind.cancelled));
        }
        unawaited(sub.cancel());
      }

      void fail(Object e) {
        if (!done.isCompleted) done.completeError(e);
        unawaited(sub.cancel());
      }

      sub = r.listen(
        (chunk) {
          received += chunk.length;
          if (received > file.dto.size) {
            fail(
              const LsException(
                LsErrorKind.protocol,
                'more data than announced',
              ),
            );
            return;
          }
          buffer.add(chunk);
          file.received = received;
          lastChunk = session._lastActivity = DateTime.now();
          if (buffer.length >= 1 << 20) {
            sub.pause();
            out.writeFrom(buffer.takeBytes()).then((_) {
              if (!done.isCompleted) sub.resume();
            }, onError: fail);
          }
          _notify(session);
        },
        onError: (Object e) => fail(e),
        onDone: () async {
          try {
            if (buffer.isNotEmpty) await out.writeFrom(buffer.takeBytes());
            if (!done.isCompleted) done.complete();
          } catch (e) {
            fail(e);
          }
        },
        cancelOnError: true,
      );
      session._cancelCallbacks.add(onSessionCancelled);
      // A sender that vanishes (left the Wi-Fi) never ends its request.
      final idle = Timer.periodic(const Duration(seconds: 5), (_) {
        if (DateTime.now().difference(lastChunk) > uploadIdleTimeout) {
          fail(
            const LsException(
              LsErrorKind.timeout,
              'the sender stopped sending',
            ),
          );
        }
      });
      try {
        await done.future;
      } finally {
        idle.cancel();
        session._cancelCallbacks.remove(onSessionCancelled);
      }
      await out.close();
      raf = null;

      if (received != file.dto.size) {
        throw LsException(
          LsErrorKind.protocol,
          'received $received of ${file.dto.size} bytes',
        );
      }

      final expected = file.dto.sha256;
      if (expected != null && expected.isNotEmpty) {
        final actual = await lsSha256OfFile(temp.path);
        if (actual.toLowerCase() != expected.toLowerCase()) {
          await _deleteQuietly(temp);
          file
            ..received = 0
            ..status = file.attempts < _maxUploadAttempts
                ? LsReceiveFileStatus.queued
                : LsReceiveFileStatus.failed
            ..error = 'Checksum mismatch';
          await _error(r, HttpStatus.unprocessableEntity, 'Checksum mismatch');
          return;
        }
      }

      if (!session.isActive) throw const LsException(LsErrorKind.cancelled);
      final target = LsNames.resolveTarget(
        session.destination,
        LsNames.safeSegments(file.dto.fileName),
        session._reserved,
      );
      if (!p.isWithin(session.destination, target)) {
        throw const LsException(LsErrorKind.io, 'invalid file name');
      }
      await Directory(p.dirname(target)).create(recursive: true);
      await _move(temp, target);
      final modified = file.dto.modified;
      if (modified != null) {
        try {
          await File(target).setLastModified(modified);
        } catch (_) {}
      }
      file
        ..savedPath = target
        ..received = file.dto.size
        ..status = LsReceiveFileStatus.done;
      await _empty(r, HttpStatus.ok);
    } catch (e) {
      try {
        await raf?.close();
      } catch (_) {}
      await _deleteQuietly(temp);
      if (file.status == LsReceiveFileStatus.receiving) {
        file
          ..status = LsReceiveFileStatus.failed
          ..error = cancelled ? 'Cancelled' : _describe(e);
      }
      LsLog.d('upload of ${file.dto.fileName} failed: $e');
      try {
        if (cancelled || !session.isActive) {
          await _error(r, HttpStatus.forbidden, 'Session cancelled');
        } else {
          await _error(r, HttpStatus.internalServerError, _describe(e));
        }
      } catch (_) {}
    } finally {
      session._inFlight--;
      session._lastActivity = DateTime.now();
      _finishIfComplete(session);
      if (!session.isActive && session._inFlight == 0) {
        unawaited(_cleanupTemp(session));
      }
      _notify(session, force: true);
    }
  }

  String _describe(Object e) => switch (e) {
    LsException(:final detail?) => detail,
    FileSystemException(:final message, :final osError) =>
      osError == null ? message : '$message (${osError.message})',
    _ => e.toString(),
  };

  void _finishIfComplete(LsReceiveSession session) {
    if (!session.isActive) return;
    if (session.files.values.every((f) => f.isFinal)) {
      session.state = LsReceiveState.finished;
      session.endedAt = DateTime.now();
      if (identical(_session, session)) _session = null;
    }
  }

  Future<void> _move(File from, String to) async {
    try {
      await from.rename(to);
    } on FileSystemException {
      // Different file systems: copy then delete.
      await from.copy(to);
      await _deleteQuietly(from);
    }
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _cleanupTemp(LsReceiveSession session) async {
    // Give aborted uploads a moment to release their files.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final dir = Directory(p.join(session.destination, tempFolderName));
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (p.basename(e.path).startsWith('${session.id}_')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      if (await dir.list().isEmpty) await dir.delete();
    } catch (_) {}
  }

  /// Removes temp files left behind by a previous run.
  static Future<void> cleanupStaleTemp(String destination) async {
    final dir = Directory(p.join(destination, tempFolderName));
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}
