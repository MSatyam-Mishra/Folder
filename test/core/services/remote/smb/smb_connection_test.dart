import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/smb/smb_bytes.dart';
import 'package:folders/core/services/remote/smb/smb_connection.dart';
import 'package:folders/core/services/remote/smb/smb_constants.dart';
import 'package:folders/core/services/remote/smb/smb_crypto.dart';

/// The connection layer against a scripted server on loopback: frames split
/// into single bytes, an interim STATUS_PENDING, a compound reply, an SMB1
/// answer, a dropped connection and a silent server.
class _FakeServer {
  late ServerSocket _server;
  Socket? _client;
  final _frames = StreamController<Uint8List>();
  late final StreamIterator<Uint8List> frames = StreamIterator(_frames.stream);
  final List<int> _buf = [];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((s) {
      _client = s;
      s.listen((data) {
        _buf.addAll(data);
        while (_buf.length >= 4) {
          final len = (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
          if (_buf.length < 4 + len) break;
          _frames.add(Uint8List.fromList(_buf.sublist(4, 4 + len)));
          _buf.removeRange(0, 4 + len);
        }
      }, onError: (_) {}, onDone: () {});
    });
  }

  Future<Uint8List> next() async {
    if (!await frames.moveNext()) throw StateError('no more frames');
    return frames.current;
  }

  void send(List<int> frame) => _client!.add(frame);

  Future<void> sendByteByByte(List<int> frame) async {
    for (final b in frame) {
      _client!.add([b]);
      await _client!.flush();
    }
  }

  Future<void> dropClient() async => _client?.destroy();

  Future<void> close() async {
    _client?.destroy();
    await _server.close();
  }
}

Uint8List _reply(int command, int mid, List<int> body, {int status = 0, int credits = 32, int flags = 1, int asyncId = 0}) {
  final w = ByteWriter()
    ..bytes([0xfe, 0x53, 0x4d, 0x42])
    ..u16(64)
    ..u16(0)
    ..u32(status)
    ..u16(command)
    ..u16(credits)
    ..u32(flags)
    ..u32(0)
    ..u64(mid);
  if ((flags & SmbFlags.asyncCommand) != 0) {
    w.u64(asyncId);
  } else {
    w
      ..u32(0)
      ..u32(0);
  }
  w
    ..u64(0)
    ..zeros(16)
    ..bytes(body);
  return Uint8List.fromList(w.toBytes());
}

Uint8List _frame(List<Uint8List> msgs) {
  // Compound: each but the last padded to 8 bytes, NextCommand set.
  final parts = <Uint8List>[];
  for (var i = 0; i < msgs.length; i++) {
    var m = msgs[i];
    if (i < msgs.length - 1) {
      final padded = (m.length + 7) & ~7;
      m = Uint8List(padded)..setRange(0, m.length, m);
      setLe32(m, 20, padded);
    }
    parts.add(m);
  }
  final body = concatBytes(parts);
  return concatBytes([
    [0, body.length >> 16, (body.length >> 8) & 0xff, body.length & 0xff],
    body,
  ]);
}

Uint8List _negotiateReply(int mid) {
  final ctx = ByteWriter();
  void add(int type, List<int> data) {
    ctx.align(8);
    ctx
      ..u16(type)
      ..u16(data.length)
      ..u32(0)
      ..bytes(data);
  }

  add(1, [1, 0, 32, 0, 1, 0, ...List.filled(32, 9)]);
  add(2, [1, 0, 2, 0]); // AES-128-GCM
  add(8, [1, 0, 2, 0]); // AES-GMAC
  final sec = [0x60, 0x00];
  final w = ByteWriter()
    ..u16(65)
    ..u16(1)
    ..u16(SmbDialect.smb311)
    ..u16(3)
    ..bytes(List.filled(16, 0x47))
    ..u32(SmbCaps.largeMtu | SmbCaps.encryption)
    ..u32(8 << 20)
    ..u32(4 << 20)
    ..u32(2 << 20)
    ..u64(0)
    ..u64(0)
    ..u16(128)
    ..u16(sec.length)
    ..u32(0) // context offset, patched
    ..bytes(sec);
  w.align(8);
  final ctxOffset = 64 + w.length;
  w.setU32(60, ctxOffset);
  w.bytes(ctx.toBytes());
  return _reply(SmbCommand.negotiate, mid, w.toBytes());
}

void main() {
  late _FakeServer server;

  setUp(() async {
    server = _FakeServer();
    await server.start();
  });

  tearDown(() => server.close());

  Future<SmbConnection> negotiated({SmbOptions options = const SmbOptions()}) async {
    final c = await SmbConnection.open('127.0.0.1', server.port, options: options);
    final f = c.negotiate();
    final req = await server.next();
    server.send(_frame([_negotiateReply(le64(req, 24))]));
    await f;
    return c;
  }

  test('NEGOTIATE 3.1.1 read a byte at a time: contexts and pre-auth hash', () async {
    final c = await SmbConnection.open('127.0.0.1', server.port);
    final f = c.negotiate();
    final req = await server.next();
    expect(req.sublist(0, 4), [0xfe, 0x53, 0x4d, 0x42]);
    expect(le16(req, 12), SmbCommand.negotiate);
    expect(le16(req, 64 + 2), 5, reason: 'five dialects offered');
    final reply = _negotiateReply(le64(req, 24));
    await server.sendByteByByte(_frame([reply]));
    await f;
    expect(c.dialect, SmbDialect.smb311);
    expect(c.cipher, SmbCipher.aes128Gcm);
    expect(c.signingAlgorithm, SmbSigningAlgorithm.aesGmac);
    expect(c.maxReadSize, 4 << 20);
    expect(c.maxWriteSize, 2 << 20);
    expect(c.supportsMultiCredit, isTrue);
    expect(c.creditCharge(1 << 20), 16);
    final want = sha512(concatBytes([sha512(concatBytes([Uint8List(64), req])), reply]));
    expect(c.preauthHash, want);
    c.destroy();
  });

  test('an interim STATUS_PENDING waits for the real reply, and credits add up', () async {
    final c = await negotiated();
    final before = c.credits;
    final w = SmbConnection.newRequest(4)
      ..u16(4)
      ..u16(0);
    final f = c.send(SmbCommand.echo, w);
    final req = await server.next();
    final mid = le64(req, 24);
    server.send(_frame([_reply(SmbCommand.echo, mid, [4, 0, 0, 0], status: NtStatus.pending, flags: 3, asyncId: 77, credits: 5)]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    server.send(_frame([_reply(SmbCommand.echo, mid, [4, 0, 0, 0], flags: 3, asyncId: 77, credits: 7)]));
    final r = await f;
    expect(r.status, NtStatus.success);
    expect(c.credits, before - 1 + 5 + 7);
    c.destroy();
  });

  test('a compound reply answers two requests', () async {
    final c = await negotiated();
    final a = c.send(SmbCommand.echo, SmbConnection.newRequest(4)
      ..u16(4)
      ..u16(0));
    final b = c.send(SmbCommand.echo, SmbConnection.newRequest(4)
      ..u16(4)
      ..u16(0));
    final r1 = await server.next();
    final r2 = await server.next();
    server.send(_frame([
      _reply(SmbCommand.echo, le64(r2, 24), [4, 0, 0, 0]),
      _reply(SmbCommand.echo, le64(r1, 24), [4, 0, 0, 0], status: NtStatus.accessDenied),
    ]));
    expect((await b).status, NtStatus.success);
    expect((await a).status, NtStatus.accessDenied);
    c.destroy();
  });

  test('an SMB1-only server is recognised', () async {
    final c = await SmbConnection.open('127.0.0.1', server.port);
    final f = c.negotiate();
    await server.next();
    final smb1 = Uint8List(40)..setAll(0, [0xff, 0x53, 0x4d, 0x42, 0x72]);
    server.send(concatBytes([
      [0, 0, 0, smb1.length],
      smb1,
    ]));
    await expectLater(f, throwsA(isA<SmbProtocolException>().having((e) => e.kind, 'kind', SmbProblem.smb1Only)));
  });

  test('a dropped connection fails what was waiting', () async {
    final c = await negotiated();
    final f = c.send(SmbCommand.echo, SmbConnection.newRequest(4)
      ..u16(4)
      ..u16(0));
    await server.next();
    await server.dropClient();
    await expectLater(f, throwsA(isA<SmbConnectionException>()));
    await c.done;
    expect(c.isClosed, isTrue);
  });

  test('a server that stops answering times out', () async {
    final c = await negotiated(options: const SmbOptions(requestTimeout: Duration(milliseconds: 300)));
    final f = c.send(SmbCommand.echo, SmbConnection.newRequest(4)
      ..u16(4)
      ..u16(0));
    await expectLater(f, throwsA(isA<SmbConnectionException>().having((e) => e.timedOut, 'timedOut', isTrue)));
  });

  test('nothing listening: refused', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    await expectLater(SmbConnection.open('127.0.0.1', port), throwsA(isA<SmbConnectionException>()));
  });
}
