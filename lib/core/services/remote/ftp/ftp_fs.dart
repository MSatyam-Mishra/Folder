import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/remote/ftp/ftp_listing.dart';
import 'package:folders/core/services/remote/known_hosts.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart' show remoteError;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

const _passive = RemoteOptionField(
  key: 'passive',
  label: 'Passive mode',
  description: 'Leave on unless the server asks for active mode',
  defaultValue: 'true',
);

/// "FTP" in "Add a place".
final ftpProtocol = RemoteProtocolInfo(
  protocol: RemoteProtocol.ftp,
  label: 'FTP',
  description: 'Not encrypted: for your own network',
  icon: LucideIcons.server,
  defaultPort: 21,
  hostHint: 'nas.local or 192.168.1.5',
  options: const [_passive],
  create: (connection, secrets) => FtpFileSystem(connection, secrets),
);

/// "FTPS" in "Add a place": FTP over TLS, explicit (AUTH TLS on port 21)
/// or implicit (TLS from the start, usually on port 990).
final ftpsProtocol = RemoteProtocolInfo(
  protocol: RemoteProtocol.ftps,
  label: 'FTPS (FTP over TLS)',
  description: 'Encrypted FTP',
  icon: LucideIcons.shieldCheck,
  defaultPort: 21,
  hostHint: 'nas.local or 192.168.1.5',
  options: const [
    _passive,
    RemoteOptionField(
      key: 'implicitTls',
      label: 'Implicit TLS',
      description: 'Encrypted from the start, usually on port 990',
    ),
  ],
  create: (connection, secrets) => FtpFileSystem(connection, secrets),
);

/// How long to wait for the server's answer.
const _timeout = Duration(seconds: 20);

/// Prints the control connection's lines when set (passwords hidden).
void Function(String line)? ftpDebugLog;

/// [RemoteFileSystem] over FTP or FTPS. Each FTP connection does one thing
/// at a time, so it keeps a few signed-in sessions: browsing goes on while
/// a file is copied or a video streams.
class FtpFileSystem implements RemoteFileSystem {
  FtpFileSystem(this.connection, this.secrets, {this.maxSessions = 3, RemoteKnownHosts? knownHosts})
      : knownHosts = knownHosts ?? RemoteKnownHosts.instance;

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;
  final int maxSessions;
  final RemoteKnownHosts knownHosts;

  final _idle = <_FtpSession>[];
  final _waiting = Queue<Completer<void>>();
  int _sessions = 0;
  String _password = '';
  bool _closed = false;

  bool get _tls => connection.protocol == RemoteProtocol.ftps;
  bool get _implicit => _tls && connection.options['implicitTls'] == 'true';
  bool get _passiveMode => connection.options['passive'] != 'false';
  int get _port => connection.port ?? (_implicit ? 990 : 21);

  @override
  Future<void> connect() async {
    await close();
    _closed = false;
    _password = await secrets.read('password') ?? '';
    // Signs in once, so a wrong password shows at once.
    _idle.add(await _open());
    _sessions = 1;
  }

  Future<_FtpSession> _open() async {
    final session = _FtpSession(
      host: connection.host,
      port: _port,
      tls: _tls,
      implicit: _implicit,
      passive: _passiveMode,
      trust: _tls ? TlsTrust(connection.host, _port, known: knownHosts) : null,
    );
    try {
      await session.open(connection.username.isEmpty ? 'anonymous' : connection.username, _password);
    } catch (e) {
      session.destroy();
      rethrow;
    }
    return session;
  }

  /// A free session, opening one if there are fewer than [maxSessions].
  Future<_FtpSession> _take() async {
    while (true) {
      if (_closed) throw const RemoteException(RemoteErrorKind.network, 'The connection to the server closed.');
      if (_idle.isNotEmpty) return _idle.removeLast();
      if (_sessions < maxSessions) {
        _sessions++;
        try {
          return await _open();
        } catch (e) {
          _sessions--;
          _wakeOne();
          rethrow;
        }
      }
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
  }

  void _give(_FtpSession session) {
    if (_closed || session.broken) {
      session.destroy();
      _sessions--;
    } else {
      _idle.add(session);
    }
    _wakeOne();
  }

  void _wakeOne() {
    if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
  }

  Future<T> _with<T>(Future<T> Function(_FtpSession session) action) async {
    final session = await _take();
    try {
      return await action(session);
    } catch (e) {
      if (e is! RemoteException || e.kind == RemoteErrorKind.network) session.broken = true;
      throw e is RemoteException ? e : remoteError(e);
    } finally {
      _give(session);
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) => _with((s) => s.list(RemotePaths.normalize(path)));

  @override
  Future<RemoteEntry> stat(String path) => _with((s) => s.stat(RemotePaths.normalize(path)));

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    final normal = RemotePaths.normalize(path);
    if (end != null && end <= start) return;
    final session = await _take();
    var finished = false;
    try {
      yield* session.retrieve(normal, start, end);
      finished = true;
    } catch (e) {
      session.broken = session.broken || e is! RemoteException || e.kind == RemoteErrorKind.network;
      throw e is RemoteException ? e : remoteError(e);
    } finally {
      // Stopped early (a video seeking): the transfer is aborted.
      if (!finished && !session.broken) await session.abortTransfer();
      _give(session);
    }
  }

  @override
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  }) =>
      _with((s) async {
        final normal = RemotePaths.normalize(path);
        if (!overwrite && await s.exists(normal)) {
          throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(normal)}" is already there');
        }
        await s.store(normal, data, onProgress);
      });

  @override
  Future<void> createDirectory(String path) => _with((s) async {
        final normal = RemotePaths.normalize(path);
        final reply = await s.command('MKD $normal');
        if (!reply.isOk) {
          if (await s.exists(normal)) {
            throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(normal)}" is already there');
          }
          throw s.failure(reply, normal);
        }
      });

  @override
  Future<void> delete(String path) => _with((s) => s.deleteTree(RemotePaths.normalize(path)));

  @override
  Future<void> rename(String from, String to) => _with((s) async {
        final source = RemotePaths.normalize(from);
        final target = RemotePaths.normalize(to);
        if (source.toLowerCase() != target.toLowerCase() && await s.exists(target)) {
          throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(target)}" is already there');
        }
        final first = await s.command('RNFR $source');
        if (!first.isIntermediate) throw s.failure(first, source);
        final second = await s.command('RNTO $target');
        if (!second.isOk) throw s.failure(second, target);
      });

  @override
  Future<void> close() async {
    _closed = true;
    final sessions = [..._idle];
    _idle.clear();
    _sessions = 0;
    for (final session in sessions) {
      await session.quit();
    }
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    }
  }
}

/// One signed-in FTP control connection.
class _FtpSession {
  _FtpSession({
    required this.host,
    required this.port,
    required this.tls,
    required this.implicit,
    required this.passive,
    this.trust,
  });

  final String host;
  final int port;
  final bool tls;
  final bool implicit;
  final bool passive;
  final TlsTrust? trust;

  late _Control _control;
  bool broken = false;
  bool _mlsd = false;
  bool _mlst = false;
  bool _epsv = true;
  bool _protected = false;
  Socket? _transfer;

  Future<void> open(String user, String password) async {
    await trust?.prepare();
    Socket socket;
    try {
      socket = implicit
          ? await SecureSocket.connect(host, port, timeout: _timeout, onBadCertificate: trust?.onBadCertificate)
          : await Socket.connect(host, port, timeout: _timeout);
    } catch (e) {
      throw trust?.failure() ?? remoteError(e);
    }
    _control = _Control(socket);
    final welcome = await _control.read();
    if (!welcome.isOk) throw RemoteException(RemoteErrorKind.network, 'The server turned the connection down: ${welcome.message}');
    if (tls && !implicit) {
      final auth = await command('AUTH TLS');
      if (!auth.isOk) {
        throw RemoteException(RemoteErrorKind.unsupported, "The server doesn't offer FTPS: ${auth.message}");
      }
      try {
        await _control.secure(host, trust?.onBadCertificate);
      } catch (e) {
        throw trust?.failure() ?? remoteError(e);
      }
    }
    var reply = await command('USER $user');
    if (reply.code == 331 || reply.code == 332) reply = await command('PASS $password');
    if (!reply.isOk) {
      throw RemoteException(
        reply.code == 530 ? RemoteErrorKind.auth : RemoteErrorKind.other,
        reply.code == 530 ? 'The server refused the user name or password.' : 'Signing in failed: ${reply.message}',
      );
    }
    if (tls) {
      await command('PBSZ 0');
      _protected = (await command('PROT P')).isOk;
    }
    final feat = await command('FEAT');
    if (feat.isOk) {
      final features = feat.lines.map((l) => l.trim().toUpperCase()).toList();
      _mlsd = features.any((f) => f.startsWith('MLSD') || f.startsWith('MLST'));
      _mlst = features.any((f) => f.startsWith('MLST'));
      if (features.any((f) => f.startsWith('UTF8'))) await command('OPTS UTF8 ON');
    }
    await command('TYPE I');
  }

  Future<FtpReply> command(String line) async {
    _control.send(line);
    final reply = await _control.read();
    if (reply.code == 421) {
      broken = true;
      throw RemoteException(RemoteErrorKind.network, 'The server closed the connection: ${reply.message}');
    }
    return reply;
  }

  RemoteException failure(FtpReply reply, String path) {
    final name = RemotePaths.nameOf(path);
    final text = reply.message.toLowerCase();
    if (reply.code == 530) return const RemoteException(RemoteErrorKind.auth, 'The server wants you to sign in again.');
    if (reply.code == 550 || reply.code == 450) {
      if (text.contains('denied') || text.contains('permission') || text.contains('not allowed')) {
        return RemoteException(RemoteErrorKind.permission, 'The server didn\'t allow it for "$name".');
      }
      if (text.contains('exist') && !text.contains('not exist') && !text.contains("doesn't exist")) {
        return RemoteException(RemoteErrorKind.alreadyExists, '"$name" is already there');
      }
      return RemoteException(RemoteErrorKind.notFound, '"$name" isn\'t there any more.');
    }
    if (reply.code == 553) return RemoteException(RemoteErrorKind.permission, 'The server didn\'t allow the name "$name".');
    if (reply.code == 500 || reply.code == 502 || reply.code == 504) {
      return RemoteException(RemoteErrorKind.unsupported, "The server can't do that: ${reply.message}");
    }
    return RemoteException(RemoteErrorKind.other, reply.message.isEmpty ? 'The server refused it (${reply.code}).' : reply.message);
  }

  /// A data connection for one transfer, then [verb] sent; returns the
  /// socket once the server said the transfer starts.
  Future<Socket> _startTransfer(String verb, String path) async {
    final line = path.isEmpty ? verb : '$verb $path';
    if (!passive) return _activeTransfer(line, path);
    final raw = await _passiveSocket(path);
    _control.send(line);
    final reply = _control.read();
    Future<Socket>? secured;
    if (_protected) {
      // TLS on the data connection once the server said it starts, as most
      // servers want; if it says nothing for a while, it may be waiting for
      // the handshake first.
      final early = await Future.any([
        reply.then((_) => false, onError: (Object _) => false),
        Future<bool>.delayed(const Duration(seconds: 2), () => true),
      ]);
      if (early) {
        secured = _secure(raw);
        secured.ignore();
      }
    }
    final first = await reply;
    if (!first.isPreliminary) {
      raw.destroy();
      throw first.isOk ? RemoteException(RemoteErrorKind.other, first.message) : failure(first, path);
    }
    if (!_protected) return raw;
    return secured ?? await _secure(raw);
  }

  /// Active mode: the server connects to this device.
  Future<Socket> _activeTransfer(String line, String path) async {
    final address = _control.socket.address;
    final listener = await ServerSocket.bind(address, 0);
    try {
      final port = listener.port;
      final reply = address.type == InternetAddressType.IPv6
          ? await command('EPRT |2|${address.address}|$port|')
          : await command('PORT ${address.address.replaceAll('.', ',')},${port >> 8},${port & 255}');
      if (!reply.isOk) throw failure(reply, path);
      final accepted = listener.first.timeout(_timeout);
      accepted.ignore();
      _control.send(line);
      final first = await _control.read();
      if (!first.isPreliminary) {
        throw first.isOk ? RemoteException(RemoteErrorKind.other, first.message) : failure(first, path);
      }
      return await _protect(await accepted);
    } finally {
      await listener.close();
    }
  }

  Future<Socket> _protect(Socket raw) => _protected ? _secure(raw) : Future.value(raw);

  Future<Socket> _secure(Socket raw) => SecureSocket.secure(raw, host: host, onBadCertificate: trust?.onBadCertificate);

  Future<Socket> _passiveSocket(String path) async {
    if (_epsv) {
      final reply = await command('EPSV');
      final port = reply.isOk ? parseEpsv(reply.message) : null;
      if (port != null) return Socket.connect(_control.socket.remoteAddress, port, timeout: _timeout);
      _epsv = false;
    }
    final reply = await command('PASV');
    final target = reply.isOk ? parsePasv(reply.message) : null;
    if (target == null) throw failure(reply, path);
    // The server's own address: behind a router, PASV often names one that
    // can't be reached from here.
    return Socket.connect(_control.socket.remoteAddress, target.$2, timeout: _timeout);
  }

  /// Reads the transfer's final answer.
  Future<void> _finish(String path) async {
    final reply = await _control.read();
    if (!reply.isOk) throw failure(reply, path);
  }

  /// Ends a data connection that was read to its end. Over TLS this
  /// answers the server's close_notify: some servers wait for it before
  /// saying the transfer is done.
  static Future<void> _closeData(Socket socket) async {
    try {
      await socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<List<String>> _lines(String verb, String path) async {
    final socket = await _startTransfer(verb, path);
    _transfer = socket;
    final bytes = <int>[];
    try {
      await for (final chunk in socket.timeout(_timeout)) {
        bytes.addAll(chunk);
      }
      await _closeData(socket);
    } finally {
      _transfer = null;
      socket.destroy();
    }
    await _finish(path);
    return const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true));
  }

  Future<List<RemoteEntry>> list(String folder) async {
    if (_mlsd) {
      final lines = await _lines('MLSD', folder);
      return [for (final line in lines) ?parseMlsdLine(line, folder)];
    }
    final cwd = await command('CWD $folder');
    if (!cwd.isOk) throw failure(cwd, folder);
    final lines = await _lines('LIST', '');
    return [for (final line in lines) ?parseListLine(line, folder)];
  }

  Future<RemoteEntry> stat(String path) async {
    if (path == '/') return const RemoteEntry(path: '/', isDirectory: true);
    if (_mlst) {
      final reply = await command('MLST $path');
      if (reply.isOk) {
        for (final line in reply.lines.skip(1)) {
          final text = line.trimLeft();
          if (text.isEmpty || RegExp(r'^\d{3}[ -]').hasMatch(line)) continue;
          final entry = parseMlsdLine(text, RemotePaths.parentOf(path));
          if (entry != null) return RemoteEntry(path: path, isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified);
        }
      } else if (reply.code == 550) {
        throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(path)}" isn\'t there any more.');
      }
    }
    // Looked for in its folder's listing.
    final name = RemotePaths.nameOf(path);
    for (final entry in await list(RemotePaths.parentOf(path))) {
      if (entry.name == name) return entry;
    }
    throw RemoteException(RemoteErrorKind.notFound, '"$name" isn\'t there any more.');
  }

  Future<bool> exists(String path) async {
    try {
      await stat(path);
      return true;
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return false;
      rethrow;
    }
  }

  Stream<List<int>> retrieve(String path, int start, int? end) async* {
    if (start > 0) {
      final rest = await command('REST $start');
      if (!rest.isIntermediate) throw RemoteException(RemoteErrorKind.unsupported, "The server can't start a file part way: ${rest.message}");
    }
    final socket = await _startTransfer('RETR', path);
    _transfer = socket;
    var left = end == null ? null : end - start;
    var complete = false;
    try {
      await for (final chunk in socket.timeout(const Duration(minutes: 2))) {
        if (left == null) {
          yield chunk;
          continue;
        }
        if (chunk.length >= left) {
          if (left > 0) yield chunk.sublist(0, left);
          left = 0;
          break;
        }
        left -= chunk.length;
        yield chunk;
      }
      if (left == null) {
        complete = true;
        _transfer = null;
        await _closeData(socket);
        socket.destroy();
        await _finish(path);
      }
    } finally {
      if (!complete) {
        // Stopped before the end: [abortTransfer] tidies up.
        _transfer = socket;
      }
    }
    if (!complete) await abortTransfer();
  }

  /// Ends a transfer stopped part way, so the session can be used again.
  Future<void> abortTransfer() async {
    final socket = _transfer;
    if (socket == null) return;
    _transfer = null;
    socket.destroy();
    try {
      _control.send('ABOR');
      // 426 for the transfer, then 226 for ABOR; some send only one.
      var reply = await _control.read(timeout: const Duration(seconds: 5));
      if (reply.code == 426 || reply.code == 451 || reply.isPreliminary) {
        reply = await _control.read(timeout: const Duration(seconds: 5));
      }
      // A 226 for the transfer may be followed by ABOR's own.
      final extra = await _control.read(timeout: const Duration(milliseconds: 300)).then<FtpReply?>((r) => r, onError: (_) => null);
      if (extra != null && !extra.isOk) broken = true;
    } catch (_) {
      broken = true;
    }
  }

  Future<void> store(String path, Stream<List<int>> data, void Function(int sent)? onProgress) async {
    final socket = await _startTransfer('STOR', path);
    var sent = 0;
    try {
      await socket.addStream(data.map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent);
        return chunk;
      }));
      await socket.flush();
      await socket.close();
    } catch (e) {
      socket.destroy();
      broken = true;
      rethrow;
    }
    await _finish(path);
  }

  Future<void> deleteTree(String path) async {
    final entry = await stat(path);
    if (!entry.isDirectory) {
      final reply = await command('DELE $path');
      if (!reply.isOk) throw failure(reply, path);
      return;
    }
    for (final child in await list(path)) {
      await deleteTree(child.path);
    }
    final reply = await command('RMD $path');
    if (!reply.isOk) throw failure(reply, path);
  }

  Future<void> quit() async {
    try {
      _control.send('QUIT');
      await _control.read(timeout: const Duration(seconds: 2));
    } catch (_) {}
    destroy();
  }

  void destroy() {
    try {
      _transfer?.destroy();
      _control.socket.destroy();
    } catch (_) {}
  }
}

/// The control connection's lines, read as they come.
class _Control {
  _Control(this.socket) {
    _listen();
  }

  Socket socket;
  StreamSubscription<List<int>>? _subscription;
  final _bytes = <int>[];
  final _lines = Queue<String>();
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  void _listen() {
    _subscription = socket.listen(
      (data) {
        _bytes.addAll(data);
        while (true) {
          final end = _bytes.indexOf(10);
          if (end < 0) break;
          var line = utf8.decode(_bytes.sublist(0, end), allowMalformed: true);
          if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
          _bytes.removeRange(0, end + 1);
          _lines.add(line);
        }
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void send(String line) => socket.add(utf8.encode('$line\r\n'));

  Future<String> _line(Duration timeout) async {
    while (_lines.isEmpty) {
      if (_error != null) throw remoteError(_error!);
      if (_done) throw const RemoteException(RemoteErrorKind.network, 'The server closed the connection.');
      final waiter = _waiter = Completer<void>();
      await waiter.future.timeout(timeout);
    }
    return _lines.removeFirst();
  }

  Future<FtpReply> read({Duration timeout = _timeout}) async {
    final first = await _line(timeout);
    final code = int.tryParse(first.length >= 3 ? first.substring(0, 3) : '');
    if (code == null) throw RemoteException(RemoteErrorKind.other, 'The server answered something unexpected: $first');
    final lines = [first];
    if (first.length > 3 && first[3] == '-') {
      while (true) {
        final line = await _line(timeout);
        lines.add(line);
        if (line.length >= 4 && line.startsWith('$code ')) break;
      }
    }
    ftpDebugLog?.call('< ${lines.join(' | ')}');
    return FtpReply(code, lines);
  }

  /// AUTH TLS: the connection goes on encrypted.
  Future<void> secure(String host, bool Function(X509Certificate)? onBadCertificate) async {
    _subscription?.pause();
    final secure = await SecureSocket.secure(socket, host: host, onBadCertificate: onBadCertificate).timeout(_timeout);
    socket = secure;
    _listen();
  }
}
