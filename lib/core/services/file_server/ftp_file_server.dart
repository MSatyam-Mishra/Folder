import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;

import 'package:folder/core/services/file_server/lan_address.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// How long to wait for a client to open (passive) or accept (active) a
/// data connection.
const _connectTimeout = Duration(seconds: 15);

/// Shares a folder with FTP clients on the local network: Windows File
/// Explorer, macOS Finder, FileZilla, phone apps, `curl`.
///
/// Plain FTP (RFC 959) with the RFC 3659 extensions (MLSD/MLST, SIZE, MDTM,
/// REST STREAM) and RFC 2428 extended passive/active mode; no TLS. Files
/// are always sent as binary and streamed from and to disk, so large files
/// and resumed transfers work. Nothing outside the shared folder can be
/// reached, and clients can only change things while [allowChanges] is on.
class FtpFileServer {
  FtpFileServer();

  static const _maxSessions = 64;

  /// Whether clients may upload, create folders, rename and delete.
  ///
  /// Checked on every command, so it can be changed while running.
  bool get allowChanges => _allowChanges && _only == null;
  set allowChanges(bool value) => _allowChanges = value;
  bool _allowChanges = false;

  /// When set, only these items of the folder are shared (names at its top
  /// level), read-only.
  Set<String>? _only;

  /// Login required when both are set (non-empty); otherwise any user
  /// name/password (anonymous) is accepted.
  ///
  /// Checked on every command: changing the login while running signs out
  /// sessions that logged in with something else.
  String? username;

  /// The password for [username].
  String? password;

  ServerSocket? _server;
  String _root = '';
  String _realRoot = '';
  List<String> _urls = const [];
  List<String> _lanHosts = const [];

  /// Every local IPv4 address, for answering PASV on the client's network.
  List<String> _localHosts = const [];
  final _sessions = <_FtpSession>{};
  final _received = StreamController<String>.broadcast();
  final _clients = ValueNotifier<int>(0);

  /// Whether the server is accepting connections.
  bool get isRunning => _server != null;

  /// Best address to open, e.g. `ftp://192.168.1.20:2121`.
  String? get url => _urls.isEmpty ? null : _urls.first;

  /// Every address the server can be reached at, best first.
  List<String> get urls => _urls;

  /// The port the server listens on, while running.
  int? get port => _server?.port;

  /// Paths of files clients finished uploading (STOR/APPE).
  Stream<String> get received => _received.stream;

  /// Number of connected control sessions.
  ValueListenable<int> get clients => _clients;

  bool get _loginRequired =>
      (username?.isNotEmpty ?? false) && (password?.isNotEmpty ?? false);

  /// Starts sharing [directory]; returns [url]. Uses the first free port
  /// from [port] to [port] + 9, or any free port if those are all taken.
  Future<String> start(
    String directory, {
    bool allowChanges = false,
    String? username,
    String? password,
    int port = 2121,
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
    this.allowChanges = allowChanges;
    this.username = username;
    this.password = password;

    ServerSocket? server;
    for (final candidate in [for (var i = 0; i < 10; i++) port + i, 0]) {
      try {
        server = await ServerSocket.bind(InternetAddress.anyIPv4, candidate);
        break;
      } on SocketException {
        if (candidate == 0) rethrow;
      }
    }
    _server = server;
    server!.listen(_accept, onError: (Object _) {});
    final addresses = await lanAddresses();
    _lanHosts = addresses;
    try {
      _localHosts = [
        for (final interface in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: true,
        ))
          for (final address in interface.addresses) address.address,
      ];
    } catch (_) {
      _localHosts = const [];
    }
    _urls = [
      for (final ip in addresses.isEmpty ? ['127.0.0.1'] : addresses)
        'ftp://$ip:${server.port}',
    ];
    return _urls.first;
  }

  /// Stops the server and disconnects every client.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _urls = const [];
    for (final session in _sessions.toList()) {
      session.close();
    }
    _sessions.clear();
    _clients.value = 0;
    await server?.close();
  }

  void _accept(Socket socket) {
    if (_server == null || _sessions.length >= _maxSessions) {
      socket.done.ignore();
      try {
        socket.add(utf8.encode('421 Too many connections, try later\r\n'));
        socket.close().whenComplete(socket.destroy).ignore();
      } catch (_) {
        socket.destroy();
      }
      return;
    }
    final session = _FtpSession(this, socket);
    _sessions.add(session);
    _clients.value = _sessions.length;
    // A bug in one session must not take down the server.
    runZonedGuarded(session.start, (error, stack) {
      debugPrint('FtpFileServer: session failed: $error\n$stack');
      session.close();
    });
  }

  void _removeSession(_FtpSession session) {
    if (_sessions.remove(session)) _clients.value = _sessions.length;
  }

  /// [target] if it exists inside the shared folder (also after following
  /// symlinks), else null.
  Future<String?> _checked(String target) async {
    if (target != _root && !p.isWithin(_root, target)) return null;
    if (_only != null &&
        target != _root &&
        !_only!.contains(p.split(p.relative(target, from: _root)).first)) {
      return null;
    }
    try {
      final real = await File(target).resolveSymbolicLinks();
      if (real != _realRoot && !p.isWithin(_realRoot, real)) return null;
    } on FileSystemException {
      return null;
    }
    return target;
  }
}

/// One client's control connection. Commands run one at a time, in order.
class _FtpSession {
  _FtpSession(this._server, this._socket);

  static const _idleTimeout = Duration(minutes: 15);
  static const _maxLineBytes = 8192;
  static const _maxQueued = 64;
  static const _maxFailedLogins = 5;
  static const _writeBuffer = 256 * 1024;
  static const _preLogin = {
    'USER',
    'PASS',
    'QUIT',
    'FEAT',
    'SYST',
    'OPTS',
    'NOOP',
    'HELP',
    'AUTH',
  };

  /// Telnet IP/Synch bytes some clients put before ABOR, stray whitespace.
  static final _leadingJunk = RegExp(r'^[^A-Za-z]+');

  final FtpFileServer _server;
  final Socket _socket;
  StreamSubscription<Uint8List>? _subscription;
  final _lineBytes = <int>[];
  final _queue = Queue<String>();
  bool _busy = false;
  bool _paused = false;
  bool _closing = false;
  bool _closed = false;
  Timer? _idle;
  String _peer = '';
  String _localHost = '';

  String _cwd = '/';
  String? _pendingUser;
  bool _loggedIn = false;
  String? _loginUser;
  String? _loginPassword;
  int _failedLogins = 0;
  int _restart = 0;
  String? _renameFrom;
  _DataChannel? _data;
  _DataChannel? _connecting;
  _Transfer? _transfer;

  void start() {
    _socket.done.ignore();
    try {
      _peer = _plainAddress(_socket.remoteAddress);
      _localHost = _plainAddress(_socket.address);
      _socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      close();
      return;
    }
    _subscription = _socket.listen(
      _onData,
      onError: (Object _) => close(),
      onDone: close,
      cancelOnError: true,
    );
    _reply(220, 'Folder FTP server ready');
    _resetIdle();
  }

  /// Drops the connection and anything it was transferring.
  void close() {
    if (_closed) return;
    _closed = _closing = true;
    _queue.clear();
    _idle?.cancel();
    _transfer?.abort();
    _connecting?.close();
    _data?.close();
    _data = null;
    _socket.destroy();
    _server._removeSession(this);
  }

  /// Sends what's queued, then closes.
  Future<void> _closeGracefully() async {
    if (_closing) return;
    _closing = true;
    _queue.clear();
    _idle?.cancel();
    try {
      await _socket.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
    close();
  }

  void _resetIdle() {
    _idle?.cancel();
    _idle = Timer(_idleTimeout, () {
      _reply(421, 'No commands for 15 minutes, closing connection');
      unawaited(_closeGracefully());
    });
  }

  // ---------------------------------------------------------------------
  // Control connection
  // ---------------------------------------------------------------------

  void _onData(Uint8List chunk) {
    for (final byte in chunk) {
      if (_closing) return;
      if (byte == 0x0a) {
        var end = _lineBytes.length;
        if (end > 0 && _lineBytes[end - 1] == 0x0d) end--;
        final line = const Utf8Decoder(
          allowMalformed: true,
        ).convert(_lineBytes, 0, end);
        _lineBytes.clear();
        _enqueue(line);
      } else if (_lineBytes.length >= _maxLineBytes) {
        _reply(500, 'Command line too long');
        unawaited(_closeGracefully());
        return;
      } else {
        _lineBytes.add(byte);
      }
    }
  }

  void _enqueue(String raw) {
    final line = raw.replaceFirst(_leadingJunk, '');
    if (_verbOf(line) == 'ABOR') {
      // Stop the running transfer now rather than after it.
      _transfer?.abort();
      _connecting?.close();
    }
    _queue.add(line);
    if (_queue.length >= _maxQueued && !_paused) {
      _paused = true;
      _subscription?.pause();
    }
    if (!_busy) unawaited(_pump());
  }

  Future<void> _pump() async {
    _busy = true;
    _idle?.cancel();
    while (_queue.isNotEmpty && !_closing) {
      final line = _queue.removeFirst();
      if (_paused && _queue.length < _maxQueued ~/ 4) {
        _paused = false;
        _subscription?.resume();
      }
      try {
        await _execute(line);
      } on FileSystemException catch (e) {
        _reply(550, 'Failed: ${e.osError?.message ?? e.message}');
      } catch (e, st) {
        // Never log the arguments: PASS has the password.
        debugPrint('FtpFileServer: ${_verbOf(line)} failed: $e\n$st');
        _reply(451, 'Requested action aborted: local error');
      }
    }
    _busy = false;
    if (!_closing) _resetIdle();
  }

  static String _verbOf(String line) {
    final space = line.indexOf(' ');
    return (space < 0 ? line : line.substring(0, space)).toUpperCase();
  }

  void _reply(int code, String text) => _write('$code ${_oneLine(text)}\r\n');

  /// A multi-line reply: `code-first`, the middle lines, `code last`.
  void _replyLines(int code, List<String> lines) {
    final out = StringBuffer('$code-${_oneLine(lines.first)}\r\n');
    for (final line in lines.sublist(1, lines.length - 1)) {
      final text = _oneLine(line);
      out.write(text.startsWith(RegExp('[0-9]')) ? ' $text\r\n' : '$text\r\n');
    }
    out.write('$code ${_oneLine(lines.last)}\r\n');
    _write(out.toString());
  }

  void _write(String text) {
    if (_closing) return;
    try {
      _socket.add(utf8.encode(text));
    } catch (_) {
      close();
    }
  }

  static String _oneLine(String text) => text.replaceAll(RegExp('[\r\n]'), ' ');

  static String _quote(String path) => '"${path.replaceAll('"', '""')}"';

  // ---------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------

  bool get _authorized {
    if (!_loggedIn) return false;
    if (!_server._loginRequired) return true;
    return _loginUser == _server.username && _loginPassword == _server.password;
  }

  Future<void> _execute(String line) async {
    final space = line.indexOf(' ');
    final verb = _verbOf(line);
    final arg = space < 0 ? '' : line.substring(space + 1);
    // RNFR must come right before RNTO.
    final renameFrom = _renameFrom;
    _renameFrom = null;

    if (verb.isEmpty) {
      _reply(500, 'Syntax error, command unrecognized');
      return;
    }
    if (!_authorized && !_preLogin.contains(verb)) {
      _reply(530, 'Please log in');
      return;
    }

    switch (verb) {
      case 'USER':
        _loggedIn = false;
        _loginUser = _loginPassword = null;
        _pendingUser = arg;
        _reply(331, 'Please specify the password');
      case 'PASS':
        await _pass(arg);
      case 'QUIT':
        _reply(221, 'Goodbye');
        await _closeGracefully();
      case 'AUTH' || 'PBSZ' || 'PROT':
        _reply(502, 'TLS is not supported');
      case 'SYST':
        _reply(215, 'UNIX Type: L8');
      case 'FEAT':
        _replyLines(211, const [
          'Features:',
          ' UTF8',
          ' MLST type*;size*;modify*;perm*;',
          ' MLSD',
          ' SIZE',
          ' MDTM',
          ' REST STREAM',
          ' TVFS',
          ' EPSV',
          ' EPRT',
          ' PASV',
          'End',
        ]);
      case 'OPTS':
        final option = arg.trim().toUpperCase();
        if (option.startsWith('UTF8') || option.startsWith('UTF-8')) {
          _reply(200, 'Always in UTF8 mode');
        } else if (option.startsWith('MLST')) {
          _reply(200, 'MLST OPTS type;size;modify;perm;');
        } else {
          _reply(501, 'Option not understood');
        }
      case 'NOOP':
        _reply(200, 'NOOP ok');
      case 'HELP':
        _replyLines(214, const [
          'The following commands are recognized:',
          ' ABOR ALLO APPE CDUP CWD  DELE EPRT EPSV FEAT HELP LIST MDTM MKD',
          ' MLSD MLST MODE NLST NOOP OPTS PASS PASV PORT PWD  QUIT REST RETR',
          ' RMD  RNFR RNTO SIZE STAT STOR STOU STRU SYST TYPE USER XCUP XCWD',
          ' XMKD XPWD XRMD',
          'Help OK',
        ]);
      case 'STAT':
        await _status(arg);
      case 'PWD' || 'XPWD':
        _reply(257, '${_quote(_cwd)} is the current directory');
      case 'CWD' || 'XCWD':
        await _changeDirectory(arg);
      case 'CDUP' || 'XCUP':
        await _changeDirectory('..');
      case 'TYPE':
        final type = arg.trim().toUpperCase();
        if (type.startsWith('A')) {
          _reply(200, 'Switching to ASCII mode');
        } else if (type.startsWith('I') || type.startsWith('L')) {
          _reply(200, 'Switching to Binary mode');
        } else {
          _reply(504, 'Type not supported');
        }
      case 'MODE':
        arg.trim().toUpperCase() == 'S'
            ? _reply(200, 'Mode set to S')
            : _reply(504, 'Only stream mode is supported');
      case 'STRU':
        arg.trim().toUpperCase() == 'F'
            ? _reply(200, 'Structure set to F')
            : _reply(504, 'Only file structure is supported');
      case 'ALLO':
        _reply(202, 'No storage allocation necessary');
      case 'REST':
        final offset = int.tryParse(arg.trim());
        if (offset == null || offset < 0) {
          _reply(501, 'Invalid restart position');
        } else {
          _restart = offset;
          _reply(350, 'Restarting at $offset');
        }
      case 'PASV':
        await _passive(arg, extended: false);
      case 'EPSV':
        await _passive(arg, extended: true);
      case 'PORT':
        _port(arg);
      case 'EPRT':
        _extendedPort(arg);
      case 'LIST' || 'NLST' || 'MLSD':
        await _list(verb, arg);
        // A PASV/PORT serves one transfer command, even a failed one.
        _setData(null);
      case 'MLST':
        await _listOne(arg);
      case 'SIZE':
        final stat = await _stat(_virtual(arg));
        if (stat?.type == FileSystemEntityType.file) {
          _reply(213, '${stat!.size}');
        } else {
          _reply(550, 'Could not get file size');
        }
      case 'MDTM':
        final stat = await _stat(_virtual(arg));
        if (stat == null) {
          _reply(550, 'No such file or directory');
        } else {
          _reply(213, _timestamp(stat.modified));
        }
      case 'RETR':
        await _retrieve(arg);
        _setData(null);
      case 'STOR' || 'APPE' || 'STOU':
        await _store(verb, arg);
        _setData(null);
      case 'MKD' || 'XMKD':
        await _makeDirectory(arg);
      case 'RMD' || 'XRMD':
        await _removeDirectory(arg);
      case 'DELE':
        await _delete(arg);
      case 'RNFR':
        await _renameStart(arg);
      case 'RNTO':
        await _renameTo(renameFrom, arg);
      case 'ABOR':
        // A running transfer was stopped when the command arrived.
        _setData(null);
        _reply(226, 'Abort successful');
      case 'SITE':
        _reply(502, 'SITE commands are not supported');
      default:
        _reply(502, 'Command not implemented');
    }
  }

  Future<void> _pass(String password) async {
    final user = _pendingUser;
    _pendingUser = null;
    if (user == null) {
      _loggedIn
          ? _reply(230, 'Already logged in')
          : _reply(503, 'Login with USER first');
      return;
    }
    if (_server._loginRequired &&
        (user != _server.username || password != _server.password)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (++_failedLogins >= _maxFailedLogins) {
        _reply(421, 'Too many failed login attempts');
        await _closeGracefully();
        return;
      }
      _reply(530, 'Login incorrect');
      return;
    }
    _failedLogins = 0;
    _loggedIn = true;
    _loginUser = user;
    _loginPassword = password;
    _reply(230, 'Login successful');
  }

  Future<void> _status(String arg) async {
    if (arg.trim().isEmpty) {
      _replyLines(211, [
        'Folder FTP server status:',
        ' Connected from $_peer',
        ' Logged in',
        ' TYPE: BINARY, MODE: Stream, STRUcture: File',
        _server.allowChanges
            ? ' The shared folder can be changed'
            : ' The shared folder is read-only',
        'End of status',
      ]);
      return;
    }
    final lines = await _listing('LIST', arg);
    if (lines == null) return;
    _replyLines(213, [
      'Status of ${_virtual(_withoutFlags(arg))}:',
      for (final line in lines) ' $line',
      'End of status',
    ]);
  }

  Future<void> _changeDirectory(String arg) async {
    final path = _virtual(arg);
    final native = await _resolve(path);
    if (native == null || !await FileSystemEntity.isDirectory(native)) {
      _reply(550, 'No such directory');
      return;
    }
    _cwd = path;
    _reply(250, 'Directory changed to $path');
  }

  // ---------------------------------------------------------------------
  // Data connections
  // ---------------------------------------------------------------------

  void _setData(_DataChannel? channel) {
    _data?.close();
    _data = channel;
  }

  Future<void> _passive(String arg, {required bool extended}) async {
    if (extended) {
      final option = arg.trim().toUpperCase();
      if (option == 'ALL') {
        _reply(200, 'EPSV ALL ok');
        return;
      }
      if (option.isNotEmpty && option != '1') {
        _reply(522, 'Network protocol not supported, use (1)');
        return;
      }
    }
    _setData(null);
    final _PassiveChannel channel;
    try {
      channel = await _PassiveChannel.open(_peer);
    } on SocketException {
      _reply(425, "Can't open data connection");
      return;
    }
    if (_closing) {
      channel.close();
      return;
    }
    _setData(channel);
    final port = channel.port;
    if (extended) {
      _reply(229, 'Entering Extended Passive Mode (|||$port|)');
    } else {
      final host = _passiveHost().replaceAll('.', ',');
      _reply(227, 'Entering Passive Mode ($host,${port ~/ 256},${port % 256})');
    }
  }

  /// The address this client reached us at, so passive mode works with
  /// several network interfaces.
  String _passiveHost() {
    final local = InternetAddress.tryParse(_localHost);
    if (local != null &&
        local.type == InternetAddressType.IPv4 &&
        _localHost != '0.0.0.0') {
      return _localHost;
    }
    // Dart doesn't always report which local address a connection came in
    // on: pick ours on the client's network (the most leading bits in
    // common), preferring the Wi-Fi address on ties.
    final peer = InternetAddress.tryParse(_peer);
    if (peer == null || peer.isLoopback) return '127.0.0.1';
    String? best;
    var bestBits = -1;
    for (final host in {..._server._lanHosts, ..._server._localHosts}) {
      final bits = _commonBits(host, _peer);
      if (bits > bestBits) {
        best = host;
        bestBits = bits;
      }
    }
    return best ?? '127.0.0.1';
  }

  static int _commonBits(String a, String b) {
    int? value(String ip) {
      final parts = ip.split('.').map(int.tryParse).toList();
      if (parts.length != 4 || parts.any((p) => p == null)) return null;
      return parts.fold<int>(0, (v, p) => (v << 8) | p!);
    }

    final x = value(a), y = value(b);
    if (x == null || y == null) return -1;
    final diff = x ^ y;
    var bits = 0;
    for (var mask = 0x80000000; mask != 0 && diff & mask == 0; mask >>= 1) {
      bits++;
    }
    return bits;
  }

  void _port(String arg) {
    final numbers = [
      for (final part in arg.trim().split(',')) int.tryParse(part.trim()),
    ];
    if (numbers.length != 6 ||
        numbers.any((n) => n == null || n < 0 || n > 255)) {
      _reply(501, 'Syntax error in PORT command');
      return;
    }
    _active(numbers.take(4).join('.'), numbers[4]! * 256 + numbers[5]!, 'PORT');
  }

  void _extendedPort(String arg) {
    final text = arg.trim();
    final parts = text.isEmpty ? const <String>[] : text.split(text[0]);
    if (parts.length != 5 || parts.first.isNotEmpty || parts.last.isNotEmpty) {
      _reply(501, 'Syntax error in EPRT command');
      return;
    }
    if (parts[1] != '1') {
      _reply(522, 'Network protocol not supported, use (1)');
      return;
    }
    final address = InternetAddress.tryParse(parts[2]);
    final port = int.tryParse(parts[3]);
    if (address == null ||
        address.type != InternetAddressType.IPv4 ||
        port == null ||
        port < 1 ||
        port > 65535) {
      _reply(501, 'Syntax error in EPRT command');
      return;
    }
    _active(address.address, port, 'EPRT');
  }

  void _active(String host, int port, String command) {
    // Only connect back to the client itself (no FTP bounce attacks).
    if (host != _peer || port < 1024) {
      _reply(500, 'Illegal $command command');
      return;
    }
    _setData(_ActiveChannel(host, port));
    _reply(200, '$command command successful');
  }

  /// Replies 150, opens the data connection and runs [body] over it, then
  /// replies 226 (after [onComplete]), or 425/426/451 when something fails.
  Future<void> _withData(
    String opening,
    Future<void> Function(_Transfer transfer) body, {
    void Function()? onComplete,
  }) async {
    final channel = _data;
    _data = null;
    if (channel == null) {
      _reply(425, 'Use PASV, EPSV, PORT or EPRT first');
      return;
    }
    _reply(150, opening);
    _connecting = channel;
    Socket? socket;
    try {
      socket = await channel.connect();
    } finally {
      _connecting = null;
      channel.close();
    }
    if (socket == null || _closing) {
      socket?.destroy();
      _reply(425, "Can't open data connection");
      return;
    }
    final transfer = _transfer = _Transfer(socket);
    try {
      await body(transfer);
      if (transfer.isAborted) {
        _reply(426, 'Connection closed; transfer aborted');
      } else {
        onComplete?.call();
        _reply(226, 'Transfer complete');
      }
    } catch (e) {
      e is FileSystemException && !transfer.isAborted
          ? _reply(451, 'Local error: could not read or write the file')
          : _reply(426, 'Connection closed; transfer aborted');
    } finally {
      _transfer = null;
      transfer.dispose();
    }
  }

  /// Sends [data] and closes the data connection.
  static Future<void> _send(_Transfer transfer, Stream<List<int>> data) async {
    final sent = transfer.socket.addStream(
      data.map((chunk) {
        transfer.touch();
        return chunk;
      }),
    );
    // A destroyed socket never finishes addStream, so also wait for abort.
    await Future.any<void>([sent, transfer.aborted]);
    if (transfer.isAborted) return;
    await Future.any<void>([transfer.socket.close(), transfer.aborted]);
  }

  /// Writes what arrives on the data connection to [file].
  static Future<void> _receive(
    _Transfer transfer,
    RandomAccessFile file,
  ) async {
    final buffer = BytesBuilder(copy: false);
    try {
      await for (final chunk in transfer.socket) {
        transfer.touch();
        buffer.add(chunk);
        if (buffer.length >= _writeBuffer) {
          await file.writeFrom(buffer.takeBytes());
        }
      }
    } finally {
      // Keep what arrived, even when the transfer broke off.
      if (buffer.isNotEmpty) await file.writeFrom(buffer.takeBytes());
    }
  }

  // ---------------------------------------------------------------------
  // Listings
  // ---------------------------------------------------------------------

  Future<void> _list(String verb, String arg) async {
    final lines = await _listing(verb, arg);
    if (lines == null) return;
    final bytes = utf8.encode(lines.map((line) => '$line\r\n').join());
    await _withData(
      'Opening data connection for directory listing',
      (transfer) => _send(transfer, _chunks(bytes)),
    );
  }

  /// LIST, NLST or MLSD lines for [arg], or null after replying with an
  /// error.
  Future<List<String>?> _listing(String verb, String arg) async {
    final path = _virtual(verb == 'MLSD' ? arg : _withoutFlags(arg));
    final native = await _resolve(path);
    final stat = native == null ? null : await FileStat.stat(native);
    final List<_Entry> entries;
    if (stat?.type == FileSystemEntityType.directory) {
      entries = await _entries(native!);
    } else if (stat?.type == FileSystemEntityType.file && verb != 'MLSD') {
      entries = [_Entry(p.posix.basename(path), stat!)];
    } else if (stat?.type == FileSystemEntityType.file) {
      _reply(501, 'Not a directory');
      return null;
    } else {
      _reply(550, 'No such file or directory');
      return null;
    }
    final now = DateTime.now();
    final writable = _server.allowChanges;
    return [
      for (final entry in entries)
        switch (verb) {
          'NLST' => entry.name,
          'MLSD' => '${_facts(entry, writable)} ${entry.name}',
          _ => _longLine(entry, writable, now),
        },
    ];
  }

  Future<void> _listOne(String arg) async {
    final path = _virtual(arg);
    final stat = await _stat(path);
    if (stat == null) {
      _reply(550, 'No such file or directory');
      return;
    }
    final entry = _Entry(p.posix.basename(path), stat);
    final facts = _facts(entry, _server.allowChanges, root: path == '/');
    _replyLines(250, ['Listing $path', ' $facts $path', 'End']);
  }

  Future<List<_Entry>> _entries(String dir) async {
    final only = _server._only;
    final entities = await Directory(dir)
        .list(followLinks: false)
        .handleError((Object _) {})
        .where((e) => only == null || dir != _server._root || only.contains(p.basename(e.path)))
        .toList();
    final entries = await Future.wait(
      entities.map((entity) async {
        final name = p.basename(entity.path);
        if (name.contains('\n') || name.contains('\r')) return null;
        try {
          if (entity is Link && await _server._checked(entity.path) == null) {
            return null;
          }
          final stat = await entity.stat();
          return stat.type == FileSystemEntityType.directory ||
                  stat.type == FileSystemEntityType.file
              ? _Entry(name, stat)
              : null;
        } catch (_) {
          return null;
        }
      }),
    );
    return entries.nonNulls.toList()..sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// An `ls -l` line, which Windows File Explorer and FileZilla parse.
  static String _longLine(_Entry entry, bool writable, DateTime now) {
    final mode = entry.isDirectory
        ? (writable ? 'drwxr-xr-x' : 'dr-xr-xr-x')
        : (writable ? '-rw-r--r--' : '-r--r--r--');
    final size = (entry.isDirectory ? 0 : entry.size).toString().padLeft(12);
    final m = entry.modified.toLocal();
    final recent =
        m.isAfter(now.subtract(const Duration(days: 180))) &&
        m.isBefore(now.add(const Duration(days: 1)));
    final timeOrYear = recent
        ? '${_two(m.hour)}:${_two(m.minute)}'
        : m.year.toString().padLeft(5);
    final day = m.day.toString().padLeft(2);
    return '$mode 1 ftp ftp $size ${_months[m.month - 1]} $day $timeOrYear '
        '${entry.name}';
  }

  /// RFC 3659 facts, ending in `;`.
  static String _facts(_Entry entry, bool writable, {bool root = false}) {
    final modify = _timestamp(entry.modified);
    if (entry.isDirectory) {
      final perm = 'el${writable ? (root ? 'cmp' : 'cdfmp') : ''}';
      return 'type=dir;modify=$modify;perm=$perm;';
    }
    return 'type=file;size=${entry.size};modify=$modify;'
        'perm=r${writable ? 'wadf' : ''};';
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `YYYYMMDDHHMMSS` in UTC.
  static String _timestamp(DateTime time) {
    final t = time.toUtc();
    return '${t.year.toString().padLeft(4, '0')}${_two(t.month)}'
        '${_two(t.day)}${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';
  }

  /// LIST/NLST arguments without leading options like `-la`.
  static String _withoutFlags(String arg) {
    final words = arg.split(' ');
    var i = 0;
    while (i < words.length && (words[i].isEmpty || words[i].startsWith('-'))) {
      i++;
    }
    return words.skip(i).join(' ');
  }

  static Stream<List<int>> _chunks(Uint8List bytes) async* {
    const size = 64 * 1024;
    for (var i = 0; i < bytes.length; i += size) {
      yield Uint8List.sublistView(bytes, i, math.min(i + size, bytes.length));
    }
  }

  // ---------------------------------------------------------------------
  // Files
  // ---------------------------------------------------------------------

  Future<void> _retrieve(String arg) async {
    final offset = _restart;
    _restart = 0;
    final path = _virtual(arg);
    final native = await _resolve(path);
    final stat = native == null ? null : await FileStat.stat(native);
    if (stat == null || stat.type != FileSystemEntityType.file) {
      _reply(550, 'No such file');
      return;
    }
    if (offset > stat.size) {
      _reply(554, 'Restart position beyond end of file');
      return;
    }
    await _withData(
      'Opening data connection for ${p.posix.basename(path)} '
      '(${stat.size - offset} bytes)',
      (transfer) => _send(transfer, File(native!).openRead(offset)),
    );
  }

  Future<void> _store(String verb, String arg) async {
    final offset = _restart;
    _restart = 0;
    if (!_mayChange()) return;

    final String target;
    if (verb == 'STOU') {
      final dir = await _resolve(_cwd);
      if (dir == null) {
        _reply(550, 'No such directory');
        return;
      }
      final name = arg.trim().isEmpty ? null : _safeName(p.posix.basename(arg));
      target = await _unusedPath(dir, name ?? 'upload');
    } else {
      final resolved = await _resolveNew(_virtual(arg));
      if (resolved == null) {
        _reply(553, 'File name not allowed');
        return;
      }
      target = resolved.native;
    }
    final type = await FileSystemEntity.type(target);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      _reply(550, 'Not a file');
      return;
    }
    final resume = verb == 'STOR' && offset > 0;
    if (resume &&
        (type != FileSystemEntityType.file ||
            offset > await File(target).length())) {
      _reply(554, 'Invalid restart position');
      return;
    }

    RandomAccessFile? opened;
    try {
      opened = await File(target).open(
        mode: verb == 'STOR' && !resume ? FileMode.write : FileMode.append,
      );
      if (resume) {
        await opened.truncate(offset);
        await opened.setPosition(offset);
      }
    } on FileSystemException {
      await _closeQuietly(opened);
      _reply(550, 'Cannot write this file');
      return;
    }
    final file = opened;
    var open = true;
    Future<void> closeFile() async {
      if (!open) return;
      open = false;
      await file.close();
    }

    try {
      await _withData(
        verb == 'STOU'
            ? 'FILE: ${p.basename(target)}'
            : 'Opening data connection for ${p.basename(target)}',
        (transfer) async {
          try {
            await _receive(transfer, file);
          } finally {
            await closeFile();
          }
        },
        onComplete: () => _server._received.add(target),
      );
    } finally {
      if (open) {
        open = false;
        await _closeQuietly(file);
      }
    }
  }

  static Future<void> _closeQuietly(RandomAccessFile? file) async {
    try {
      await file?.close();
    } catch (_) {}
  }

  Future<void> _makeDirectory(String arg) async {
    if (!_mayChange()) return;
    final target = await _resolveNew(_virtual(arg));
    if (target == null) {
      _reply(550, 'Cannot create this folder');
      return;
    }
    if (await FileSystemEntity.type(target.native, followLinks: false) !=
        FileSystemEntityType.notFound) {
      _reply(550, 'Already exists');
      return;
    }
    await Directory(target.native).create();
    _reply(257, '${_quote(target.path)} created');
  }

  Future<void> _removeDirectory(String arg) async {
    if (!_mayChange()) return;
    final path = _virtual(arg);
    final native = path == '/' ? null : await _resolve(path);
    if (native == null ||
        await FileSystemEntity.type(native, followLinks: false) !=
            FileSystemEntityType.directory) {
      _reply(550, 'No such directory');
      return;
    }
    if (!await Directory(native).list().isEmpty) {
      _reply(550, 'Directory not empty');
      return;
    }
    await Directory(native).delete();
    _reply(250, 'Directory removed');
  }

  Future<void> _delete(String arg) async {
    if (!_mayChange()) return;
    final path = _virtual(arg);
    final native = path == '/' ? null : await _resolve(path);
    if (native == null ||
        await FileSystemEntity.type(native) != FileSystemEntityType.file) {
      _reply(550, 'No such file');
      return;
    }
    if (await FileSystemEntity.isLink(native)) {
      await Link(native).delete();
    } else {
      await File(native).delete();
    }
    _reply(250, 'File deleted');
  }

  Future<void> _renameStart(String arg) async {
    if (!_mayChange()) return;
    final path = _virtual(arg);
    final native = path == '/' ? null : await _resolve(path);
    if (native == null) {
      _reply(550, 'No such file or directory');
      return;
    }
    _renameFrom = native;
    _reply(350, 'Ready for RNTO');
  }

  Future<void> _renameTo(String? from, String arg) async {
    if (!_mayChange()) return;
    if (from == null) {
      _reply(503, 'Send RNFR first');
      return;
    }
    final target = await _resolveNew(_virtual(arg));
    if (target == null) {
      _reply(553, 'File name not allowed');
      return;
    }
    final to = target.native;
    if (p.isWithin(from, to)) {
      _reply(550, 'Cannot move a folder into itself');
      return;
    }
    if (await FileSystemEntity.type(to, followLinks: false) !=
            FileSystemEntityType.notFound &&
        !await _same(from, to)) {
      _reply(550, 'Already exists');
      return;
    }
    if (to != from) {
      switch (await FileSystemEntity.type(from, followLinks: false)) {
        case FileSystemEntityType.link:
          await Link(from).rename(to);
        case FileSystemEntityType.directory:
          await Directory(from).rename(to);
        case FileSystemEntityType.file:
          await File(from).rename(to);
        default:
          _reply(550, 'No such file or directory');
          return;
      }
    }
    _reply(250, 'Renamed');
  }

  /// Whether [a] and [b] are the same entry, e.g. differing only in case
  /// on a case-insensitive file system.
  static Future<bool> _same(String a, String b) async {
    try {
      return await FileSystemEntity.identical(a, b);
    } catch (_) {
      return false;
    }
  }

  bool _mayChange() {
    if (_server.allowChanges) return true;
    _reply(550, 'Permission denied: this share is read-only');
    return false;
  }

  // ---------------------------------------------------------------------
  // Paths
  // ---------------------------------------------------------------------

  /// [arg] as an absolute virtual path (`/` is the shared folder); `..`
  /// never goes above `/`.
  String _virtual(String arg) {
    if (arg.isEmpty) return _cwd;
    return p.posix.normalize(arg.startsWith('/') ? arg : '$_cwd/$arg');
  }

  Future<FileStat?> _stat(String path) async {
    final native = await _resolve(path);
    if (native == null) return null;
    final stat = await FileStat.stat(native);
    return stat.type == FileSystemEntityType.directory ||
            stat.type == FileSystemEntityType.file
        ? stat
        : null;
  }

  /// The existing file or folder at virtual [path], or null when there's
  /// nothing there or it's outside the shared folder.
  Future<String?> _resolve(String path) async {
    final parts = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty) continue;
      if (!_allowedPart(part)) return null;
      parts.add(part);
    }
    return _server._checked(p.joinAll([_server._root, ...parts]));
  }

  /// Where to create virtual [path]: inside its existing parent folder,
  /// with a name the file system accepts. Null when that's not possible or
  /// an existing entry there leads outside the shared folder.
  Future<({String native, String path})?> _resolveNew(String path) async {
    if (path == '/') return null;
    final parentPath = p.posix.dirname(path);
    final parent = await _resolve(parentPath);
    final name = _safeName(p.posix.basename(path));
    if (parent == null ||
        name == null ||
        (Platform.isWindows && _windowsDevice.hasMatch(name)) ||
        !await FileSystemEntity.isDirectory(parent)) {
      return null;
    }
    final native = p.join(parent, name);
    if (await FileSystemEntity.type(native, followLinks: false) !=
            FileSystemEntityType.notFound &&
        await _server._checked(native) == null) {
      return null;
    }
    return (native: native, path: p.posix.join(parentPath, name));
  }

  static bool _allowedPart(String part) {
    if (part == '.' ||
        part == '..' ||
        part.contains(r'\') ||
        part.contains('\u0000')) {
      return false;
    }
    if (Platform.isWindows) {
      // Drive letters, alternate data streams, names Windows rewrites.
      return !_windowsForbidden.hasMatch(part) &&
          !part.endsWith('.') &&
          !part.endsWith(' ');
    }
    return true;
  }

  static final _windowsForbidden = RegExp(r'[<>:"|?*\x00-\x1f]');
  static final _windowsDevice = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$',
    caseSensitive: false,
  );

  static String _plainAddress(InternetAddress address) {
    final text = address.address;
    return text.startsWith('::ffff:') ? text.substring(7) : text;
  }
}

/// A listing entry.
class _Entry {
  _Entry(this.name, FileStat stat)
    : isDirectory = stat.type == FileSystemEntityType.directory,
      size = stat.size,
      modified = stat.modified;

  final String name;
  final bool isDirectory;
  final int size;
  final DateTime modified;
}

/// How the next transfer's data connection is made (PASV/EPSV or
/// PORT/EPRT).
abstract interface class _DataChannel {
  /// The data connection, or null if it couldn't be made in time.
  Future<Socket?> connect();

  /// Releases the channel; a connection already handed out stays open.
  void close();
}

/// Waits for the client to connect (PASV/EPSV).
class _PassiveChannel implements _DataChannel {
  _PassiveChannel._(this._listener, this._peer) {
    _listener.listen(_accept, onError: (Object _) {});
  }

  static Future<_PassiveChannel> open(String peer) async => _PassiveChannel._(
    await ServerSocket.bind(InternetAddress.anyIPv4, 0),
    peer,
  );

  final ServerSocket _listener;
  final String _peer;
  final _connection = Completer<Socket?>();
  bool _taken = false;

  int get port => _listener.port;

  void _accept(Socket socket) {
    socket.done.ignore();
    String? from;
    try {
      from = _FtpSession._plainAddress(socket.remoteAddress);
    } catch (_) {}
    // Only the client itself may connect.
    if (_connection.isCompleted || from != _peer) {
      socket.destroy();
      return;
    }
    _connection.complete(socket);
    _listener.close().ignore();
  }

  @override
  Future<Socket?> connect() {
    _taken = true;
    return _connection.future.timeout(_connectTimeout, onTimeout: () => null);
  }

  @override
  void close() {
    _listener.close().ignore();
    if (!_connection.isCompleted) {
      _connection.complete(null);
    } else if (!_taken) {
      unawaited(_connection.future.then((socket) => socket?.destroy()));
    }
  }
}

/// Connects to the client (PORT/EPRT).
class _ActiveChannel implements _DataChannel {
  _ActiveChannel(this._host, this._port);

  final String _host;
  final int _port;

  @override
  Future<Socket?> connect() async {
    try {
      final socket = await Socket.connect(
        _host,
        _port,
        timeout: _connectTimeout,
      );
      socket.done.ignore();
      return socket;
    } catch (_) {
      return null;
    }
  }

  @override
  void close() {}
}

/// A running transfer over a data connection. Aborted by ABOR, by the
/// session closing, or when nothing moves for [_stallTimeout].
class _Transfer {
  _Transfer(this.socket) {
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_sinceActivity.elapsed > _stallTimeout) abort();
    });
  }

  static const _stallTimeout = Duration(minutes: 5);

  final Socket socket;
  final _aborted = Completer<void>();
  final _sinceActivity = Stopwatch()..start();
  late final Timer _watchdog;

  bool get isAborted => _aborted.isCompleted;

  /// Completes when the transfer is aborted.
  Future<void> get aborted => _aborted.future;

  /// Notes that data moved.
  void touch() => _sinceActivity.reset();

  void abort() {
    if (!_aborted.isCompleted) _aborted.complete();
    socket.destroy();
  }

  void dispose() {
    _watchdog.cancel();
    socket.destroy();
  }
}

/// [name] without path parts or characters file systems reject, or null
/// if nothing usable is left.
String? _safeName(String name) {
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
Future<String> _unusedPath(String dir, String name) async {
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
