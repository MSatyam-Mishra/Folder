import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'ntlm.dart';
import 'smb_bytes.dart';
import 'smb_constants.dart';
import 'smb_crypto.dart';
import 'smb_security.dart';
import 'spnego.dart';

/// One TCP connection to an SMB2/3 server: framing, NEGOTIATE, credits,
/// message ids, signing and encryption, and SESSION_SETUP with NTLMv2. The
/// file operations on top are in `smb_client.dart`.

/// The server answered with an NT status that isn't success.
class SmbStatusException implements Exception {
  SmbStatusException(this.status, this.command, [this.detail]);

  final int status;
  final int command;
  final String? detail;

  @override
  String toString() => 'SmbStatusException(${NtStatus.hex(status)}, command $command${detail == null ? '' : ', $detail'})';
}

/// The connection broke, timed out or couldn't be made.
class SmbConnectionException implements Exception {
  SmbConnectionException(this.message, {this.timedOut = false, this.refused = false});

  final String message;
  final bool timedOut;
  final bool refused;

  @override
  String toString() => 'SmbConnectionException($message)';
}

/// The server did something the protocol doesn't allow, or something we
/// can't do (SMB1 only, no common cipher, a bad signature).
class SmbProtocolException implements Exception {
  SmbProtocolException(this.message, {this.kind = SmbProblem.other});

  final String message;
  final SmbProblem kind;

  @override
  String toString() => 'SmbProtocolException(${kind.name}: $message)';
}

enum SmbProblem { other, smb1Only, noCommonDialect, encryptionUnavailable, badSignature, guestBlocked }

class SmbOptions {
  const SmbOptions({
    this.dialects = SmbDialect.all,
    this.requireSigning = false,
    this.requireEncryption = false,
    this.ciphers = const [SmbCipher.aes128Gcm, SmbCipher.aes128Ccm, SmbCipher.aes256Gcm, SmbCipher.aes256Ccm],
    this.signingAlgorithms = const [SmbSigningAlgorithm.aesGmac, SmbSigningAlgorithm.aesCmac, SmbSigningAlgorithm.hmacSha256],
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30),
    this.validateNegotiate = true,
  });

  /// Offered in NEGOTIATE; the server picks the highest it has.
  final List<int> dialects;
  final bool requireSigning;

  /// Encrypts everything on SMB 3, and refuses servers without it.
  final bool requireEncryption;
  final List<int> ciphers;

  /// For 3.1.1, in order of preference. AES-GMAC comes first: here it runs
  /// about three times as fast as AES-CMAC.
  final List<int> signingAlgorithms;
  final Duration connectTimeout;
  final Duration requestTimeout;

  /// FSCTL_VALIDATE_NEGOTIATE_INFO on 3.0 and 3.0.2 (3.1.1 has pre-auth
  /// integrity instead).
  final bool validateNegotiate;
}

/// A reply, the SMB2 header included; offsets in the body are relative to
/// the header's start, as the protocol counts them.
class SmbResponse {
  SmbResponse(this.msg, {this.encrypted = false});

  final Uint8List msg;
  final bool encrypted;

  int get status => le32(msg, 8);
  int get command => le16(msg, 12);
  int get credits => le16(msg, 14);
  int get flags => le32(msg, 16);
  int get messageId => le64(msg, 24);
  int get treeId => le32(msg, 36);
  int get sessionId => le64(msg, 40);

  int u8(int bodyOffset) => msg[64 + bodyOffset];
  int u16(int bodyOffset) => le16(msg, 64 + bodyOffset);
  int u32(int bodyOffset) => le32(msg, 64 + bodyOffset);
  int u64(int bodyOffset) => le64(msg, 64 + bodyOffset);

  /// [length] bytes at [headerOffset] (counted from the header), checked.
  Uint8List slice(int headerOffset, int length) {
    if (length == 0) return Uint8List(0);
    if (headerOffset < 0 || headerOffset + length > msg.length) {
      throw SmbProtocolException('The server sent a truncated reply');
    }
    return Uint8List.sublistView(msg, headerOffset, headerOffset + length);
  }
}

/// A signed-in user on a connection, with its keys.
class SmbSession {
  SmbSession._(this.connection);

  final SmbConnection connection;
  int id = 0;
  bool isGuest = false;
  bool isAnonymous = false;
  bool signingRequired = false;
  bool encryptData = false;
  Uint8List? sessionKey;
  Uint8List? signingKey;
  Uint8List? encryptionKey;
  Uint8List? decryptionKey;
  Uint8List preauthHash = Uint8List(64);

  AesCmac? _cmac;
  final Uint8List _noncePrefix = randomBytes(4);
  int _nonceCounter = 0;

  bool get canSign => signingKey != null;
  bool get canEncrypt => encryptionKey != null && decryptionKey != null;

  void _deriveKeys(Uint8List key) {
    final c = connection;
    sessionKey = key.length > 16 ? Uint8List.sublistView(key, 0, 16) : key;
    final keys = deriveSmbKeys(key, dialect: c.dialect, cipher: c.cipher, preauthHash: preauthHash);
    signingKey = keys.signing;
    encryptionKey = keys.encryption;
    decryptionKey = keys.decryption;
  }

  Uint8List _signatureOf(Uint8List buf, int start, int end) => smbSignature(
        buf,
        start,
        end,
        dialect: connection.dialect,
        algorithm: connection.signingAlgorithm,
        key: signingKey!,
        cmac: connection.dialect >= SmbDialect.smb300 ? (_cmac ??= AesCmac(signingKey!)) : null,
      );

  /// Signs the message at [start] of [buf] in place.
  void sign(Uint8List buf, int start, int end) {
    setLe32(buf, start + 16, le32(buf, start + 16) | SmbFlags.signed);
    buf.fillRange(start + 48, start + 64, 0);
    final sig = _signatureOf(buf, start, end);
    buf.setRange(start + 48, start + 64, sig);
  }

  bool verify(Uint8List msg) {
    if (!canSign) return false;
    final got = Uint8List.fromList(Uint8List.sublistView(msg, 48, 64));
    msg.fillRange(48, 64, 0);
    final want = _signatureOf(msg, 0, msg.length);
    msg.setRange(48, 64, got);
    return bytesEqual(got, want);
  }

  /// The framed TRANSFORM_HEADER message carrying the message encrypted. The
  /// nonce is a counter plus a random part, never used twice with a key.
  Uint8List encrypt(Uint8List buf, int start, int end) {
    final gcm = SmbCipher.isGcm(connection.cipher);
    final nonce = Uint8List(gcm ? 12 : 11);
    setLe64(nonce, 0, _nonceCounter++);
    nonce.setRange(8, nonce.length, _noncePrefix);
    return smbEncrypt(buf, start, end, cipher: connection.cipher, key: encryptionKey!, nonce: nonce, sessionId: id);
  }

  /// The plain SMB2 message(s) inside the TRANSFORM_HEADER [frame].
  Uint8List decrypt(Uint8List frame) {
    if (!canEncrypt) throw SmbProtocolException('The server sent encrypted data without agreeing on a cipher');
    final plain = smbDecrypt(frame, cipher: connection.cipher, key: decryptionKey!);
    if (plain == null) {
      throw SmbProtocolException('An encrypted message from the server failed its check', kind: SmbProblem.badSignature);
    }
    return plain;
  }
}

/// A connected share.
class SmbTree {
  SmbTree(this.session, this.id, this.share, this.shareType, this.shareFlags, this.maximalAccess);

  final SmbSession session;
  final int id;
  final String share;

  /// 1 disk, 2 pipe, 3 printer.
  final int shareType;
  final int shareFlags;
  final int maximalAccess;

  bool get encrypt => (shareFlags & SmbShareFlags.encryptData) != 0;
  bool get isDfs => (shareFlags & SmbShareFlags.dfs) != 0;
}

class _Pending {
  _Pending(this.completer, this.command, this.session, this.encrypted);

  final Completer<SmbResponse> completer;
  final int command;
  final SmbSession? session;

  /// Sent encrypted, so the reply must be too.
  final bool encrypted;
  Timer? timer;
  int asyncId = 0;
}

class SmbConnection {
  SmbConnection._(this._socket, this.host, this.port, this.options) {
    _sub = _socket.listen(_onData, onError: _onError, onDone: _onDone, cancelOnError: true);
  }

  final Socket _socket;
  final String host;
  final int port;
  final SmbOptions options;
  late final StreamSubscription<Uint8List> _sub;

  final Uint8List clientGuid = randomBytes(16);
  int dialect = 0;
  int serverSecurityMode = 0;
  int serverCapabilities = 0;
  int maxTransactSize = 65536;
  int maxReadSize = 65536;
  int maxWriteSize = 65536;
  Uint8List serverGuid = Uint8List(16);
  Uint8List gssToken = Uint8List(0);
  int cipher = 0;
  int signingAlgorithm = SmbSigningAlgorithm.hmacSha256;
  Uint8List preauthHash = Uint8List(64);

  int _nextMessageId = 0;
  int _credits = 1;
  final Queue<(int, Completer<void>)> _creditWaiters = Queue();
  final Map<int, _Pending> _pending = {};
  final Map<int, SmbSession> _sessions = {};
  bool _closed = false;
  Object? _closeReason;
  final Completer<void> _done = Completer<void>();

  bool get isClosed => _closed;

  /// Completes when the connection ends, for whatever reason.
  Future<void> get done => _done.future;

  bool get supportsMultiCredit => dialect > SmbDialect.smb202 && (serverCapabilities & SmbCaps.largeMtu) != 0;

  /// How many credits are in hand right now (for tests and tuning).
  int get credits => _credits;

  /// Opens the TCP connection (and a NetBIOS session on port 139) to
  /// [address], or to [host] when there's none. [host] is what the server is
  /// called in share paths and the sign-in.
  static Future<SmbConnection> open(
    String host,
    int port, {
    InternetAddress? address,
    SmbOptions options = const SmbOptions(),
  }) async {
    Socket socket;
    try {
      socket = await Socket.connect(address ?? host, port, timeout: options.connectTimeout);
    } on SocketException catch (e) {
      final refused = e.osError?.errorCode == 111 || e.osError?.errorCode == 10061 || e.osError?.errorCode == 61;
      final timedOut = e.message.contains('timed out') || e.osError?.errorCode == 110 || e.osError?.errorCode == 10060;
      throw SmbConnectionException(e.osError?.message ?? e.message, refused: refused, timedOut: timedOut);
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    final c = SmbConnection._(socket, host, port, options);
    if (port == 139) {
      try {
        await c._netbiosSessionRequest();
      } catch (_) {
        c.destroy();
        rethrow;
      }
    }
    return c;
  }

  Completer<bool>? _netbiosWait;

  Future<void> _netbiosSessionRequest() async {
    // NetBIOS over TCP needs a session request first; "*SMBSERVER" is
    // accepted by Windows and Samba when the real name isn't known.
    final isIp = InternetAddress.tryParse(host) != null;
    final called = isIp ? '*SMBSERVER' : host.split('.').first.toUpperCase();
    final body = concatBytes([netbiosEncodeName(called, 0x20), netbiosEncodeName('FOLDERS', 0x00)]);
    final wait = _netbiosWait = Completer<bool>();
    _socket.add(concatBytes([
      [0x81, 0, body.length >> 8, body.length & 0xff],
      body,
    ]));
    final ok = await wait.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
    _netbiosWait = null;
    if (!ok) throw SmbConnectionException('The server refused the NetBIOS session');
  }


  // ------------------------------------------------------------------ receiving

  final Queue<Uint8List> _rx = Queue();
  int _rxOffset = 0;
  int _rxLen = 0;
  int _need = -1;
  int _frameType = 0;

  void _onData(Uint8List chunk) {
    _rx.add(chunk);
    _rxLen += chunk.length;
    while (!_closed) {
      if (_need < 0) {
        if (_rxLen < 4) return;
        final h = _take(4);
        _frameType = h[0];
        // Direct TCP gives the length 24 bits; NetBIOS packets 17.
        _need = _frameType == 0 ? (h[1] << 16) | (h[2] << 8) | h[3] : ((h[1] & 1) << 16) | (h[2] << 8) | h[3];
      }
      if (_rxLen < _need) return;
      final frame = _need == 0 ? Uint8List(0) : _take(_need);
      _need = -1;
      if (_frameType != 0) {
        // NetBIOS session packets: 0x82 yes, 0x83 no, 0x85 keep-alive.
        if (_frameType == 0x82 || _frameType == 0x83) {
          final w = _netbiosWait;
          if (w != null && !w.isCompleted) w.complete(_frameType == 0x82);
        }
        continue;
      }
      try {
        _handleFrame(frame);
      } catch (e) {
        _fail(e is SmbProtocolException ? e : SmbProtocolException('Bad reply from the server: $e'));
        return;
      }
    }
  }

  Uint8List _take(int n) {
    final first = _rx.first;
    if (_rxOffset == 0 && first.length == n) {
      _rx.removeFirst();
      _rxLen -= n;
      return first;
    }
    if (first.length - _rxOffset >= n) {
      final out = Uint8List.sublistView(first, _rxOffset, _rxOffset + n);
      _rxOffset += n;
      if (_rxOffset == first.length) {
        _rx.removeFirst();
        _rxOffset = 0;
      }
      _rxLen -= n;
      return out;
    }
    final out = Uint8List(n);
    var o = 0;
    while (o < n) {
      final c = _rx.first;
      final k = min(c.length - _rxOffset, n - o);
      out.setRange(o, o + k, c, _rxOffset);
      o += k;
      _rxOffset += k;
      if (_rxOffset == c.length) {
        _rx.removeFirst();
        _rxOffset = 0;
      }
    }
    _rxLen -= n;
    return out;
  }

  void _handleFrame(Uint8List frame) {
    if (frame.length < 4) throw SmbProtocolException('Short message');
    if (frame[0] == 0xfd && frame[1] == 0x53 && frame[2] == 0x4d && frame[3] == 0x42) {
      if (frame.length < 52) throw SmbProtocolException('Short encrypted message');
      final session = _sessions[le64(frame, 44)];
      if (session == null) throw SmbProtocolException('Encrypted message for an unknown session');
      _handleSmb2(session.decrypt(frame), encrypted: true);
    } else if (frame[0] == 0xfe && frame[1] == 0x53 && frame[2] == 0x4d && frame[3] == 0x42) {
      _handleSmb2(frame, encrypted: false);
    } else if (frame[0] == 0xff && frame[1] == 0x53 && frame[2] == 0x4d && frame[3] == 0x42) {
      throw SmbProtocolException('The server speaks only SMB 1', kind: SmbProblem.smb1Only);
    } else if (frame[0] == 0xfc && frame[1] == 0x53) {
      throw SmbProtocolException('The server sent compressed data, which wasn\'t asked for');
    } else {
      throw SmbProtocolException('Not an SMB message');
    }
  }

  void _handleSmb2(Uint8List buf, {required bool encrypted}) {
    var off = 0;
    while (true) {
      if (off + 64 > buf.length) throw SmbProtocolException('Short SMB2 header');
      final next = le32(buf, off + 20);
      final end = next == 0 ? buf.length : off + next;
      if (end > buf.length || end < off + 64) throw SmbProtocolException('Bad compound reply');
      // Copy out of a compound so that signature checks can work in place.
      final msg = off == 0 && end == buf.length ? buf : Uint8List.fromList(Uint8List.sublistView(buf, off, end));
      _handleMessage(msg, encrypted);
      if (next == 0) break;
      off = end;
    }
  }

  void _handleMessage(Uint8List msg, bool encrypted) {
    final mid = le64(msg, 24);
    final status = le32(msg, 8);
    final flags = le32(msg, 16);
    final command = le16(msg, 12);
    _grant(le16(msg, 14));
    if (mid == -1) return; // oplock or lease break: we never ask for either
    final p = _pending[mid];
    if (p == null) return; // a late reply to something given up on
    if (status == NtStatus.pending && (flags & SmbFlags.asyncCommand) != 0) {
      p.asyncId = le64(msg, 32);
      p.timer?.cancel();
      p.timer = Timer(const Duration(minutes: 10), () => _timeout(mid));
      return;
    }
    _pending.remove(mid);
    p.timer?.cancel();
    final s = p.session;
    if (!encrypted && s != null && command != SmbCommand.sessionSetup) {
      final signed = (flags & SmbFlags.signed) != 0;
      if (signed && s.canSign) {
        if (!s.verify(msg)) {
          final e = SmbProtocolException('A reply from the server had a wrong signature', kind: SmbProblem.badSignature);
          p.completer.completeError(e);
          _fail(e);
          return;
        }
      } else if (_isSuccessLike(status) && (p.encrypted || (!signed && s.signingRequired))) {
        p.completer.completeError(SmbProtocolException(
          p.encrypted ? 'A reply from the server wasn\'t encrypted' : 'A reply from the server wasn\'t signed',
          kind: SmbProblem.badSignature,
        ));
        return;
      }
    }
    p.completer.complete(SmbResponse(msg, encrypted: encrypted));
  }

  static bool _isSuccessLike(int status) =>
      status == NtStatus.success || status == NtStatus.bufferOverflow || status == NtStatus.moreProcessingRequired;

  void _onError(Object error) => _fail(SmbConnectionException('The connection broke: $error'));

  void _onDone() => _fail(SmbConnectionException('The server closed the connection'));

  void _timeout(int mid) {
    if (!_pending.containsKey(mid)) return;
    _fail(SmbConnectionException('The server stopped answering', timedOut: true));
  }

  void _fail(Object reason) {
    if (_closed) return;
    _closed = true;
    _closeReason = reason;
    for (final p in _pending.values) {
      p.timer?.cancel();
      if (!p.completer.isCompleted) p.completer.completeError(reason);
    }
    _pending.clear();
    for (final (_, c) in _creditWaiters) {
      if (!c.isCompleted) c.completeError(reason);
    }
    _creditWaiters.clear();
    final nb = _netbiosWait;
    if (nb != null && !nb.isCompleted) nb.complete(false);
    _sub.cancel();
    _socket.destroy();
    if (!_done.isCompleted) _done.complete();
  }

  /// Ends the connection without logging off.
  void destroy() => _fail(SmbConnectionException('Closed'));

  // ------------------------------------------------------------------ credits

  void _grant(int n) {
    _credits += n;
    while (_creditWaiters.isNotEmpty && _credits >= _creditWaiters.first.$1) {
      final (need, c) = _creditWaiters.removeFirst();
      _credits -= need;
      c.complete();
    }
  }

  Future<void> _acquire(int n) {
    if (_creditWaiters.isEmpty && _credits >= n) {
      _credits -= n;
      return Future.value();
    }
    final c = Completer<void>();
    _creditWaiters.add((n, c));
    if (_pending.isEmpty && _credits >= 1 && !_echoing) {
      // Nothing out there will bring credits back: ask for some.
      _echoing = true;
      unawaited(_echoForCredits().whenComplete(() => _echoing = false));
    }
    return c.future;
  }

  bool _echoing = false;

  Future<void> _echoForCredits() async {
    _credits -= 1;
    try {
      final w = newRequest(4)
        ..u16(4)
        ..u16(0);
      await _sendPrepared(SmbCommand.echo, w, 1, null, 0, false, false, null, null);
    } catch (_) {}
  }

  /// The CreditCharge of a request of [bytes] (the larger of what's sent and
  /// what may come back); 0 where the dialect has no multi-credit requests.
  int creditCharge(int bytes) => supportsMultiCredit ? max(1, (bytes + 65535) ~/ 65536) : 0;

  /// The largest read or write one request may carry, within what the server
  /// allows and [preferred].
  int ioSize(int serverMax, int preferred) {
    if (!supportsMultiCredit) return min(serverMax, 65536);
    return max(4096, min(serverMax, preferred));
  }

  // ------------------------------------------------------------------ sending

  /// A writer with room for the NetBIOS length and the SMB2 header; the
  /// request body goes after them.
  static ByteWriter newRequest([int bodyCapacity = 128]) => ByteWriter(68 + bodyCapacity)..zeros(68);

  /// Sends the request whose body was written to [w] (after [newRequest]).
  ///
  /// [size] is the larger of the payload sent and the reply expected, for the
  /// credit charge. Requests are signed when the session requires it or
  /// [forceSign], and encrypted when the session or [tree] needs it.
  Future<SmbResponse> send(
    int command,
    ByteWriter w, {
    SmbSession? session,
    SmbTree? tree,
    int size = 0,
    bool forceSign = false,
    Duration? timeout,
    void Function(Uint8List message)? onWire,
  }) async {
    if (_closed) throw _closeReason ?? SmbConnectionException('Not connected');
    final charge = creditCharge(size);
    final cost = max(1, charge);
    await _acquire(cost);
    final encrypt = session != null && session.canEncrypt && (session.encryptData || (tree?.encrypt ?? false));
    final sign = !encrypt && session != null && session.canSign && (session.signingRequired || forceSign);
    return _sendPrepared(command, w, cost, session, tree?.id ?? 0, encrypt, sign, timeout, onWire, charge: charge);
  }

  Future<SmbResponse> _sendPrepared(
    int command,
    ByteWriter w,
    int cost,
    SmbSession? session,
    int treeId,
    bool encrypt,
    bool sign,
    Duration? timeout,
    void Function(Uint8List message)? onWire, {
    int charge = 0,
  }) {
    if (_closed) return Future.error(_closeReason ?? SmbConnectionException('Not connected'));
    final mid = _nextMessageId;
    _nextMessageId += cost;
    final buf = w.toBytes();
    final len = buf.length - 4;
    buf[0] = 0;
    buf[1] = (len >> 16) & 0xff;
    buf[2] = (len >> 8) & 0xff;
    buf[3] = len & 0xff;
    const h = 4;
    buf.setAll(h, const [0xfe, 0x53, 0x4d, 0x42]);
    setLe16(buf, h + 4, 64);
    setLe16(buf, h + 6, charge);
    setLe16(buf, h + 12, command);
    final int want = _credits < 512 ? cost + min(256, 512 - _credits) : cost;
    setLe16(buf, h + 14, min(want, 8192));
    setLe32(buf, h + 16, 0);
    setLe64(buf, h + 24, mid);
    setLe32(buf, h + 32, 0xfeff);
    setLe32(buf, h + 36, treeId);
    setLe64(buf, h + 40, session?.id ?? 0);
    if (sign) session!.sign(buf, h, buf.length);
    onWire?.call(Uint8List.sublistView(buf, h));
    final p = _Pending(Completer<SmbResponse>(), command, session, encrypt);
    _pending[mid] = p;
    p.timer = Timer(timeout ?? options.requestTimeout, () => _timeout(mid));
    try {
      _socket.add(encrypt ? session!.encrypt(buf, h, buf.length) : buf);
    } catch (e) {
      _fail(SmbConnectionException('Couldn\'t send: $e'));
    }
    return p.completer.future;
  }

  // ------------------------------------------------------------------ negotiate

  int get _clientCapabilities =>
      options.dialects.any((d) => d >= SmbDialect.smb300) ? (SmbCaps.largeMtu | SmbCaps.encryption) : SmbCaps.largeMtu;

  int get _clientSecurityMode =>
      SmbSecurityMode.signingEnabled | (options.requireSigning ? SmbSecurityMode.signingRequired : 0);

  Future<void> negotiate() async {
    final dialects = options.dialects;
    final has311 = dialects.contains(SmbDialect.smb311);
    final w = newRequest(256);
    const base = 4; // the header starts here; offsets count from it
    w
      ..u16(36)
      ..u16(dialects.length)
      ..u16(_clientSecurityMode)
      ..u16(0)
      ..u32(_clientCapabilities)
      ..bytes(clientGuid);
    final ctxOffsetAt = w.length;
    if (has311) {
      w
        ..u32(0)
        ..u16(0)
        ..u16(0);
    } else {
      w.u64(0);
    }
    for (final d in dialects) {
      w.u16(d);
    }
    if (has311) {
      w.align(8, from: base);
      w.setU32(ctxOffsetAt, w.length - base);
      var count = 0;
      void ctx(int type, Uint8List data) {
        w.align(8, from: base);
        w
          ..u16(type)
          ..u16(data.length)
          ..u32(0)
          ..bytes(data);
        count++;
      }

      final preauth = ByteWriter()
        ..u16(1)
        ..u16(32)
        ..u16(1)
        ..bytes(randomBytes(32));
      ctx(1, preauth.toBytes());
      if (options.ciphers.isNotEmpty) {
        final c = ByteWriter()..u16(options.ciphers.length);
        for (final x in options.ciphers) {
          c.u16(x);
        }
        ctx(2, c.toBytes());
      }
      final s = ByteWriter()..u16(options.signingAlgorithms.length);
      for (final x in options.signingAlgorithms) {
        s.u16(x);
      }
      ctx(8, s.toBytes());
      w.setU16(ctxOffsetAt + 4, count);
    }
    Uint8List? sent;
    final r = await send(SmbCommand.negotiate, w, onWire: (m) => sent = Uint8List.fromList(m));
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.negotiate);
    serverSecurityMode = r.u16(2);
    dialect = r.u16(4);
    final ctxCount = r.u16(6);
    serverGuid = Uint8List.fromList(r.slice(64 + 8, 16));
    serverCapabilities = r.u32(24);
    maxTransactSize = r.u32(28);
    maxReadSize = r.u32(32);
    maxWriteSize = r.u32(36);
    gssToken = Uint8List.fromList(r.slice(r.u16(56), r.u16(58)));
    if (!dialects.contains(dialect)) {
      throw SmbProtocolException(
        'The server chose SMB ${SmbDialect.name(dialect)}, which wasn\'t offered',
        kind: SmbProblem.noCommonDialect,
      );
    }
    if (dialect >= SmbDialect.smb300) {
      signingAlgorithm = SmbSigningAlgorithm.aesCmac;
      if (dialect < SmbDialect.smb311 &&
          (serverCapabilities & SmbCaps.encryption) != 0 &&
          options.ciphers.contains(SmbCipher.aes128Ccm)) {
        cipher = SmbCipher.aes128Ccm;
      }
    }
    if (dialect == SmbDialect.smb311) {
      preauthHash = sha512(concatBytes([Uint8List(64), sent!]));
      preauthHash = sha512(concatBytes([preauthHash, r.msg]));
      var off = r.u32(60);
      for (var i = 0; i < ctxCount; i++) {
        off = (off + 7) & ~7;
        if (off + 8 > r.msg.length) break;
        final type = le16(r.msg, off);
        final len = le16(r.msg, off + 2);
        final data = r.slice(off + 8, len);
        if (type == 2 && len >= 4) {
          cipher = le16(data, 2);
          if (!options.ciphers.contains(cipher)) cipher = 0;
        } else if (type == 8 && len >= 4) {
          final alg = le16(data, 2);
          signingAlgorithm = options.signingAlgorithms.contains(alg) ? alg : SmbSigningAlgorithm.aesCmac;
        } else if (type == 1 && len >= 6) {
          if (le16(data, 4) != 1) throw SmbProtocolException('The server wants a pre-auth hash other than SHA-512');
        }
        off += 8 + len;
      }
    }
  }

  // ------------------------------------------------------------------ sessions

  /// Signs in. An empty [user] (and password) signs in anonymously.
  Future<SmbSession> sessionSetup({
    required String user,
    required String password,
    String domain = '',
    String workstation = '',
  }) async {
    final session = SmbSession._(this);
    if (dialect == SmbDialect.smb311) session.preauthHash = Uint8List.fromList(preauthHash);
    final ntlm = NtlmClient(user: user, password: password, domain: domain, workstation: workstation, spn: 'cifs/$host');
    final hint = gssToken.isEmpty ? null : _tryParse(gssToken);
    if (hint != null && hint.mechTypes.isNotEmpty && !hint.offersNtlm) {
      throw SmbProtocolException('The server doesn\'t offer NTLM sign-in (Kerberos only)');
    }

    void hash(Uint8List m) {
      if (dialect == SmbDialect.smb311) session.preauthHash = sha512(concatBytes([session.preauthHash, m]));
    }

    var r = await _sessionSetupStep(session, spnegoInit(ntlm.negotiate()), hash);
    if (r.status != NtStatus.moreProcessingRequired) {
      throw SmbStatusException(r.status, SmbCommand.sessionSetup);
    }
    hash(r.msg);
    session.id = r.sessionId;
    _sessions[session.id] = session;
    final token = parseSpnego(r.slice(r.u16(4), r.u16(6)));
    if (token.negState == 2 || token.responseToken == null) {
      _sessions.remove(session.id);
      throw SmbStatusException(NtStatus.logonFailure, SmbCommand.sessionSetup, 'SPNEGO rejected');
    }
    final result = ntlm.authenticate(token.responseToken!);
    final mic = ntlm.sentMic ? ntlm.sign(ntlmMechTypeList) : null;
    r = await _sessionSetupStep(session, spnegoResponse(result.message, mechListMic: mic), hash);
    if (r.status != NtStatus.success) {
      _sessions.remove(session.id);
      throw SmbStatusException(r.status, SmbCommand.sessionSetup);
    }
    final flags = r.u16(2);
    session.isGuest = (flags & SmbSessionFlags.isGuest) != 0;
    session.isAnonymous = (flags & SmbSessionFlags.isNull) != 0 || result.anonymous;
    if (!session.isGuest && !session.isAnonymous && result.sessionKey.isNotEmpty) {
      session._deriveKeys(result.sessionKey);
      session.signingRequired =
          (serverSecurityMode & SmbSecurityMode.signingRequired) != 0 || options.requireSigning;
      if ((r.flags & SmbFlags.signed) != 0 && !session.verify(r.msg)) {
        _sessions.remove(session.id);
        throw SmbProtocolException('The server\'s signature didn\'t match', kind: SmbProblem.badSignature);
      }
    }
    if (options.requireEncryption && dialect < SmbDialect.smb300) {
      _sessions.remove(session.id);
      throw SmbProtocolException(
        'The server speaks only SMB ${SmbDialect.name(dialect)}, without encryption',
        kind: SmbProblem.encryptionUnavailable,
      );
    }
    if ((flags & SmbSessionFlags.encryptData) != 0 || options.requireEncryption) {
      if (!session.canEncrypt) {
        _sessions.remove(session.id);
        throw SmbProtocolException(
          session.isGuest || session.isAnonymous ? 'Encryption needs a signed-in user' : 'No cipher in common',
          kind: SmbProblem.encryptionUnavailable,
        );
      }
      session.encryptData = true;
    }
    return session;
  }

  SpnegoToken? _tryParse(Uint8List t) {
    try {
      return parseSpnego(t);
    } catch (_) {
      return null;
    }
  }

  Future<SmbResponse> _sessionSetupStep(SmbSession s, Uint8List token, void Function(Uint8List) hash) {
    final w = newRequest(24 + token.length)
      ..u16(25)
      ..u8(0)
      ..u8(_clientSecurityMode)
      ..u32(0)
      ..u32(0)
      ..u16(64 + 24)
      ..u16(token.length)
      ..u64(0)
      ..bytes(token);
    return send(SmbCommand.sessionSetup, w, session: s, onWire: hash);
  }

  Future<void> logoff(SmbSession s) async {
    final w = newRequest(4)
      ..u16(4)
      ..u16(0);
    try {
      await send(SmbCommand.logoff, w, session: s, timeout: const Duration(seconds: 5));
    } finally {
      _sessions.remove(s.id);
    }
  }

  Future<SmbTree> treeConnect(SmbSession s, String share) async {
    final path = utf16le('\\\\$host\\$share');
    final w = newRequest(8 + path.length)
      ..u16(9)
      ..u16(0)
      ..u16(64 + 8)
      ..u16(path.length)
      ..bytes(path);
    final r = await send(SmbCommand.treeConnect, w, session: s, forceSign: dialect == SmbDialect.smb311);
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.treeConnect, share);
    final tree = SmbTree(s, r.treeId, share, r.u8(2), r.u32(4), r.u32(12));
    if (tree.encrypt && !s.canEncrypt) {
      throw SmbProtocolException('No cipher in common', kind: SmbProblem.encryptionUnavailable);
    }
    if (options.validateNegotiate &&
        !_validated &&
        (dialect == SmbDialect.smb300 || dialect == SmbDialect.smb302) &&
        s.canSign &&
        !s.encryptData &&
        !tree.encrypt) {
      _validated = true;
      await _validateNegotiate(tree);
    }
    return tree;
  }

  bool _validated = false;

  Future<void> _validateNegotiate(SmbTree tree) async {
    final dialects = options.dialects;
    final input = ByteWriter()
      ..u32(_clientCapabilities)
      ..bytes(clientGuid)
      ..u16(_clientSecurityMode)
      ..u16(dialects.length);
    for (final d in dialects) {
      input.u16(d);
    }
    final r = await ioctl(
      tree,
      Fsctl.validateNegotiateInfo,
      input.toBytes(),
      fileId: allOnesFileId,
      maxOutput: 24,
      forceSign: true,
    );
    if (r.status != NtStatus.success) return; // servers that don't do it answer with an error
    final out = ioctlOutput(r);
    if (out.length < 24) return;
    final ok = le32(out, 0) == serverCapabilities &&
        bytesEqual(out.sublist(4, 20), serverGuid) &&
        le16(out, 20) == serverSecurityMode &&
        le16(out, 22) == dialect;
    if (!ok) {
      final e = SmbProtocolException(
        'The server\'s answer didn\'t match what it said before; something may be tampering with the connection',
        kind: SmbProblem.badSignature,
      );
      _fail(e);
      throw e;
    }
  }

  Future<void> treeDisconnect(SmbTree t) async {
    final w = newRequest(4)
      ..u16(4)
      ..u16(0);
    await send(SmbCommand.treeDisconnect, w, session: t.session, tree: t, timeout: const Duration(seconds: 5));
  }

  static final Uint8List allOnesFileId = Uint8List(16)..fillRange(0, 16, 0xff);

  /// An IOCTL/FSCTL; returns the reply whatever its status (callers check).
  Future<SmbResponse> ioctl(
    SmbTree tree,
    int code,
    Uint8List input, {
    required Uint8List fileId,
    int maxOutput = 65536,
    bool forceSign = false,
  }) {
    final w = newRequest(56 + input.length)
      ..u16(57)
      ..u16(0)
      ..u32(code)
      ..bytes(fileId)
      ..u32(input.isEmpty ? 0 : 64 + 56)
      ..u32(input.length)
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u32(maxOutput)
      ..u32(1) // SMB2_0_IOCTL_IS_FSCTL
      ..u32(0)
      ..bytes(input);
    if (input.isEmpty) w.u8(0);
    return send(
      SmbCommand.ioctl,
      w,
      session: tree.session,
      tree: tree,
      size: max(input.length, maxOutput),
      forceSign: forceSign,
    );
  }

  static Uint8List ioctlOutput(SmbResponse r) => r.slice(r.u32(32), r.u32(36));

  /// Logs off every session and closes the socket.
  Future<void> close() async {
    if (_closed) return;
    for (final s in _sessions.values.toList()) {
      try {
        await logoff(s);
      } catch (_) {}
    }
    destroy();
  }
}

/// A NetBIOS name, first-level encoded (RFC 1001), as a length-prefixed label.
Uint8List netbiosEncodeName(String name, int suffix) {
  final wildcard = name == '*';
  final n = name.length > 15 ? name.substring(0, 15) : name;
  final raw = Uint8List(16)..fillRange(0, 16, wildcard ? 0 : 0x20);
  final bytes = latin1.encode(n.toUpperCase());
  raw.setRange(0, bytes.length, bytes);
  raw[15] = wildcard ? 0 : suffix;
  final out = Uint8List(34);
  out[0] = 32;
  for (var i = 0; i < 16; i++) {
    out[1 + 2 * i] = 0x41 + (raw[i] >> 4);
    out[2 + 2 * i] = 0x41 + (raw[i] & 0xf);
  }
  return out;
}
