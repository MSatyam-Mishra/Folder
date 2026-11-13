import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:pointycastle/digests/md4.dart';

import 'smb_bytes.dart';

/// The cryptography SMB needs, in plain Dart: AES (encryption direction
/// only, which is all CTR, CCM, GCM and CMAC use) with lookup tables, AES-CMAC,
/// AES-CCM, AES-GCM and GMAC with an 8-bit GHASH table, SP 800-108 key
/// derivation, plus MD4, HMAC-MD5 and RC4 for NTLM.
///
/// pointycastle has CCM and GCM too, but its GHASH works bit by bit and runs
/// at a couple of MB/s, far too slow for file transfers.

// ---------------------------------------------------------------- AES core

final Uint8List _sbox = _makeSbox();
final Uint32List _te0 = Uint32List(256);
final Uint32List _te1 = Uint32List(256);
final Uint32List _te2 = Uint32List(256);
final Uint32List _te3 = Uint32List(256);
bool _tablesReady = false;

Uint8List _makeSbox() {
  final s = Uint8List(256);
  var p = 1, q = 1;
  int rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xff;
  do {
    p = (p ^ (p << 1) ^ ((p & 0x80) != 0 ? 0x1b : 0)) & 0xff;
    q ^= q << 1;
    q ^= q << 2;
    q ^= q << 4;
    q &= 0xff;
    if ((q & 0x80) != 0) q ^= 0x09;
    final x = q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4);
    s[p] = x ^ 0x63;
  } while (p != 1);
  s[0] = 0x63;
  return s;
}

void _makeTables() {
  if (_tablesReady) return;
  for (var i = 0; i < 256; i++) {
    final s = _sbox[i];
    final s2 = ((s << 1) ^ ((s & 0x80) != 0 ? 0x1b : 0)) & 0xff;
    final s3 = s2 ^ s;
    final t = (s2 << 24) | (s << 16) | (s << 8) | s3;
    _te0[i] = t;
    _te1[i] = ((t >> 8) | (t << 24)) & 0xffffffff;
    _te2[i] = ((t >> 16) | (t << 16)) & 0xffffffff;
    _te3[i] = ((t >> 24) | (t << 8)) & 0xffffffff;
  }
  _tablesReady = true;
}

/// AES-128 or AES-256, encryption only.
class Aes {
  Aes(Uint8List key) {
    if (key.length != 16 && key.length != 32) {
      throw ArgumentError('AES keys are 16 or 32 bytes');
    }
    _makeTables();
    final nk = key.length ~/ 4;
    _rounds = nk + 6;
    final total = 4 * (_rounds + 1);
    _rk = Uint32List(total);
    for (var i = 0; i < nk; i++) {
      _rk[i] = (key[4 * i] << 24) | (key[4 * i + 1] << 16) | (key[4 * i + 2] << 8) | key[4 * i + 3];
    }
    var rcon = 1;
    for (var i = nk; i < total; i++) {
      var t = _rk[i - 1];
      if (i % nk == 0) {
        t = ((t << 8) | (t >> 24)) & 0xffffffff;
        t = (_sbox[t >> 24] << 24) | (_sbox[(t >> 16) & 0xff] << 16) | (_sbox[(t >> 8) & 0xff] << 8) | _sbox[t & 0xff];
        t ^= rcon << 24;
        rcon = ((rcon << 1) ^ ((rcon & 0x80) != 0 ? 0x1b : 0)) & 0xff;
      } else if (nk > 6 && i % nk == 4) {
        t = (_sbox[t >> 24] << 24) | (_sbox[(t >> 16) & 0xff] << 16) | (_sbox[(t >> 8) & 0xff] << 8) | _sbox[t & 0xff];
      }
      _rk[i] = _rk[i - nk] ^ t;
    }
  }

  late final int _rounds;
  late final Uint32List _rk;

  /// The result of [_encryptWords].
  final Uint32List _w = Uint32List(4);

  static int _be32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static void _put32(Uint8List b, int o, int v) {
    b[o] = (v >> 24) & 0xff;
    b[o + 1] = (v >> 16) & 0xff;
    b[o + 2] = (v >> 8) & 0xff;
    b[o + 3] = v & 0xff;
  }

  /// Encrypts one block given as four big-endian words into [_w].
  void _encryptWords(int s0, int s1, int s2, int s3) {
    final rk = _rk;
    final t0 = _te0, t1 = _te1, t2 = _te2, t3 = _te3, sb = _sbox;
    s0 ^= rk[0];
    s1 ^= rk[1];
    s2 ^= rk[2];
    s3 ^= rk[3];
    var k = 4;
    for (var r = 1; r < _rounds; r++) {
      final n0 = t0[s0 >> 24] ^ t1[(s1 >> 16) & 0xff] ^ t2[(s2 >> 8) & 0xff] ^ t3[s3 & 0xff] ^ rk[k];
      final n1 = t0[s1 >> 24] ^ t1[(s2 >> 16) & 0xff] ^ t2[(s3 >> 8) & 0xff] ^ t3[s0 & 0xff] ^ rk[k + 1];
      final n2 = t0[s2 >> 24] ^ t1[(s3 >> 16) & 0xff] ^ t2[(s0 >> 8) & 0xff] ^ t3[s1 & 0xff] ^ rk[k + 2];
      final n3 = t0[s3 >> 24] ^ t1[(s0 >> 16) & 0xff] ^ t2[(s1 >> 8) & 0xff] ^ t3[s2 & 0xff] ^ rk[k + 3];
      s0 = n0;
      s1 = n1;
      s2 = n2;
      s3 = n3;
      k += 4;
    }
    final w = _w;
    w[0] = ((sb[s0 >> 24] << 24) | (sb[(s1 >> 16) & 0xff] << 16) | (sb[(s2 >> 8) & 0xff] << 8) | sb[s3 & 0xff]) ^ rk[k];
    w[1] = ((sb[s1 >> 24] << 24) | (sb[(s2 >> 16) & 0xff] << 16) | (sb[(s3 >> 8) & 0xff] << 8) | sb[s0 & 0xff]) ^ rk[k + 1];
    w[2] = ((sb[s2 >> 24] << 24) | (sb[(s3 >> 16) & 0xff] << 16) | (sb[(s0 >> 8) & 0xff] << 8) | sb[s1 & 0xff]) ^ rk[k + 2];
    w[3] = ((sb[s3 >> 24] << 24) | (sb[(s0 >> 16) & 0xff] << 16) | (sb[(s1 >> 8) & 0xff] << 8) | sb[s2 & 0xff]) ^ rk[k + 3];
  }

  /// Encrypts the 16 bytes at [inOff] of [input] into [out] at [outOff]
  /// (they may be the same place).
  void encryptBlock(Uint8List input, int inOff, Uint8List out, int outOff) {
    _encryptWords(_be32(input, inOff), _be32(input, inOff + 4), _be32(input, inOff + 8), _be32(input, inOff + 12));
    final w = _w;
    _put32(out, outOff, w[0]);
    _put32(out, outOff + 4, w[1]);
    _put32(out, outOff + 8, w[2]);
    _put32(out, outOff + 12, w[3]);
  }

  Uint8List encrypt(Uint8List block) {
    final out = Uint8List(16);
    encryptBlock(block, 0, out, 0);
    return out;
  }

  /// CBC-MAC style chaining: `state = E(state ^ block)` over [data] from
  /// [start] to [end] (a multiple of 16 apart), a word at a time.
  void cbcMacInto(Uint8List state, Uint8List data, int start, int end) {
    if (end <= start) return;
    final bd = ByteData.sublistView(data);
    final w = _w;
    var s0 = _be32(state, 0), s1 = _be32(state, 4), s2 = _be32(state, 8), s3 = _be32(state, 12);
    for (var i = start; i < end; i += 16) {
      _encryptWords(
        s0 ^ bd.getUint32(i, Endian.big),
        s1 ^ bd.getUint32(i + 4, Endian.big),
        s2 ^ bd.getUint32(i + 8, Endian.big),
        s3 ^ bd.getUint32(i + 12, Endian.big),
      );
      s0 = w[0];
      s1 = w[1];
      s2 = w[2];
      s3 = w[3];
    }
    _put32(state, 0, s0);
    _put32(state, 4, s1);
    _put32(state, 8, s2);
    _put32(state, 12, s3);
  }

  /// XORs [data] (start to end) with the key stream of the big-endian
  /// counter block [counter], whose last [counterBytes] bytes (at most 4)
  /// count up per block; [counter] is left at the next value.
  void ctrXor(Uint8List counter, Uint8List data, int start, int end, {int counterBytes = 4}) {
    if (end <= start) return;
    final bd = ByteData.sublistView(data);
    final w = _w;
    final c0 = _be32(counter, 0), c1 = _be32(counter, 4), c2 = _be32(counter, 8);
    var c3 = _be32(counter, 12);
    final mask = counterBytes >= 4 ? 0xffffffff : (1 << (8 * counterBytes)) - 1;
    var i = start;
    for (; i + 16 <= end; i += 16) {
      _encryptWords(c0, c1, c2, c3);
      bd.setUint32(i, bd.getUint32(i, Endian.big) ^ w[0], Endian.big);
      bd.setUint32(i + 4, bd.getUint32(i + 4, Endian.big) ^ w[1], Endian.big);
      bd.setUint32(i + 8, bd.getUint32(i + 8, Endian.big) ^ w[2], Endian.big);
      bd.setUint32(i + 12, bd.getUint32(i + 12, Endian.big) ^ w[3], Endian.big);
      c3 = (c3 & ~mask & 0xffffffff) | ((c3 + 1) & mask);
    }
    if (i < end) {
      _encryptWords(c0, c1, c2, c3);
      final ks = Uint8List(16);
      _put32(ks, 0, w[0]);
      _put32(ks, 4, w[1]);
      _put32(ks, 8, w[2]);
      _put32(ks, 12, w[3]);
      for (var j = 0; i + j < end; j++) {
        data[i + j] ^= ks[j];
      }
      c3 = (c3 & ~mask & 0xffffffff) | ((c3 + 1) & mask);
    }
    _put32(counter, 12, c3);
  }
}

// ---------------------------------------------------------------- CMAC

/// AES-CMAC (RFC 4493) over [data], 16 bytes.
Uint8List aesCmac(Uint8List key, Uint8List data, [int start = 0, int? end]) => AesCmac(key).mac(data, start, end);

class AesCmac {
  AesCmac(Uint8List key) : _aes = Aes(key) {
    final l = _aes.encrypt(Uint8List(16));
    _k1 = _dbl(l);
    _k2 = _dbl(_k1);
  }

  final Aes _aes;
  late final Uint8List _k1;
  late final Uint8List _k2;

  static Uint8List _dbl(Uint8List x) {
    final out = Uint8List(16);
    var carry = 0;
    for (var i = 15; i >= 0; i--) {
      final v = (x[i] << 1) | carry;
      out[i] = v & 0xff;
      carry = (x[i] >> 7) & 1;
    }
    if ((x[0] & 0x80) != 0) out[15] ^= 0x87;
    return out;
  }

  Uint8List mac(Uint8List data, [int start = 0, int? end]) {
    final e = end ?? data.length;
    final len = e - start;
    final state = Uint8List(16);
    final full = len == 0 ? 0 : ((len - 1) ~/ 16) * 16; // all but the last block
    _aes.cbcMacInto(state, data, start, start + full);
    final last = Uint8List(16);
    final rest = len - full;
    if (rest == 16) {
      for (var j = 0; j < 16; j++) {
        last[j] = data[start + full + j] ^ _k1[j];
      }
    } else {
      for (var j = 0; j < rest; j++) {
        last[j] = data[start + full + j];
      }
      last[rest] = 0x80;
      for (var j = 0; j < 16; j++) {
        last[j] ^= _k2[j];
      }
    }
    for (var j = 0; j < 16; j++) {
      state[j] ^= last[j];
    }
    _aes.encryptBlock(state, 0, state, 0);
    return state;
  }
}

// ---------------------------------------------------------------- GHASH / GCM

/// GF(2^128)'s reduction (x^128 + x^7 + x^2 + x + 1) in GCM's bit order.
final int _poly = 0xe1 << 56;

/// What shifting a byte out of the bottom adds at the top, for each byte.
final Int64List _r8 = () {
  final r = Int64List(256);
  for (var b = 0; b < 256; b++) {
    var h = 0, l = b;
    for (var k = 0; k < 8; k++) {
      final lsb = l & 1;
      l = (h << 63) | (l >>> 1);
      h = h >>> 1;
      if (lsb != 0) h ^= _poly;
    }
    r[b] = h;
  }
  return r;
}();

/// GHASH with Shoup's 8-bit tables (`b·H` for every byte `b`), the state
/// kept as two 64-bit halves.
class _Ghash {
  _Ghash(Uint8List h) {
    var vh = _be64(h, 0);
    var vl = _be64(h, 8);
    _mh[128] = vh;
    _ml[128] = vl;
    for (var i = 64; i > 0; i >>= 1) {
      final lsb = vl & 1;
      vl = (vh << 63) | (vl >>> 1);
      vh = vh >>> 1;
      if (lsb != 0) vh ^= _poly;
      _mh[i] = vh;
      _ml[i] = vl;
    }
    for (var i = 2; i <= 128; i <<= 1) {
      for (var j = 1; j < i; j++) {
        _mh[i + j] = _mh[i] ^ _mh[j];
        _ml[i + j] = _ml[i] ^ _ml[j];
      }
    }
  }

  final Int64List _mh = Int64List(256);
  final Int64List _ml = Int64List(256);
  int _yh = 0;
  int _yl = 0;

  static int _be64(Uint8List b, int o) =>
      (b[o] << 56) | (b[o + 1] << 48) | (b[o + 2] << 40) | (b[o + 3] << 32) | (b[o + 4] << 24) | (b[o + 5] << 16) | (b[o + 6] << 8) | b[o + 7];

  /// Absorbs [data] from start to end, zero-padding the last block.
  void update(Uint8List data, int start, int end) {
    if (end <= start) return;
    final bd = ByteData.sublistView(data);
    final mh = _mh, ml = _ml, r8 = _r8;
    var yh = _yh, yl = _yl;
    for (var i = start; i < end; i += 16) {
      if (i + 16 <= end) {
        yh ^= bd.getInt64(i, Endian.big);
        yl ^= bd.getInt64(i + 8, Endian.big);
      } else {
        final pad = Uint8List(16)..setRange(0, end - i, data, i);
        yh ^= _be64(pad, 0);
        yl ^= _be64(pad, 8);
      }
      // y = y·H, from the last byte to the first.
      var b = yl & 0xff;
      var zh = mh[b];
      var zl = ml[b];
      for (var s = 8; s < 64; s += 8) {
        b = (yl >>> s) & 0xff;
        final rem = zl & 0xff;
        zl = (zh << 56) | (zl >>> 8);
        zh = (zh >>> 8) ^ r8[rem] ^ mh[b];
        zl ^= ml[b];
      }
      for (var s = 0; s < 64; s += 8) {
        b = (yh >>> s) & 0xff;
        final rem = zl & 0xff;
        zl = (zh << 56) | (zl >>> 8);
        zh = (zh >>> 8) ^ r8[rem] ^ mh[b];
        zl ^= ml[b];
      }
      yh = zh;
      yl = zl;
    }
    _yh = yh;
    _yl = yl;
  }

  void updateLengths(int aadBytes, int dataBytes) {
    final w = Uint8List(16);
    final bd = ByteData.sublistView(w);
    bd.setInt64(0, aadBytes * 8, Endian.big);
    bd.setInt64(8, dataBytes * 8, Endian.big);
    update(w, 0, 16);
  }

  Uint8List digest() {
    final out = Uint8List(16);
    final bd = ByteData.sublistView(out);
    bd.setInt64(0, _yh, Endian.big);
    bd.setInt64(8, _yl, Endian.big);
    return out;
  }
}

/// AES-GCM with a 12-byte nonce and 16-byte tag. [data] is encrypted or
/// decrypted in place; returns the tag (computed over the cipher text).
Uint8List aesGcm(Uint8List key, Uint8List nonce, Uint8List aad, Uint8List data, {required bool encrypt, int start = 0, int? end}) {
  final e = end ?? data.length;
  final aes = Aes(key);
  final h = aes.encrypt(Uint8List(16));
  final g = _Ghash(h);
  final j0 = Uint8List(16)..setRange(0, 12, nonce);
  j0[15] = 1;
  final tagMask = aes.encrypt(j0);
  g.update(aad, 0, aad.length);
  final counter = Uint8List.fromList(j0);
  counter[15] = 2;
  if (encrypt) {
    aes.ctrXor(counter, data, start, e);
    g.update(data, start, e);
  } else {
    g.update(data, start, e);
    aes.ctrXor(counter, data, start, e);
  }
  g.updateLengths(aad.length, e - start);
  final tag = g.digest();
  for (var i = 0; i < 16; i++) {
    tag[i] ^= tagMask[i];
  }
  return tag;
}

/// AES-GMAC: GCM's tag over [aad] alone.
Uint8List aesGmac(Uint8List key, Uint8List nonce, Uint8List aad) => aesGcm(key, nonce, aad, Uint8List(0), encrypt: true);

// ---------------------------------------------------------------- CCM

/// AES-CCM with an 11-byte nonce (so a 4-byte length) and 16-byte tag, as
/// SMB 3 uses it. [data] is encrypted or decrypted in place; returns the tag.
Uint8List aesCcm(Uint8List key, Uint8List nonce, Uint8List aad, Uint8List data, {required bool encrypt, int start = 0, int? end}) {
  final e = end ?? data.length;
  final len = e - start;
  final aes = Aes(key);
  final n = nonce.length; // 11 for SMB
  final lBytes = 15 - n;
  // CBC-MAC
  final b0 = Uint8List(16);
  b0[0] = (aad.isNotEmpty ? 0x40 : 0) | (((16 - 2) ~/ 2) << 3) | (lBytes - 1);
  b0.setRange(1, 1 + n, nonce);
  for (var i = 0; i < lBytes; i++) {
    b0[15 - i] = (len >> (8 * i)) & 0xff;
  }
  final mac = Uint8List(16);
  aes.cbcMacInto(mac, b0, 0, 16);
  if (aad.isNotEmpty) {
    final aadBlock = Uint8List(((aad.length + 2 + 15) ~/ 16) * 16);
    aadBlock[0] = aad.length >> 8;
    aadBlock[1] = aad.length & 0xff;
    aadBlock.setRange(2, 2 + aad.length, aad);
    aes.cbcMacInto(mac, aadBlock, 0, aadBlock.length);
  }
  final ctr = Uint8List(16);
  ctr[0] = lBytes - 1;
  ctr.setRange(1, 1 + n, nonce);
  final s0 = aes.encrypt(ctr);
  ctr[15] = 1;

  void macData() {
    final full = (len ~/ 16) * 16;
    aes.cbcMacInto(mac, data, start, start + full);
    if (full < len) {
      final last = Uint8List(16)..setRange(0, len - full, data, start + full);
      aes.cbcMacInto(mac, last, 0, 16);
    }
  }

  if (encrypt) {
    macData();
    aes.ctrXor(ctr, data, start, e, counterBytes: lBytes);
  } else {
    aes.ctrXor(ctr, data, start, e, counterBytes: lBytes);
    macData();
  }
  for (var i = 0; i < 16; i++) {
    mac[i] ^= s0[i];
  }
  return mac;
}

// ---------------------------------------------------------------- hashes

Uint8List hmacSha256(List<int> key, List<int> data) => Uint8List.fromList(hash.Hmac(hash.sha256, key).convert(data).bytes);

Uint8List hmacMd5(List<int> key, List<int> data) => Uint8List.fromList(hash.Hmac(hash.md5, key).convert(data).bytes);

Uint8List md5(List<int> data) => Uint8List.fromList(hash.md5.convert(data).bytes);

Uint8List sha512(List<int> data) => Uint8List.fromList(hash.sha512.convert(data).bytes);

Uint8List md4(List<int> data) => MD4Digest().process(Uint8List.fromList(data));

/// SP 800-108 KDF in counter mode with HMAC-SHA256, as SMB 3 derives its
/// keys: `HMAC(key, i || label || 0 || context || L)`.
Uint8List smbKdf(Uint8List key, List<int> label, List<int> context, {int bits = 128}) {
  final out = BytesBuilderLite();
  var i = 1;
  while (out.length < bits ~/ 8) {
    final w = ByteWriter(label.length + context.length + 9)
      ..u32be(i)
      ..bytes(label)
      ..u8(0)
      ..bytes(context)
      ..u32be(bits);
    out.add(hmacSha256(key, w.toBytes()));
    i++;
  }
  return Uint8List.sublistView(out.takeBytes(), 0, bits ~/ 8);
}

class BytesBuilderLite {
  final List<Uint8List> _parts = [];
  int length = 0;

  void add(Uint8List b) {
    _parts.add(b);
    length += b.length;
  }

  Uint8List takeBytes() {
    final out = concatBytes(_parts);
    _parts.clear();
    length = 0;
    return out;
  }
}

/// RC4, kept as a running stream (NTLM's sealing handle needs that).
class Rc4 {
  Rc4(List<int> key) {
    for (var i = 0; i < 256; i++) {
      _s[i] = i;
    }
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + _s[i] + key[i % key.length]) & 0xff;
      final t = _s[i];
      _s[i] = _s[j];
      _s[j] = t;
    }
  }

  final Uint8List _s = Uint8List(256);
  int _i = 0;
  int _j = 0;

  Uint8List process(List<int> data) {
    final out = Uint8List(data.length);
    for (var k = 0; k < data.length; k++) {
      _i = (_i + 1) & 0xff;
      _j = (_j + _s[_i]) & 0xff;
      final t = _s[_i];
      _s[_i] = _s[_j];
      _s[_j] = t;
      out[k] = data[k] ^ _s[(_s[_i] + _s[_j]) & 0xff];
    }
    return out;
  }
}
