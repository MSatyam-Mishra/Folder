import 'dart:typed_data';

/// PBKDF2 with HMAC-SHA1, as WinZip's AES needs it once per file: the
/// HMAC's inner and outer states are worked out once, and each of the
/// thousand rounds is then two SHA-1 blocks with nothing allocated, several
/// times faster than a general HMAC, which matters with thousands of files.
Uint8List pbkdf2HmacSha1(List<int> password, List<int> salt, int iterations, int length) {
  // A key longer than a block is hashed first, as HMAC says.
  var key = password;
  if (key.length > 64) key = _Sha1.digest(key);
  final ipad = Uint8List(64);
  final opad = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    final k = i < key.length ? key[i] : 0;
    ipad[i] = k ^ 0x36;
    opad[i] = k ^ 0x5C;
  }
  final inner = _Sha1.stateAfter(ipad);
  final outer = _Sha1.stateAfter(opad);

  final out = Uint8List(((length + 19) ~/ 20) * 20);
  final w = Uint32List(80);
  final state = Uint32List(5);
  final u = Uint32List(5);
  final t = Uint32List(5);
  for (var block = 1; block * 20 - 20 < length; block++) {
    // U1 = HMAC(password, salt || INT(block)).
    final first = BytesBuilder(copy: false)
      ..add(salt)
      ..add([block >> 24 & 0xFF, block >> 16 & 0xFF, block >> 8 & 0xFF, block & 0xFF]);
    final innerDigest = _Sha1.digestFrom(inner, first.takeBytes(), 64);
    final firstU = _Sha1.digestFrom(outer, innerDigest, 64);
    for (var i = 0; i < 5; i++) {
      u[i] = (firstU[i * 4] << 24) | (firstU[i * 4 + 1] << 16) | (firstU[i * 4 + 2] << 8) | firstU[i * 4 + 3];
      t[i] = u[i];
    }
    for (var round = 1; round < iterations; round++) {
      // Inner: the 20 bytes of U, padded, after ipad's block.
      _hmacBlock(inner, u, state, w);
      // Outer: the inner digest, padded, after opad's block.
      _hmacBlock(outer, state, u, w);
      for (var i = 0; i < 5; i++) {
        t[i] ^= u[i];
      }
    }
    final at = (block - 1) * 20;
    for (var i = 0; i < 5; i++) {
      out[at + i * 4] = t[i] >> 24 & 0xFF;
      out[at + i * 4 + 1] = t[i] >> 16 & 0xFF;
      out[at + i * 4 + 2] = t[i] >> 8 & 0xFF;
      out[at + i * 4 + 3] = t[i] & 0xFF;
    }
  }
  return Uint8List.sublistView(out, 0, length);
}

/// SHA-1 of a 20-byte message (in [message], as words) that follows one
/// block already hashed into [start]; the digest goes into [result].
void _hmacBlock(Uint32List start, Uint32List message, Uint32List result, Uint32List w) {
  for (var i = 0; i < 5; i++) {
    w[i] = message[i];
  }
  w[5] = 0x80000000;
  for (var i = 6; i < 15; i++) {
    w[i] = 0;
  }
  w[15] = (64 + 20) * 8;
  for (var i = 0; i < 5; i++) {
    result[i] = start[i];
  }
  _Sha1.compress(result, w);
}

abstract final class _Sha1 {
  static Uint32List get _initial => Uint32List.fromList([0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]);

  /// The state after one whole 64-byte [block].
  static Uint32List stateAfter(Uint8List block) {
    final state = _initial;
    final w = Uint32List(80);
    _load(w, block, 0);
    compress(state, w);
    return state;
  }

  static Uint8List digest(List<int> data) => digestFrom(_initial, data, 0);

  /// The digest of [data] after [state], which has [before] bytes hashed.
  static Uint8List digestFrom(Uint32List state, List<int> data, int before) {
    final h = Uint32List.fromList(state);
    final total = before + data.length;
    final padded = Uint8List(((data.length + 9 + 63) ~/ 64) * 64)..setRange(0, data.length, data);
    padded[data.length] = 0x80;
    final bits = total * 8;
    for (var i = 0; i < 8; i++) {
      padded[padded.length - 1 - i] = (bits >> (8 * i)) & 0xFF;
    }
    final w = Uint32List(80);
    for (var at = 0; at < padded.length; at += 64) {
      _load(w, padded, at);
      compress(h, w);
    }
    final out = Uint8List(20);
    for (var i = 0; i < 5; i++) {
      out[i * 4] = h[i] >> 24 & 0xFF;
      out[i * 4 + 1] = h[i] >> 16 & 0xFF;
      out[i * 4 + 2] = h[i] >> 8 & 0xFF;
      out[i * 4 + 3] = h[i] & 0xFF;
    }
    return out;
  }

  static void _load(Uint32List w, Uint8List bytes, int at) {
    for (var i = 0; i < 16; i++) {
      final j = at + i * 4;
      w[i] = (bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3];
    }
  }

  /// One block: the first 16 words of [w] in, [h] updated.
  static void compress(Uint32List h, Uint32List w) {
    for (var i = 16; i < 80; i++) {
      final x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
      w[i] = ((x << 1) | (x >> 31)) & 0xFFFFFFFF;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (var i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (((a << 5) | (a >> 27)) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = ((b << 30) | (b >> 2)) & 0xFFFFFFFF;
      b = a;
      a = temp;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
  }
}
