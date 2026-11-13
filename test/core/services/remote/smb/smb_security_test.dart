import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/smb/smb_bytes.dart';
import 'package:folders/core/services/remote/smb/smb_constants.dart';
import 'package:folders/core/services/remote/smb/smb_security.dart';

/// Key derivation, the three signing algorithms and the encryption
/// transform, against `data/smb_vectors.json`: made with Python's
/// pycryptodome and impacket from the formulas in MS-SMB2 3.1.4, an
/// implementation independent of this one. (Samba 4.19 accepted all of it
/// too, in the real-server tests.)
void main() {
  final v = jsonDecode(File('test/core/services/remote/smb/data/smb_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  Uint8List h(String k) => hexBytes(v[k] as String);
  final sk = hexBytes('8de40ccadbc14a82f15cb0ad0de95ca3');

  test('SMB 3.0 and 3.1.1 keys', () {
    final k30 = deriveSmbKeys(sk, dialect: SmbDialect.smb302, cipher: SmbCipher.aes128Ccm);
    expect(hexOf(k30.signing), v['k30_sign']);
    expect(hexOf(k30.encryption!), v['k30_enc']);
    expect(hexOf(k30.decryption!), v['k30_dec']);
    final k311 = deriveSmbKeys(sk, dialect: SmbDialect.smb311, cipher: SmbCipher.aes128Gcm, preauthHash: h('preauth'));
    expect(hexOf(k311.signing), v['k311_sign']);
    expect(hexOf(k311.encryption!), v['k311_enc']);
    expect(hexOf(k311.decryption!), v['k311_dec']);
    final k256 = deriveSmbKeys(sk, dialect: SmbDialect.smb311, cipher: SmbCipher.aes256Gcm, preauthHash: h('preauth'));
    expect(hexOf(k256.encryption!), v['k311_enc256']);
    // 2.x signs with the session key itself, and has no cipher.
    final k21 = deriveSmbKeys(sk, dialect: SmbDialect.smb210, cipher: 0);
    expect(k21.signing, sk);
    expect(k21.encryption, isNull);
    // No cipher agreed: no encryption keys.
    expect(deriveSmbKeys(sk, dialect: SmbDialect.smb311, cipher: 0, preauthHash: h('preauth')).encryption, isNull);
  });

  test('HMAC-SHA256, AES-CMAC and AES-GMAC signatures', () {
    final req = h('req');
    final key = h('k311_sign');
    expect(hexOf(smbSignature(req, 0, req.length, dialect: SmbDialect.smb210, algorithm: 0, key: sk)), v['sig_hmac']);
    expect(
      hexOf(smbSignature(req, 0, req.length, dialect: SmbDialect.smb311, algorithm: SmbSigningAlgorithm.aesCmac, key: key)),
      v['sig_cmac'],
    );
    for (final name in ['req', 'rep', 'cancel']) {
      final m = h(name);
      expect(
        hexOf(smbSignature(m, 0, m.length, dialect: SmbDialect.smb311, algorithm: SmbSigningAlgorithm.aesGmac, key: key)),
        v['sig_gmac_$name'],
        reason: name,
      );
    }
    // Inside a bigger buffer (as sent, after the NetBIOS length).
    final framed = concatBytes([
      [0, 0, 0, req.length],
      req,
    ]);
    expect(
      hexOf(smbSignature(framed, 4, framed.length, dialect: SmbDialect.smb300, algorithm: SmbSigningAlgorithm.aesCmac, key: key)),
      v['sig_cmac'],
    );
  });

  test('encryption transform with CCM and GCM, and back', () {
    final req = h('req');
    final key = h('k311_enc');
    for (final (name, cipher, nonce) in [
      ('ccm', SmbCipher.aes128Ccm, Uint8List.fromList(List.generate(11, (i) => i + 1))),
      ('gcm', SmbCipher.aes128Gcm, Uint8List.fromList(List.generate(12, (i) => i + 1))),
    ]) {
      final out = smbEncrypt(req, 0, req.length, cipher: cipher, key: key, nonce: nonce, sessionId: 0x4400000000000001);
      expect(out.sublist(0, 4), [0, 0, 0, 52 + req.length]);
      final frame = out.sublist(4);
      expect(hexOf(frame), v['enc_$name'], reason: name);
      final plain = smbDecrypt(Uint8List.fromList(frame), cipher: cipher, key: key);
      expect(plain, req);
      final tampered = Uint8List.fromList(frame)..[60] ^= 1;
      expect(smbDecrypt(tampered, cipher: cipher, key: key), isNull);
      final badAad = Uint8List.fromList(frame)..[44] ^= 1;
      expect(smbDecrypt(badAad, cipher: cipher, key: key), isNull);
    }
  });
}
