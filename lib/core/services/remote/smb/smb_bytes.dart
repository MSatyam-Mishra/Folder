import 'dart:math';
import 'dart:typed_data';

/// Little-endian byte building and reading for SMB2, NTLM and DCE/RPC.

/// A growable buffer that writes little-endian numbers.
class ByteWriter {
  ByteWriter([int capacity = 256]) : _buf = Uint8List(max(16, capacity));

  Uint8List _buf;
  int _len = 0;

  int get length => _len;

  void _ensure(int extra) {
    final need = _len + extra;
    if (need <= _buf.length) return;
    var size = _buf.length * 2;
    while (size < need) {
      size *= 2;
    }
    _buf = Uint8List(size)..setRange(0, _len, _buf);
  }

  void u8(int v) {
    _ensure(1);
    _buf[_len++] = v & 0xff;
  }

  void u16(int v) {
    _ensure(2);
    _buf[_len++] = v & 0xff;
    _buf[_len++] = (v >> 8) & 0xff;
  }

  void u32(int v) {
    _ensure(4);
    _buf[_len++] = v & 0xff;
    _buf[_len++] = (v >> 8) & 0xff;
    _buf[_len++] = (v >> 16) & 0xff;
    _buf[_len++] = (v >> 24) & 0xff;
  }

  /// Writes all 64 bits of [v]; -1 gives eight 0xff bytes.
  void u64(int v) {
    u32(v & 0xffffffff);
    u32((v >> 32) & 0xffffffff);
  }

  void u16be(int v) {
    _ensure(2);
    _buf[_len++] = (v >> 8) & 0xff;
    _buf[_len++] = v & 0xff;
  }

  void u32be(int v) {
    _ensure(4);
    _buf[_len++] = (v >> 24) & 0xff;
    _buf[_len++] = (v >> 16) & 0xff;
    _buf[_len++] = (v >> 8) & 0xff;
    _buf[_len++] = v & 0xff;
  }

  void bytes(List<int> b, [int start = 0, int? end]) {
    final e = end ?? b.length;
    _ensure(e - start);
    _buf.setRange(_len, _len + e - start, b, start);
    _len += e - start;
  }

  void zeros(int n) {
    if (n <= 0) return;
    _ensure(n);
    _buf.fillRange(_len, _len + n, 0);
    _len += n;
  }

  /// Pads with zeros until the length is a multiple of [n], counted from
  /// [from] (the start of the message the alignment is relative to).
  void align(int n, {int from = 0}) {
    final rem = (_len - from) % n;
    if (rem != 0) zeros(n - rem);
  }

  void setU8(int offset, int v) => _buf[offset] = v & 0xff;

  void setU16(int offset, int v) {
    _buf[offset] = v & 0xff;
    _buf[offset + 1] = (v >> 8) & 0xff;
  }

  void setU32(int offset, int v) {
    _buf[offset] = v & 0xff;
    _buf[offset + 1] = (v >> 8) & 0xff;
    _buf[offset + 2] = (v >> 16) & 0xff;
    _buf[offset + 3] = (v >> 24) & 0xff;
  }

  void setU64(int offset, int v) {
    setU32(offset, v & 0xffffffff);
    setU32(offset + 4, (v >> 32) & 0xffffffff);
  }

  void setBytes(int offset, List<int> b) => _buf.setRange(offset, offset + b.length, b);

  /// A view of what was written; later writes may reallocate, so take it last.
  Uint8List toBytes() => Uint8List.sublistView(_buf, 0, _len);
}

/// Reads little-endian numbers from [data], moving [offset] along.
class ByteReader {
  ByteReader(this.data, [this.offset = 0]);

  final Uint8List data;
  int offset;

  int get remaining => data.length - offset;

  void _need(int n) {
    if (offset + n > data.length || offset < 0) {
      throw const FormatException('Message ended too soon');
    }
  }

  int u8() {
    _need(1);
    return data[offset++];
  }

  int u16() {
    _need(2);
    final v = le16(data, offset);
    offset += 2;
    return v;
  }

  int u32() {
    _need(4);
    final v = le32(data, offset);
    offset += 4;
    return v;
  }

  int u64() {
    _need(8);
    final v = le64(data, offset);
    offset += 8;
    return v;
  }

  int u16be() {
    _need(2);
    final v = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return v;
  }

  int u32be() {
    _need(4);
    final v = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
    offset += 4;
    return v;
  }

  Uint8List bytes(int n) {
    _need(n);
    final v = Uint8List.sublistView(data, offset, offset + n);
    offset += n;
    return v;
  }

  void skip(int n) {
    _need(n);
    offset += n;
  }

  void align(int n, {int from = 0}) {
    final rem = (offset - from) % n;
    if (rem != 0) offset += n - rem;
  }
}

int le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int le32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int le64(Uint8List b, int o) => le32(b, o) | (le32(b, o + 4) << 32);

void setLe16(Uint8List b, int o, int v) {
  b[o] = v & 0xff;
  b[o + 1] = (v >> 8) & 0xff;
}

void setLe32(Uint8List b, int o, int v) {
  b[o] = v & 0xff;
  b[o + 1] = (v >> 8) & 0xff;
  b[o + 2] = (v >> 16) & 0xff;
  b[o + 3] = (v >> 24) & 0xff;
}

void setLe64(Uint8List b, int o, int v) {
  setLe32(b, o, v & 0xffffffff);
  setLe32(b, o + 4, (v >> 32) & 0xffffffff);
}

/// [s] as UTF-16LE, without a terminating zero.
Uint8List utf16le(String s) {
  final units = s.codeUnits;
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    out[2 * i] = units[i] & 0xff;
    out[2 * i + 1] = units[i] >> 8;
  }
  return out;
}

/// UTF-16LE bytes back to text; stops at a zero character when [stopAtZero].
String fromUtf16le(Uint8List b, [int start = 0, int? end, bool stopAtZero = false]) {
  final e = end ?? b.length;
  final units = <int>[];
  for (var i = start; i + 1 < e; i += 2) {
    final u = b[i] | (b[i + 1] << 8);
    if (stopAtZero && u == 0) break;
    units.add(u);
  }
  return String.fromCharCodes(units);
}

/// Windows FILETIME (100 ns since 1601) to a local [DateTime], null for 0.
DateTime? fromFileTime(int ft) {
  if (ft <= 0) return null;
  const epochDiff = 11644473600000000; // microseconds from 1601 to 1970
  return DateTime.fromMicrosecondsSinceEpoch(ft ~/ 10 - epochDiff, isUtc: true).toLocal();
}

int toFileTime(DateTime t) => (t.toUtc().microsecondsSinceEpoch + 11644473600000000) * 10;

final Random _random = Random.secure();

Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List concatBytes(List<List<int>> parts) {
  var n = 0;
  for (final p in parts) {
    n += p.length;
  }
  final out = Uint8List(n);
  var o = 0;
  for (final p in parts) {
    out.setRange(o, o + p.length, p);
    o += p.length;
  }
  return out;
}

String hexOf(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}
