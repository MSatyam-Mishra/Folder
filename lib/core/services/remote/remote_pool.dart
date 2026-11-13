import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';

/// The open connections to network places: one [RemoteFileSystem] per
/// place, connected when first needed, connected again after the line
/// dropped, and closed after [idleTimeout] unused.
class RemotePool {
  RemotePool({
    this.idleTimeout = const Duration(minutes: 5),
    bool? closeIdle,
    RemotePlaces? places,
    DateTime Function()? clock,
  })  : _closeIdle = closeIdle ?? !Platform.environment.containsKey('FLUTTER_TEST'),
        _places = places,
        _clock = clock ?? DateTime.now;

  static RemotePool instance = RemotePool();

  final Duration idleTimeout;
  final bool _closeIdle;
  final RemotePlaces? _places;
  final DateTime Function() _clock;
  final Map<String, _Pooled> _open = {};
  Timer? _timer;

  RemotePlaces get places => _places ?? RemotePlaces.instance;

  /// The places with a connection open or opening.
  Iterable<String> get openIds => _open.keys;

  _Pooled _entry(String id) => _open[id] ??= _Pooled(_clock());

  Future<RemoteFileSystem> _connected(String id, _Pooled entry) {
    return entry.ready ??= () async {
      await places.load();
      final place = places.byId(id);
      if (place == null) {
        throw const RemoteException(RemoteErrorKind.notFound, 'This place was removed. Add it again to open it.');
      }
      final info = RemoteProtocols.of(place.protocol);
      if (info == null || !info.available) {
        throw const RemoteException(RemoteErrorKind.unsupported, "This version of Folders can't open this kind of place.");
      }
      final fs = info.create(place, places.secretsOf(id));
      entry.fs = fs;
      try {
        await fs.connect();
      } catch (e) {
        unawaited(_quietClose(fs));
        rethrow;
      }
      entry.connectedOnce = true;
      _startTimer();
      return fs;
    }()
        .catchError((Object e) {
      // The next try connects anew (a password fixed meanwhile...).
      if (identical(_open[id], entry)) _open.remove(id);
      throw remoteError(e);
    });
  }

  /// Runs [action] on [id]'s connection. A connection that had worked and
  /// dropped is made again and [action] tried once more, unless not
  /// [retry] (it can't be repeated: it sends a stream).
  Future<T> run<T>(String id, Future<T> Function(RemoteFileSystem fs) action, {bool retry = true}) async {
    for (var attempt = 0;; attempt++) {
      final entry = _entry(id);
      entry.busy++;
      var stale = false;
      try {
        final fs = await _connected(id, entry);
        return await action(fs);
      } catch (e) {
        final error = remoteError(e);
        stale = error.kind == RemoteErrorKind.network && entry.connectedOnce;
        if (stale && retry && attempt == 0) continue;
        throw error;
      } finally {
        entry.busy--;
        entry.lastUsed = _clock();
        // Dropped: the next call connects again.
        if (stale) await _drop(id, entry);
      }
    }
  }

  /// [path]'s bytes from [start] to [end], connecting first if needed. If
  /// a connection that had worked dropped before anything came, it's made
  /// again once.
  Stream<List<int>> openRead(String id, String path, {int start = 0, int? end}) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? source;
    _Pooled? entry;
    var finished = false;
    void finish() {
      if (finished) return;
      finished = true;
      final e = entry;
      if (e != null) {
        e.busy--;
        e.lastUsed = _clock();
      }
    }

    Future<void> listen(int attempt) async {
      final current = entry = _entry(id);
      current.busy++;
      final RemoteFileSystem fs;
      try {
        fs = await _connected(id, current);
      } catch (e) {
        current.busy--;
        controller.addError(remoteError(e));
        finished = true;
        await controller.close();
        return;
      }
      if (controller.isClosed) {
        current.busy--;
        finished = true;
        return;
      }
      var got = false;
      source = fs.openRead(path, start: start, end: end).listen(
        (chunk) {
          got = true;
          controller.add(chunk);
        },
        onError: (Object e) async {
          final error = remoteError(e);
          if (!got && attempt == 0 && error.kind == RemoteErrorKind.network && current.connectedOnce) {
            await source?.cancel();
            current.busy--;
            await _drop(id, current);
            return listen(1);
          }
          controller.addError(error);
        },
        onDone: () {
          finish();
          controller.close();
        },
        cancelOnError: false,
      );
      if (controller.isPaused) source?.pause();
    }

    controller = StreamController<List<int>>(
      onListen: () => listen(0),
      onPause: () => source?.pause(),
      onResume: () => source?.resume(),
      onCancel: () async {
        final s = source;
        source = null;
        finish();
        await s?.cancel();
      },
    );
    return controller.stream;
  }

  /// Closes [id]'s connection, if open (the place was edited or removed).
  Future<void> close(String id) async {
    final entry = _open.remove(id);
    final fs = entry?.fs;
    if (fs != null) await _quietClose(fs);
  }

  Future<void> closeAll() async {
    _timer?.cancel();
    _timer = null;
    for (final id in [..._open.keys]) {
      await close(id);
    }
  }

  Future<void> _drop(String id, _Pooled entry) async {
    if (!identical(_open[id], entry)) return;
    _open.remove(id);
    final fs = entry.fs;
    if (fs != null) await _quietClose(fs);
  }

  /// Closes the connections unused for [idleTimeout]; a timer calls it.
  @visibleForTesting
  Future<void> closeIdleNow() async {
    final now = _clock();
    for (final MapEntry(key: id, value: entry) in [..._open.entries]) {
      if (entry.busy == 0 && entry.ready != null && now.difference(entry.lastUsed) >= idleTimeout) {
        await _drop(id, entry);
      }
    }
    if (_open.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() {
    if (!_closeIdle || _timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => closeIdleNow());
  }

  static Future<void> _quietClose(RemoteFileSystem fs) async {
    try {
      await fs.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}

class _Pooled {
  _Pooled(this.lastUsed);

  Future<RemoteFileSystem>? ready;
  RemoteFileSystem? fs;
  bool connectedOnce = false;
  int busy = 0;
  DateTime lastUsed;
}

/// [error] as a [RemoteException] with words for the user: the protocols
/// throw those, and anything else is mapped here (a socket that closed, a
/// timeout...).
RemoteException remoteError(Object error) {
  if (error is RemoteException) return error;
  if (error is TimeoutException) {
    return const RemoteException(RemoteErrorKind.network, "The server didn't answer in time.");
  }
  if (error is HandshakeException || error is TlsException) {
    return RemoteException(RemoteErrorKind.network, "A secure connection couldn't be made: ${error is TlsException ? error.message : error}");
  }
  if (error is SocketException) {
    final os = error.osError?.message.trim();
    return RemoteException(
      RemoteErrorKind.network,
      "Can't reach the server${os == null || os.isEmpty ? '' : ': $os'}.",
    );
  }
  if (error is FileSystemException) {
    return RemoteException(RemoteErrorKind.other, error.osError?.message ?? error.message);
  }
  return RemoteException(RemoteErrorKind.other, '$error');
}
