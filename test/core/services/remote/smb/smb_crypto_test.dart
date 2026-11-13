import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/smb/smb_bytes.dart';
import 'package:folders/core/services/remote/smb/smb_crypto.dart';

/// Published vectors (FIPS-197, RFC 4493, McGrew and Viega's GCM paper), plus
/// vectors made with Python's `cryptography` package for CCM with SMB's
/// 11-byte nonce and odd lengths (`data/crypto_vectors.json`).
void main() {
  test('AES-128 and AES-256 match FIPS-197', () {
    final pt = hexBytes('00112233445566778899aabbccddeeff');
    expect(hexOf(Aes(hexBytes('000102030405060708090a0b0c0d0e0f')).encrypt(pt)), '69c4e0d86a7b0430d8cdb78070b4c55a');
    expect(
      hexOf(Aes(hexBytes('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')).encrypt(pt)),
      '8ea2b7ca516745bfeafc49904b496089',
    );
  });

  test('AES-CMAC matches RFC 4493', () {
    final key = hexBytes('2b7e151628aed2a6abf7158809cf4f3c');
    final m = hexBytes('6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51'
        '30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710');
    expect(hexOf(aesCmac(key, Uint8List(0))), 'bb1d6929e95937287fa37d129b756746');
    expect(hexOf(aesCmac(key, m.sublist(0, 16))), '070a16b46b4d4144f79bdd9dd04a287c');
    expect(hexOf(aesCmac(key, m.sublist(0, 40))), 'dfa66747de9ae63030ca32611497c827');
    expect(hexOf(aesCmac(key, m)), '51f0bebf7e3b9d92fc49741779363cfe');
  });

  test('AES-GCM matches the GCM paper', () {
    final zero = Uint8List(16);
    final data = Uint8List(16);
    final tag = aesGcm(zero, Uint8List(12), Uint8List(0), data, encrypt: true);
    expect(hexOf(data), '0388dace60b6a392f328c2b971b2fe78');
    expect(hexOf(tag), 'ab6e47d42cec13bdf53a67b21257bddf');

    // Test case 4: with additional data and a partial last block.
    final key = hexBytes('feffe9928665731c6d6a8f9467308308');
    final iv = hexBytes('cafebabefacedbaddecaf888');
    final aad = hexBytes('feedfacedeadbeeffeedfacedeadbeefabaddad2');
    final pt = hexBytes('d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72'
        '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39');
    final t4 = aesGcm(key, iv, aad, pt, encrypt: true);
    expect(hexOf(pt), '42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e'
        '21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091');
    expect(hexOf(t4), '5bc94fbc3221a5db94fae95ae7121a47');
    // And back.
    final t4b = aesGcm(key, iv, aad, pt, encrypt: false);
    expect(hexOf(t4b), '5bc94fbc3221a5db94fae95ae7121a47');
    expect(hexOf(pt).startsWith('d9313225'), isTrue);
  });

  final vectors = jsonDecode(File('test/core/services/remote/smb/data/crypto_vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('CCM, GCM and CMAC agree with Python cryptography, at many lengths', () {
    for (final v in (vectors['aead'] as List).cast<Map<String, dynamic>>()) {
      final key = hexBytes(v['key'] as String);
      final aad = hexBytes(v['aad'] as String);
      final len = v['seed_len'] as int;
      Uint8List plain() => v['pt'] != null
          ? hexBytes(v['pt'] as String)
          : Uint8List.fromList([for (var i = 0; i < len; i++) (i * 31 + 7) & 0xff]);
      String ctOf(Uint8List b) => v['pt'] != null ? hexOf(b) : sha256.convert(b).toString();

      final c1 = plain();
      final t1 = aesCcm(key, hexBytes(v['n11'] as String), aad, c1, encrypt: true);
      expect(ctOf(c1), v['ccm_ct'], reason: 'CCM $len');
      expect(hexOf(t1), v['ccm_tag'], reason: 'CCM tag $len');
      final t1b = aesCcm(key, hexBytes(v['n11'] as String), aad, c1, encrypt: false);
      expect(hexOf(t1b), v['ccm_tag']);
      expect(bytesEqual(c1, plain()), isTrue);

      final c2 = plain();
      final t2 = aesGcm(key, hexBytes(v['n12'] as String), aad, c2, encrypt: true);
      expect(ctOf(c2), v['gcm_ct'], reason: 'GCM $len');
      expect(hexOf(t2), v['gcm_tag'], reason: 'GCM tag $len');

      final both = concatBytes([plain(), aad]);
      expect(hexOf(aesCmac(key, both)), v['cmac'], reason: 'CMAC $len');
    }
  });

  test('the SMB 3 key derivation matches SP 800-108 as Python computes it', () {
    final sk = hexBytes('270e1ba896585eeb7af3472d3b4c75a7');
    expect(hexOf(smbKdf(sk, ascii.encode('SMB2AESCMAC\x00'), ascii.encode('SmbSign\x00'))), vectors['kdf_sign']);
    expect(
      hexOf(smbKdf(sk, ascii.encode('SMBC2SCipherKey\x00'), Uint8List.fromList(List.generate(64, (i) => i)), bits: 256)),
      vectors['kdf256'],
    );
  });

  test('RC4 and MD4 give the textbook answers', () {
    expect(hexOf(Rc4(ascii.encode('Key')).process(ascii.encode('Plaintext'))), 'bbf316e8d940af0ad3');
    expect(hexOf(md4(ascii.encode('abc'))), 'a448017aaf21d8525fc10ae87aa6729d');
  });

  test('crypto is quick enough for transfers', () {
    final data = Uint8List(4 << 20);
    final key = Uint8List(16);
    final sw = Stopwatch()..start();
    aesCmac(key, data);
    final cmac = sw.elapsedMicroseconds;
    sw.reset();
    aesGcm(key, Uint8List(12), Uint8List(32), data, encrypt: true);
    final gcm = sw.elapsedMicroseconds;
    sw.reset();
    aesCcm(key, Uint8List(11), Uint8List(32), data, encrypt: true);
    final ccm = sw.elapsedMicroseconds;
    sw.reset();
    hmacSha256(key, data);
    final hmac = sw.elapsedMicroseconds;
    double mbps(int us) => 4 / (us / 1e6);
    // ignore: avoid_print
    print('MB/s: CMAC ${mbps(cmac).toStringAsFixed(0)}, GCM ${mbps(gcm).toStringAsFixed(0)}, '
        'CCM ${mbps(ccm).toStringAsFixed(0)}, HMAC-SHA256 ${mbps(hmac).toStringAsFixed(0)}');
  });
}
