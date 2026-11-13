import 'dart:convert';
import 'dart:typed_data';

import 'smb_bytes.dart';
import 'smb_constants.dart';
import 'smb_crypto.dart';

/// SMB2/3 message signing, key derivation and the encryption transform
/// (MS-SMB2 3.1.4), as plain functions.

class SmbKeys {
  const SmbKeys(this.signing, this.encryption, this.decryption);

  final Uint8List signing;

  /// Client to server, and server to client; null without a cipher.
  final Uint8List? encryption;
  final Uint8List? decryption;
}

/// The keys of a session from its [sessionKey] (NTLM's ExportedSessionKey).
SmbKeys deriveSmbKeys(Uint8List sessionKey, {required int dialect, required int cipher, Uint8List? preauthHash}) {
  final sk = sessionKey.length > 16 ? Uint8List.sublistView(sessionKey, 0, 16) : sessionKey;
  if (dialect < SmbDialect.smb300) return SmbKeys(sk, null, null);
  final bits = SmbCipher.keyBits(cipher);
  if (dialect == SmbDialect.smb311) {
    final h = preauthHash!;
    return SmbKeys(
      smbKdf(sk, ascii.encode('SMBSigningKey\x00'), h),
      cipher == 0 ? null : smbKdf(sessionKey, ascii.encode('SMBC2SCipherKey\x00'), h, bits: bits),
      cipher == 0 ? null : smbKdf(sessionKey, ascii.encode('SMBS2CCipherKey\x00'), h, bits: bits),
    );
  }
  return SmbKeys(
    smbKdf(sk, ascii.encode('SMB2AESCMAC\x00'), ascii.encode('SmbSign\x00')),
    cipher == 0 ? null : smbKdf(sk, ascii.encode('SMB2AESCCM\x00'), ascii.encode('ServerIn \x00')),
    cipher == 0 ? null : smbKdf(sk, ascii.encode('SMB2AESCCM\x00'), ascii.encode('ServerOut\x00')),
  );
}

/// The 16-byte signature of the SMB2 message at [start]..[end] of [buf],
/// whose signature field must be zero: HMAC-SHA256 on 2.x, AES-CMAC on 3.x,
/// AES-GMAC on 3.1.1 when negotiated (nonce: MessageId, then a byte with 1
/// for a reply and 2 for CANCEL).
Uint8List smbSignature(
  Uint8List buf,
  int start,
  int end, {
  required int dialect,
  required int algorithm,
  required Uint8List key,
  AesCmac? cmac,
}) {
  if (dialect < SmbDialect.smb300) {
    return hmacSha256(key, Uint8List.sublistView(buf, start, end)).sublist(0, 16);
  }
  if (algorithm == SmbSigningAlgorithm.aesGmac) {
    final nonce = Uint8List(12)..setRange(0, 8, buf, start + 24);
    final flags = le32(buf, start + 16);
    final command = le16(buf, start + 12);
    nonce[8] = ((flags & SmbFlags.serverToRedir) != 0 ? 1 : 0) | (command == SmbCommand.cancel ? 2 : 0);
    return aesGmac(key, nonce, Uint8List.sublistView(buf, start, end));
  }
  return (cmac ?? AesCmac(key)).mac(buf, start, end);
}

/// The TRANSFORM_HEADER message, NetBIOS length first, carrying the SMB2
/// message at [start]..[end] of [buf] encrypted with [key] and [nonce]
/// (11 bytes for CCM, 12 for GCM).
Uint8List smbEncrypt(Uint8List buf, int start, int end, {required int cipher, required Uint8List key, required Uint8List nonce, required int sessionId}) {
  final len = end - start;
  final out = Uint8List(4 + 52 + len);
  final total = 52 + len;
  out[1] = (total >> 16) & 0xff;
  out[2] = (total >> 8) & 0xff;
  out[3] = total & 0xff;
  out.setAll(4, const [0xfd, 0x53, 0x4d, 0x42]);
  out.setRange(4 + 20, 4 + 20 + nonce.length, nonce);
  setLe32(out, 4 + 36, len);
  setLe16(out, 4 + 42, 1);
  setLe64(out, 4 + 44, sessionId);
  out.setRange(56, 56 + len, buf, start);
  final aad = Uint8List.fromList(Uint8List.sublistView(out, 4 + 20, 4 + 52));
  final tag = SmbCipher.isGcm(cipher)
      ? aesGcm(key, nonce, aad, out, encrypt: true, start: 56)
      : aesCcm(key, nonce, aad, out, encrypt: true, start: 56);
  out.setRange(4 + 4, 4 + 20, tag);
  return out;
}

/// The plain SMB2 message(s) in the TRANSFORM_HEADER [frame] (no NetBIOS
/// length), decrypted in place; null when the check fails.
Uint8List? smbDecrypt(Uint8List frame, {required int cipher, required Uint8List key}) {
  final gcm = SmbCipher.isGcm(cipher);
  final size = le32(frame, 36);
  if (frame.length < 52 || 52 + size > frame.length) return null;
  final nonce = Uint8List.fromList(frame.sublist(20, 20 + (gcm ? 12 : 11)));
  final aad = Uint8List.fromList(frame.sublist(20, 52));
  final data = Uint8List.sublistView(frame, 52, 52 + size);
  final tag = gcm ? aesGcm(key, nonce, aad, data, encrypt: false) : aesCcm(key, nonce, aad, data, encrypt: false);
  return bytesEqual(tag, frame.sublist(4, 20)) ? data : null;
}
