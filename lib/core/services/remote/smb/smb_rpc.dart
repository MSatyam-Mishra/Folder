import 'dart:typed_data';

import 'smb_bytes.dart';
import 'smb_client.dart';
import 'smb_connection.dart';
import 'smb_constants.dart';

/// DCE/RPC over the `\PIPE\srvsvc` named pipe, for NetrShareEnum (MS-SRVS
/// opnum 15): the list of shares a server has.

/// 4b324fc8-1670-01d3-1278-5a47bf6ee188 v3.0
final Uint8List _srvsvcUuid = _uuid('4b324fc8-1670-01d3-1278-5a47bf6ee188');

/// NDR 8a885d04-1ceb-11c9-9fe8-08002b104860 v2.0
final Uint8List _ndrUuid = _uuid('8a885d04-1ceb-11c9-9fe8-08002b104860');

/// A UUID in DCE's wire order: the first three fields little-endian.
Uint8List _uuid(String s) {
  final h = hexBytes(s);
  return Uint8List.fromList([h[3], h[2], h[1], h[0], h[5], h[4], h[7], h[6], ...h.sublist(8)]);
}

const _maxFrag = 4280;

class RpcException implements Exception {
  RpcException(this.message);
  final String message;
  @override
  String toString() => 'RpcException($message)';
}

/// The DCE/RPC PDUs, kept apart from the pipe so tests can check them.
abstract final class Rpc {
  static const typeRequest = 0;
  static const typeResponse = 2;
  static const typeFault = 3;
  static const typeBind = 11;
  static const typeBindAck = 12;
  static const typeBindNak = 13;
  static const firstFrag = 1;
  static const lastFrag = 2;

  static void _header(ByteWriter w, int type, int flags, int callId) {
    w
      ..u8(5)
      ..u8(0)
      ..u8(type)
      ..u8(flags)
      ..u32(0x10) // little-endian, ASCII, IEEE
      ..u16(0) // frag length, patched
      ..u16(0)
      ..u32(callId);
  }

  static Uint8List bind(int callId) {
    final w = ByteWriter(72);
    _header(w, typeBind, firstFrag | lastFrag, callId);
    w
      ..u16(_maxFrag)
      ..u16(_maxFrag)
      ..u32(0)
      ..u8(1) // one context
      ..zeros(3)
      ..u16(0) // context id
      ..u8(1) // one transfer syntax
      ..u8(0)
      ..bytes(_srvsvcUuid)
      ..u16(3)
      ..u16(0)
      ..bytes(_ndrUuid)
      ..u32(2);
    w.setU16(8, w.length);
    return Uint8List.fromList(w.toBytes());
  }

  /// Checks a bind_ack and returns the server's max receive fragment.
  static int parseBindAck(Uint8List pdu) {
    if (pdu.length < 24) throw RpcException('Short bind reply');
    final type = pdu[2];
    if (type == typeBindNak) throw RpcException('The server refused the RPC bind');
    if (type != typeBindAck) throw RpcException('Unexpected RPC reply $type');
    final r = ByteReader(pdu, 16);
    r.u16(); // max xmit
    final maxRecv = r.u16();
    r.u32();
    final portLen = r.u16();
    r.skip(portLen);
    r.align(4);
    final results = r.u8();
    r.skip(3);
    if (results < 1 || r.u16() != 0) throw RpcException('The server didn\'t accept the srvsvc interface');
    return maxRecv;
  }

  static Uint8List request(int callId, int opnum, Uint8List stub) {
    final w = ByteWriter(24 + stub.length);
    _header(w, typeRequest, firstFrag | lastFrag, callId);
    w
      ..u32(stub.length)
      ..u16(0)
      ..u16(opnum)
      ..bytes(stub);
    w.setU16(8, w.length);
    return Uint8List.fromList(w.toBytes());
  }

  /// Joins response fragments into the stub data.
  static Uint8List stubOf(List<Uint8List> fragments) {
    final parts = <Uint8List>[];
    for (final f in fragments) {
      if (f.length < 16) throw RpcException('Short RPC fragment');
      if (f[2] == typeFault) {
        final status = f.length >= 28 ? le32(f, 24) : 0;
        throw RpcException('RPC fault 0x${status.toRadixString(16)}');
      }
      if (f[2] != typeResponse) throw RpcException('Unexpected RPC reply ${f[2]}');
      final fragLen = le16(f, 8);
      final authLen = le16(f, 10);
      final end = fragLen - (authLen > 0 ? authLen + 8 : 0);
      parts.add(Uint8List.sublistView(f, 24, end));
    }
    return concatBytes(parts);
  }

  /// NetrShareEnum's request stub, level 1.
  static Uint8List netShareEnumRequest(String server) {
    final w = ByteWriter(96);
    final name = '\\\\$server\x00';
    w
      ..u32(0x00020000) // unique pointer to the server name
      ..u32(name.length)
      ..u32(0)
      ..u32(name.length)
      ..bytes(utf16le(name));
    w.align(4);
    w
      ..u32(1) // level
      ..u32(1) // union switch
      ..u32(0x00020004) // pointer to SHARE_INFO_1_CONTAINER
      ..u32(0) // entries read
      ..u32(0) // null buffer
      ..u32(0xffffffff) // preferred maximum length
      ..u32(0x00020008) // resume handle pointer
      ..u32(0);
    return Uint8List.fromList(w.toBytes());
  }

  static List<SmbShareInfo> parseNetShareEnum(Uint8List stub) {
    final r = ByteReader(stub);
    final level = r.u32();
    r.u32(); // switch
    if (level != 1) throw RpcException('Unexpected info level $level');
    final ptr = r.u32();
    if (ptr == 0) return const [];
    final count = r.u32();
    final bufPtr = r.u32();
    if (bufPtr == 0 || count == 0) return const [];
    final max = r.u32();
    if (max < count) throw RpcException('Bad share list');
    final fixed = <(int, int, int)>[];
    for (var i = 0; i < count; i++) {
      fixed.add((r.u32(), r.u32(), r.u32()));
    }
    String str(int pointer) {
      if (pointer == 0) return '';
      r.align(4);
      r.u32(); // max count
      r.u32(); // offset
      final actual = r.u32();
      final s = fromUtf16le(r.bytes(actual * 2), 0, null, true);
      r.align(4);
      return s;
    }

    final out = <SmbShareInfo>[];
    for (final (namePtr, type, remarkPtr) in fixed) {
      final name = str(namePtr);
      final remark = str(remarkPtr);
      out.add(SmbShareInfo(name, type, remark));
    }
    return out;
  }
}

class SrvsvcClient {
  SrvsvcClient(this.client, this.ipc);

  final SmbClient client;
  final SmbTree ipc;

  Future<List<SmbShareInfo>> netShareEnumAll() async {
    final pipe = await client.create(
      ipc,
      'srvsvc',
      access: FileAccess.readData |
          FileAccess.writeData |
          FileAccess.appendData |
          FileAccess.readEa |
          FileAccess.writeEa |
          FileAccess.readAttributes |
          FileAccess.writeAttributes |
          FileAccess.readControl |
          FileAccess.synchronize,
      share: ShareAccess.read | ShareAccess.write,
    );
    return client.using(pipe, (pipe) async {
      await client.write(pipe, 0, Rpc.bind(1));
      final ack = await client.read(pipe, 0, _maxFrag);
      Rpc.parseBindAck(ack);
      final req = Rpc.request(2, 15, Rpc.netShareEnumRequest(client.host));
      final r = await client.connection.ioctl(ipc, Fsctl.pipeTransceive, req, fileId: pipe.fileId, maxOutput: _maxFrag);
      if (r.status != NtStatus.success && r.status != NtStatus.bufferOverflow) {
        throw SmbStatusException(r.status, SmbCommand.ioctl, 'srvsvc');
      }
      // The reply comes as fragments; the rest of a cut one, and the
      // fragments after it, are read from the pipe.
      final buffer = BytesBuilderLiteList()..add(SmbConnection.ioctlOutput(r));
      final fragments = <Uint8List>[];
      while (true) {
        while (buffer.length < 16 || buffer.length < le16(buffer.peek(16), 8)) {
          final more = await client.read(pipe, 0, _maxFrag);
          if (more.isEmpty) throw RpcException('The share list ended too soon');
          buffer.add(more);
        }
        final len = le16(buffer.peek(16), 8);
        final frag = buffer.take(len);
        fragments.add(frag);
        if ((frag[3] & Rpc.lastFrag) != 0) break;
      }
      final shares = Rpc.parseNetShareEnum(Rpc.stubOf(fragments));
      return shares;
    });
  }
}

/// A byte queue: add chunks, peek and take from the front.
class BytesBuilderLiteList {
  Uint8List _data = Uint8List(0);

  int get length => _data.length;

  void add(Uint8List b) => _data = concatBytes([_data, b]);

  Uint8List peek(int n) => Uint8List.sublistView(_data, 0, n);

  Uint8List take(int n) {
    final out = Uint8List.fromList(Uint8List.sublistView(_data, 0, n));
    _data = Uint8List.fromList(Uint8List.sublistView(_data, n));
    return out;
  }
}
