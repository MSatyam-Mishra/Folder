import 'dart:convert';
import 'dart:typed_data';

import 'smb_bytes.dart';
import 'smb_crypto.dart';

/// NTLMv2 authentication (MS-NLMP), the client side: NEGOTIATE, then
/// AUTHENTICATE from the server's CHALLENGE, with the MIC and key exchange.

abstract final class NtlmFlags {
  static const unicode = 0x00000001;
  static const oem = 0x00000002;
  static const requestTarget = 0x00000004;
  static const sign = 0x00000010;
  static const seal = 0x00000020;
  static const ntlm = 0x00000200;
  static const anonymous = 0x00000800;
  static const alwaysSign = 0x00008000;
  static const extendedSessionSecurity = 0x00080000;
  static const targetInfo = 0x00800000;
  static const version = 0x02000000;
  static const n128 = 0x20000000;
  static const keyExchange = 0x40000000;
  static const n56 = 0x80000000;
}

abstract final class AvId {
  static const eol = 0;
  static const nbComputerName = 1;
  static const nbDomainName = 2;
  static const dnsComputerName = 3;
  static const dnsDomainName = 4;
  static const dnsTreeName = 5;
  static const flags = 6;
  static const timestamp = 7;
  static const singleHost = 8;
  static const targetName = 9;
  static const channelBindings = 10;
}

final Uint8List _signature = Uint8List.fromList(ascii.encode('NTLMSSP\x00'));

/// The server's CHALLENGE_MESSAGE.
class NtlmChallenge {
  NtlmChallenge._(this.raw, this.flags, this.serverChallenge, this.targetInfo, this.targetName);

  final Uint8List raw;
  final int flags;
  final Uint8List serverChallenge;
  final Uint8List targetInfo;
  final String targetName;

  static NtlmChallenge parse(Uint8List raw) {
    if (raw.length < 32 || !bytesEqual(raw.sublist(0, 8), _signature) || le32(raw, 8) != 2) {
      throw const FormatException('Not an NTLM challenge');
    }
    final r = ByteReader(raw, 12);
    final nameLen = r.u16();
    r.u16();
    final nameOff = r.u32();
    final flags = r.u32();
    final challenge = Uint8List.fromList(r.bytes(8));
    r.skip(8);
    var info = Uint8List(0);
    if (raw.length >= 48) {
      final infoLen = r.u16();
      r.u16();
      final infoOff = r.u32();
      if (infoLen > 0 && infoOff + infoLen <= raw.length) {
        info = Uint8List.fromList(raw.sublist(infoOff, infoOff + infoLen));
      }
    }
    var name = '';
    if (nameLen > 0 && nameOff + nameLen <= raw.length) {
      name = (flags & NtlmFlags.unicode) != 0
          ? fromUtf16le(raw, nameOff, nameOff + nameLen)
          : latin1.decode(raw.sublist(nameOff, nameOff + nameLen));
    }
    return NtlmChallenge._(raw, flags, challenge, info, name);
  }

  /// The AV pairs, in order, without the EOL.
  List<(int, Uint8List)> get avPairs => parseAvPairs(targetInfo);

  Uint8List? av(int id) {
    for (final (k, v) in avPairs) {
      if (k == id) return v;
    }
    return null;
  }
}

List<(int, Uint8List)> parseAvPairs(Uint8List info) {
  final out = <(int, Uint8List)>[];
  var o = 0;
  while (o + 4 <= info.length) {
    final id = le16(info, o);
    final len = le16(info, o + 2);
    if (id == AvId.eol || o + 4 + len > info.length) break;
    out.add((id, Uint8List.fromList(info.sublist(o + 4, o + 4 + len))));
    o += 4 + len;
  }
  return out;
}

Uint8List encodeAvPairs(List<(int, Uint8List)> pairs) {
  final w = ByteWriter();
  for (final (id, v) in pairs) {
    w
      ..u16(id)
      ..u16(v.length)
      ..bytes(v);
  }
  w
    ..u16(AvId.eol)
    ..u16(0);
  return w.toBytes();
}

/// `NTOWFv2`: HMAC-MD5 of MD4(password) over upper-case user plus domain.
Uint8List ntowfV2(String password, String user, String domain) =>
    hmacMd5(md4(utf16le(password)), utf16le(user.toUpperCase() + domain));

/// What one NTLMv2 exchange produced.
class NtlmResult {
  NtlmResult(this.message, this.sessionKey, this.anonymous);

  /// The AUTHENTICATE_MESSAGE.
  final Uint8List message;

  /// ExportedSessionKey: SMB's session key. Empty for anonymous.
  final Uint8List sessionKey;
  final bool anonymous;
}

/// One NTLM client exchange. Empty [user] means anonymous.
class NtlmClient {
  NtlmClient({
    required this.user,
    required this.password,
    this.domain = '',
    this.workstation = '',
    this.spn,
    this.channelBindings = true,
  });

  final String user;
  final String password;
  final String domain;
  final String workstation;

  /// `cifs/host`, put in the AV pairs as the target name.
  final String? spn;

  /// Adds an all-zero channel binding hash, as Windows does without TLS.
  final bool channelBindings;

  bool get isAnonymous => user.isEmpty && password.isEmpty;

  Uint8List? _negotiate;
  int _flags = 0;

  /// For tests: fixed values instead of random ones and the clock.
  Uint8List? testClientChallenge;
  Uint8List? testSessionKey;
  int? testTime;

  /// The first message.
  Uint8List negotiate() {
    var flags = NtlmFlags.unicode |
        NtlmFlags.oem |
        NtlmFlags.requestTarget |
        NtlmFlags.sign |
        NtlmFlags.ntlm |
        NtlmFlags.alwaysSign |
        NtlmFlags.extendedSessionSecurity |
        NtlmFlags.targetInfo |
        NtlmFlags.version |
        NtlmFlags.n128 |
        NtlmFlags.keyExchange |
        NtlmFlags.n56;
    if (isAnonymous) flags |= NtlmFlags.anonymous;
    _flags = flags;
    final w = ByteWriter(40)
      ..bytes(_signature)
      ..u32(1)
      ..u32(flags)
      ..u16(0) // domain
      ..u16(0)
      ..u32(40)
      ..u16(0) // workstation
      ..u16(0)
      ..u32(40)
      ..bytes(_version);
    return _negotiate = Uint8List.fromList(w.toBytes());
  }

  /// Windows 10's version block: 10.0 build 19041, NTLM revision 15.
  static final Uint8List _version = Uint8List.fromList([10, 0, 0x61, 0x4a, 0, 0, 0, 15]);

  /// The third message, from the server's [challengeBytes].
  NtlmResult authenticate(Uint8List challengeBytes) {
    final negotiate = _negotiate ?? this.negotiate();
    final challenge = NtlmChallenge.parse(challengeBytes);
    final unicode = (challenge.flags & NtlmFlags.unicode) != 0;
    // Agree on the flags both sides have.
    var flags = challenge.flags & _flags;
    flags |= NtlmFlags.ntlm | (unicode ? NtlmFlags.unicode : NtlmFlags.oem);
    if ((flags & NtlmFlags.unicode) != 0) flags &= ~NtlmFlags.oem;
    if (isAnonymous) flags |= NtlmFlags.anonymous;

    Uint8List str(String s) => unicode ? utf16le(s) : Uint8List.fromList(latin1.encode(s));

    Uint8List lm;
    Uint8List nt;
    Uint8List exported;
    Uint8List encryptedKey = Uint8List(0);
    var withMic = false;

    if (isAnonymous) {
      lm = Uint8List(1);
      nt = Uint8List(0);
      exported = Uint8List(0);
      flags &= ~NtlmFlags.keyExchange;
    } else {
      final key = ntowfV2(password, user, domain);
      final clientChallenge = testClientChallenge ?? randomBytes(8);
      final serverTime = challenge.av(AvId.timestamp);
      final time = testTime ?? (serverTime != null ? le64(serverTime, 0) : toFileTime(DateTime.now()));
      // The AV pairs we answer with: the server's, plus flags (MIC), target name
      // and channel bindings when the server sent a timestamp.
      final pairs = [...challenge.avPairs];
      if (serverTime != null) {
        withMic = true;
        final i = pairs.indexWhere((p) => p.$1 == AvId.flags);
        final old = i >= 0 ? le32(pairs[i].$2, 0) : 0;
        final f = Uint8List(4);
        setLe32(f, 0, old | 0x2);
        if (i >= 0) {
          pairs[i] = (AvId.flags, f);
        } else {
          pairs.add((AvId.flags, f));
        }
        if (channelBindings && !pairs.any((p) => p.$1 == AvId.channelBindings)) {
          pairs.add((AvId.channelBindings, Uint8List(16)));
        }
        if (spn != null && !pairs.any((p) => p.$1 == AvId.targetName)) {
          pairs.add((AvId.targetName, utf16le(spn!)));
        }
      }
      final temp = ByteWriter()
        ..u8(1)
        ..u8(1)
        ..zeros(6)
        ..u64(time)
        ..bytes(clientChallenge)
        ..zeros(4)
        ..bytes(serverTime != null ? encodeAvPairs(pairs) : challenge.targetInfo)
        ..zeros(4);
      final tempBytes = Uint8List.fromList(temp.toBytes());
      final proof = hmacMd5(key, concatBytes([challenge.serverChallenge, tempBytes]));
      nt = concatBytes([proof, tempBytes]);
      lm = withMic
          ? Uint8List(24)
          : concatBytes([hmacMd5(key, concatBytes([challenge.serverChallenge, clientChallenge])), clientChallenge]);
      final sessionBaseKey = hmacMd5(key, proof);
      if ((flags & NtlmFlags.keyExchange) != 0) {
        exported = testSessionKey ?? randomBytes(16);
        encryptedKey = Rc4(sessionBaseKey).process(exported);
      } else {
        exported = sessionBaseKey;
      }
    }

    final domainB = str(isAnonymous ? '' : domain);
    final userB = str(user);
    final wsB = str(workstation);
    const headerLen = 88; // with version and MIC
    final w = ByteWriter(headerLen + lm.length + nt.length + domainB.length + userB.length + wsB.length + 16);
    var off = headerLen;
    void field(Uint8List b) {
      w
        ..u16(b.length)
        ..u16(b.length)
        ..u32(off);
      off += b.length;
    }

    w
      ..bytes(_signature)
      ..u32(3);
    field(lm);
    field(nt);
    field(domainB);
    field(userB);
    field(wsB);
    field(encryptedKey);
    w
      ..u32(flags)
      ..bytes(_version)
      ..zeros(16) // MIC
      ..bytes(lm)
      ..bytes(nt)
      ..bytes(domainB)
      ..bytes(userB)
      ..bytes(wsB)
      ..bytes(encryptedKey);
    final message = Uint8List.fromList(w.toBytes());
    if (withMic) {
      final mic = hmacMd5(exported, concatBytes([negotiate, challengeBytes, message]));
      message.setRange(72, 88, mic);
    }
    _negotiatedFlags = flags;
    _exportedKey = exported;
    _sentMic = withMic;
    return NtlmResult(message, exported, isAnonymous);
  }

  int _negotiatedFlags = 0;
  Uint8List _exportedKey = Uint8List(0);
  bool _sentMic = false;

  /// Whether the AUTHENTICATE carried a MIC, which makes SPNEGO want a
  /// mechListMIC too.
  bool get sentMic => _sentMic;

  /// GSS_GetMIC over [message] with sequence number [seq], client to server
  /// (MS-NLMP 3.4.4.2, extended session security), for SPNEGO's mechListMIC.
  Uint8List sign(Uint8List message, {int seq = 0}) {
    final key = _exportedKey;
    final signKey = md5(concatBytes([key, ascii.encode('session key to client-to-server signing key magic constant\x00')]));
    var sealBase = key;
    if ((_negotiatedFlags & NtlmFlags.n128) == 0) {
      sealBase = key.sublist(0, (_negotiatedFlags & NtlmFlags.n56) != 0 ? 7 : 5);
    }
    final sealKey = md5(concatBytes([sealBase, ascii.encode('session key to client-to-server sealing key magic constant\x00')]));
    final seqB = Uint8List(4);
    setLe32(seqB, 0, seq);
    var checksum = hmacMd5(signKey, concatBytes([seqB, message])).sublist(0, 8);
    if ((_negotiatedFlags & NtlmFlags.keyExchange) != 0) {
      checksum = Rc4(sealKey).process(checksum);
    }
    final out = ByteWriter(16)
      ..u32(1)
      ..bytes(checksum)
      ..bytes(seqB);
    return Uint8List.fromList(out.toBytes());
  }
}
