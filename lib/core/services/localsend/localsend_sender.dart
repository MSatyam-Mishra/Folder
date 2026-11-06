// Sending files to a peer (spec section 4, client side).

import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/localsend/localsend_client.dart';
import 'package:folders/core/services/localsend/localsend_hash.dart';
import 'package:folders/core/services/localsend/localsend_models.dart';
import 'package:folders/core/services/localsend/localsend_names.dart';
import 'package:path/path.dart' as p;

/// One file to send. [fileName] may contain `/`-separated folders.
class LsSendFile {
  LsSendFile({
    required this.path,
    required this.fileName,
    required this.size,
    this.modified,
    String? id,
  }) : id = id ?? lsRandomId();

  final String id;
  final String path;
  final String fileName;
  final int size;
  final DateTime? modified;

  /// Expands files and folders (recursively, without following links) the
  /// way the official apps do: a folder `Photos` yields `Photos/a.jpg`,
  /// `Photos/2024/b.jpg`, ...
  static Future<List<LsSendFile>> collect(
    Iterable<FileSystemEntity> items,
  ) async {
    final out = <LsSendFile>[];
    for (final item in items) {
      final type = await FileSystemEntity.type(item.path);
      if (type == FileSystemEntityType.file) {
        final f = await _fromFile(File(item.path), p.basename(item.path));
        if (f != null) out.add(f);
      } else if (type == FileSystemEntityType.directory) {
        final root = p.basename(p.normalize(item.path));
        final files = <LsSendFile>[];
        try {
          await for (final e
              in Directory(item.path)
                  .list(recursive: true, followLinks: false)
                  .handleError((Object e) => LsLog.d('skipping: $e'))) {
            if (e is! File) continue;
            final rel = p.relative(e.path, from: item.path);
            final name = [root, ...p.split(rel)].join('/');
            final f = await _fromFile(e, name);
            if (f != null) files.add(f);
          }
        } catch (e) {
          LsLog.d('cannot list ${item.path}: $e');
        }
        files.sort((a, b) => a.fileName.compareTo(b.fileName));
        out.addAll(files);
      }
    }
    return out;
  }

  static Future<LsSendFile?> _fromFile(File file, String name) async {
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      return LsSendFile(
        path: file.path,
        fileName: name,
        size: stat.size,
        modified: stat.modified,
      );
    } catch (_) {
      return null;
    }
  }
}

enum LsSendState {
  preparing,
  waitingForPin,
  waitingForAcceptance,
  sending,
  finished,
  finishedWithErrors,
  declined,
  failed,
  cancelled,
  cancelledByReceiver,
}

enum LsSendFileStatus { queued, sending, done, failed, skipped }

class LsSendFileProgress {
  LsSendFileProgress(this.file);

  final LsSendFile file;
  LsSendFileStatus status = LsSendFileStatus.queued;
  int sent = 0;
  String? error;

  /// When the last byte was handed to the connection.
  DateTime? sentAllAt;
}

/// Asks the user for the receiver's PIN. Null aborts.
typedef LsPinPrompt = Future<String?> Function({required bool invalid});

class LsSendSession {
  LsSendSession({
    required this.client,
    required this.target,
    required this.self,
    required List<LsSendFile> files,
    this.concurrency = 3,
    this.withChecksums = false,
    this.askPin,
  }) : files = {for (final f in files) f.id: LsSendFileProgress(f)};

  final LsClient client;
  final LsDevice target;
  final LsDeviceInfo self;
  final Map<String, LsSendFileProgress> files;
  final int concurrency;
  final bool withChecksums;
  final LsPinPrompt? askPin;

  final _changes = StreamController<void>.broadcast();
  final _cancel = LsCancelToken();
  LsSendState state = LsSendState.preparing;
  LsException? error;
  String? sessionId;
  DateTime? sendingSince;
  DateTime? endedAt;
  bool _started = false;
  bool _stalled = false;
  DateTime _lastProgress = DateTime.now();

  /// Sending gives up when no data could be sent for this long.
  static Duration stallTimeout = const Duration(seconds: 60);

  Stream<void> get changes => _changes.stream;

  bool get isDone => switch (state) {
    LsSendState.finished ||
    LsSendState.finishedWithErrors ||
    LsSendState.declined ||
    LsSendState.failed ||
    LsSendState.cancelled ||
    LsSendState.cancelledByReceiver => true,
    _ => false,
  };

  int get totalBytes => files.values
      .where((f) => f.status != LsSendFileStatus.skipped)
      .fold(0, (s, f) => s + f.file.size);
  int get sentBytes => files.values.fold(0, (s, f) => s + f.sent);

  /// Bytes per second since the upload started.
  double get speed {
    final since = sendingSince;
    if (since == null) return 0;
    final ms = (endedAt ?? DateTime.now()).difference(since).inMilliseconds;
    return ms <= 0 ? 0 : sentBytes * 1000 / ms;
  }

  void _set(LsSendState s, [LsException? e]) {
    if (isDone) return; // terminal states are final
    state = s;
    if (e != null) error = e;
    if (isDone) endedAt ??= DateTime.now();
    _emit();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Runs the whole transfer; never throws (see [state] / [error]).
  Future<void> run() async {
    if (_started) return;
    _started = true;
    try {
      await _run();
    } on LsException catch (e) {
      if (_cancel.isCancelled || e.kind == LsErrorKind.cancelled) {
        if (!isDone) _set(LsSendState.cancelled);
      } else if (e.kind == LsErrorKind.declined) {
        _set(LsSendState.declined, e);
      } else {
        _set(LsSendState.failed, e);
      }
    } catch (e) {
      _set(LsSendState.failed, LsException(LsErrorKind.unknown, e.toString()));
    } finally {
      client.close();
      // Events added before close are still delivered.
      unawaited(_changes.close());
    }
  }

  Future<void> _run() async {
    final dtos = <LsFileDto>[];
    for (final f in files.values) {
      String? sha;
      if (withChecksums) {
        sha = await lsSha256OfFile(f.file.path);
        if (_cancel.isCancelled) throw const LsException(LsErrorKind.cancelled);
      }
      dtos.add(
        LsFileDto(
          id: f.file.id,
          fileName: f.file.fileName,
          size: f.file.size,
          fileType: LsNames.mimeTypeOf(f.file.fileName),
          sha256: sha,
          modified: f.file.modified,
        ),
      );
    }

    String? pin;
    LsPrepareResult? prepared;
    while (true) {
      _set(LsSendState.waitingForAcceptance);
      try {
        prepared = await client.prepareUpload(
          device: target,
          self: self,
          files: dtos,
          pin: pin,
          cancel: _cancel,
        );
        break;
      } on LsException catch (e) {
        if (e.kind == LsErrorKind.pinRequired ||
            e.kind == LsErrorKind.invalidPin) {
          final prompt = askPin;
          if (prompt == null) rethrow;
          _set(LsSendState.waitingForPin);
          final entered = await prompt(invalid: pin != null);
          if (entered == null || _cancel.isCancelled) {
            throw const LsException(LsErrorKind.cancelled);
          }
          pin = entered;
          continue;
        }
        rethrow;
      }
    }

    if (prepared == null) {
      // 204: the receiver needs nothing.
      for (final f in files.values) {
        f.status = LsSendFileStatus.skipped;
      }
      _set(LsSendState.finished);
      return;
    }
    final prep = prepared;
    sessionId = prep.sessionId;
    final queue = <LsSendFileProgress>[];
    for (final f in files.values) {
      if (prep.tokens.containsKey(f.file.id)) {
        queue.add(f);
      } else {
        f.status = LsSendFileStatus.skipped;
      }
    }
    sendingSince = DateTime.now();
    _lastProgress = DateTime.now();
    _set(LsSendState.sending);
    // A receiver that vanishes mid-upload would block a write (or the wait
    // for its answer) for minutes or forever: give up when nothing moves.
    final watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now();
      final stuck = files.values.any((f) {
        if (f.status != LsSendFileStatus.sending) return false;
        final allSent = f.sentAllAt;
        if (allSent == null) {
          return now.difference(_lastProgress) > stallTimeout;
        }
        // Everything sent, waiting for the answer: the receiver may still
        // be verifying a checksum (allow ~20 MB/s for that).
        final grace =
            stallTimeout +
            Duration(milliseconds: f.file.size ~/ (20 * 1024 * 1024) * 1000);
        return now.difference(allSent) > grace;
      });
      if (stuck) {
        _stalled = true;
        _cancel.cancel();
      }
    });

    LsException? fatal;
    var next = 0;
    Future<void> worker() async {
      while (next < queue.length && fatal == null && !_cancel.isCancelled) {
        final f = queue[next++];
        await _uploadOne(f, prep.sessionId, prep.tokens[f.file.id]!).catchError(
          (Object e) {
            final ex = e is LsException
                ? e
                : LsException(LsErrorKind.unknown, '$e');
            if (ex.kind == LsErrorKind.invalidToken ||
                ex.kind == LsErrorKind.busy) {
              fatal ??= ex;
            }
          },
        );
      }
    }

    try {
      await Future.wait(
        List.generate(concurrency.clamp(1, 8), (_) => worker()),
      );
    } finally {
      watchdog.cancel();
    }

    if (_stalled) {
      _set(
        LsSendState.failed,
        const LsException(
          LsErrorKind.timeout,
          'the receiver stopped responding',
        ),
      );
      return;
    }
    if (_cancel.isCancelled) {
      if (!isDone) _set(LsSendState.cancelled);
      return;
    }
    if (fatal != null) {
      _set(LsSendState.failed, fatal);
      return;
    }
    final failed = files.values.where(
      (f) => f.status == LsSendFileStatus.failed,
    );
    if (failed.isEmpty) {
      _set(LsSendState.finished);
    } else {
      _set(
        LsSendState.finishedWithErrors,
        LsException(LsErrorKind.unknown, '${failed.length} file(s) failed'),
      );
    }
  }

  Future<void> _uploadOne(
    LsSendFileProgress f,
    String sessionId,
    String token,
  ) async {
    for (var attempt = 1; ; attempt++) {
      f
        ..status = LsSendFileStatus.sending
        ..sent = 0
        ..sentAllAt = null;
      _emit();
      try {
        await client.upload(
          device: target,
          sessionId: sessionId,
          fileId: f.file.id,
          token: token,
          file: File(f.file.path),
          size: f.file.size,
          cancel: _cancel,
          onProgress: (sent) {
            f.sent = sent;
            _lastProgress = DateTime.now();
            if (sent >= f.file.size) f.sentAllAt ??= _lastProgress;
            _emit();
          },
        );
        f
          ..status = LsSendFileStatus.done
          ..sent = f.file.size;
        _emit();
        return;
      } on LsException catch (e) {
        // The receiver lets a file be re-sent after a checksum mismatch.
        if (e.kind == LsErrorKind.checksumMismatch && attempt < 3) continue;
        f
          ..status = LsSendFileStatus.failed
          ..error = e.message;
        _emit();
        rethrow;
      }
    }
  }

  /// Cancels locally and tells the receiver.
  Future<void> cancel() async {
    if (isDone || _cancel.isCancelled) return;
    // The UI shows "cancelled" at once; requests are aborted below.
    final previous = state;
    _set(LsSendState.cancelled);
    if (previous == LsSendState.waitingForPin ||
        previous == LsSendState.preparing) {
      _cancel.cancel();
      return;
    }
    final wasWaiting = previous == LsSendState.waitingForAcceptance;
    // Tell the receiver first, so it ends the session as cancelled rather
    // than seeing broken uploads; then abort our requests.
    final cancelClient = LsClient(
      client.identity,
      expectedFingerprint: client.expectedFingerprint,
      connectTimeout: const Duration(seconds: 2),
    );
    try {
      await cancelClient
          .cancel(device: target, sessionId: wasWaiting ? null : sessionId)
          .timeout(const Duration(seconds: 3), onTimeout: () {});
    } finally {
      cancelClient.close();
      _cancel.cancel();
    }
  }

  /// The receiver cancelled (`POST /cancel` to our server).
  void cancelledByReceiver() {
    if (isDone) return;
    _cancel.cancel();
    _set(
      LsSendState.cancelledByReceiver,
      const LsException(LsErrorKind.cancelledByPeer),
    );
  }
}
