import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/smb/ntlm.dart';
import 'package:folders/core/services/remote/smb/smb_bytes.dart';
import 'package:folders/core/services/remote/smb/smb_crypto.dart';
import 'package:folders/core/services/remote/smb/spnego.dart';

/// NTLMv2 against MS-NLMP 4.2.4 (user "User", domain "Domain", password
/// "Password", server challenge 0123456789abcdef, client challenge aa..aa,
/// time 0, random session key 55..55), and the mechListMIC as impacket
/// computes it.
void main() {
  const allFlags = NtlmFlags.unicode |
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

  Uint8List challenge({required int flags, required List<(int, Uint8List)> av}) {
    final name = utf16le('Server');
    final info = encodeAvPairs(av);
    final w = ByteWriter()
      ..bytes(ascii.encode('NTLMSSP\x00'))
      ..u32(2)
      ..u16(name.length)
      ..u16(name.length)
      ..u32(56)
      ..u32(flags)
      ..bytes(hexBytes('0123456789abcdef'))
      ..zeros(8)
      ..u16(info.length)
      ..u16(info.length)
      ..u32(56 + name.length)
      ..bytes([6, 0, 0x70, 0x17, 0, 0, 0, 15])
      ..bytes(name)
      ..bytes(info);
    return Uint8List.fromList(w.toBytes());
  }

  Uint8List field(Uint8List msg, int at) {
    final len = le16(msg, at);
    final off = le32(msg, at + 4);
    return msg.sublist(off, off + len);
  }

  final specPairs = [(AvId.nbDomainName, utf16le('Domain')), (AvId.nbComputerName, utf16le('Server'))];

  NtlmClient client() => NtlmClient(user: 'User', password: 'Password', domain: 'Domain', workstation: 'COMPUTER')
    ..testClientChallenge = Uint8List.fromList(List.filled(8, 0xaa))
    ..testSessionKey = Uint8List.fromList(List.filled(16, 0x55))
    ..testTime = 0;

  test('NTOWFv2 matches MS-NLMP 4.2.4.1.1', () {
    expect(hexOf(ntowfV2('Password', 'User', 'Domain')), '0c868a403bfd7a93a3001ef22ef02e3f');
  });

  test('the AUTHENTICATE message matches MS-NLMP 4.2.4', () {
    final c = client();
    final neg = c.negotiate();
    expect(neg.sublist(0, 8), ascii.encode('NTLMSSP\x00'));
    expect(le32(neg, 8), 1);
    final chal = challenge(flags: allFlags, av: specPairs);
    final result = c.authenticate(chal);
    final msg = result.message;
    expect(le32(msg, 8), 3);
    final lm = field(msg, 12);
    final nt = field(msg, 20);
    expect(hexOf(lm), '86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa');
    expect(hexOf(nt.sublist(0, 16)), '68cd0ab851e51c96aabc927bebef6a1c');
    // The rest of the NT response is the temp blob with the server's pairs.
    expect(
      hexOf(nt.sublist(16)),
      '0101000000000000' '0000000000000000' 'aaaaaaaaaaaaaaaa' '00000000' '${hexOf(encodeAvPairs(specPairs))}' '00000000',
    );
    expect(fromUtf16le(field(msg, 28)), 'Domain');
    expect(fromUtf16le(field(msg, 36)), 'User');
    expect(fromUtf16le(field(msg, 44)), 'COMPUTER');
    // Session base key 8de40cca... encrypts the random session key (4.2.4.2.3).
    expect(hexOf(field(msg, 52)), 'c5dad2544fc9799094ce1ce90bc9d03e');
    expect(hexOf(result.sessionKey), '55555555555555555555555555555555');
    expect(le32(msg, 60) & NtlmFlags.keyExchange, isNonZero);
    // No timestamp from the server: no MIC.
    expect(msg.sublist(72, 88).every((b) => b == 0), isTrue);
    expect(c.sentMic, isFalse);
  });

  test('without key exchange the session key is the session base key', () {
    final c = client();
    c.negotiate();
    final r = c.authenticate(challenge(flags: allFlags & ~NtlmFlags.keyExchange, av: specPairs));
    expect(hexOf(r.sessionKey), '8de40ccadbc14a82f15cb0ad0de95ca3');
    expect(field(r.message, 52), isEmpty);
  });

  test('with a server timestamp: MIC, zero LM response, and the extra pairs', () {
    final ts = Uint8List(8);
    setLe64(ts, 0, toFileTime(DateTime.utc(2026, 11, 13)));
    final pairs = [...specPairs, (AvId.timestamp, ts)];
    final c = NtlmClient(user: 'User', password: 'Password', domain: 'Domain', spn: 'cifs/server')
      ..testClientChallenge = Uint8List.fromList(List.filled(8, 0xaa))
      ..testSessionKey = Uint8List.fromList(List.filled(16, 0x55));
    final neg = c.negotiate();
    final chal = challenge(flags: allFlags, av: pairs);
    final r = c.authenticate(chal);
    final msg = r.message;
    expect(field(msg, 12), List.filled(24, 0));
    expect(c.sentMic, isTrue);
    final nt = field(msg, 20);
    expect(le64(nt, 24), le64(ts, 0), reason: 'the server\'s time is used');
    final sent = parseAvPairs(nt.sublist(16 + 28));
    final flags = sent.firstWhere((p) => p.$1 == AvId.flags).$2;
    expect(le32(flags, 0) & 2, 2);
    expect(sent.any((p) => p.$1 == AvId.channelBindings), isTrue);
    expect(fromUtf16le(sent.firstWhere((p) => p.$1 == AvId.targetName).$2), 'cifs/server');
    final zeroed = Uint8List.fromList(msg)..fillRange(72, 88, 0);
    final mic = hmacMd5(r.sessionKey, concatBytes([neg, chal, zeroed]));
    expect(msg.sublist(72, 88), mic);
  });

  test('anonymous: empty responses, no key', () {
    final c = NtlmClient(user: '', password: '');
    c.negotiate();
    final r = c.authenticate(challenge(flags: allFlags, av: specPairs));
    expect(r.anonymous, isTrue);
    expect(field(r.message, 20), isEmpty);
    expect(field(r.message, 12), [0]);
    expect(r.sessionKey, isEmpty);
    expect(le32(r.message, 60) & NtlmFlags.anonymous, isNonZero);
  });

  test('mechListMIC matches impacket\'s NTLM SIGN', () {
    final c = NtlmClient(user: 'u', password: 'p')..testSessionKey = Uint8List.fromList(List.generate(16, (i) => i));
    c.negotiate();
    c.authenticate(challenge(
      flags: NtlmFlags.extendedSessionSecurity | NtlmFlags.keyExchange | NtlmFlags.n128 | NtlmFlags.sign | NtlmFlags.unicode | NtlmFlags.ntlm,
      av: specPairs,
    ));
    expect(hexOf(ntlmMechTypeList), '300c060a2b06010401823702020a');
    expect(hexOf(c.sign(ntlmMechTypeList)), '010000003de8df789a511c4500000000');
  });

  test('SPNEGO wraps and unwraps', () {
    final token = Uint8List.fromList(List.generate(300, (i) => i & 0xff));
    final init = spnegoInit(token);
    expect(init[0], 0x60);
    final parsed = parseSpnego(init);
    expect(parsed.offersNtlm, isTrue);
    expect(parsed.responseToken, token);

    final resp = spnegoResponse(token, mechListMic: Uint8List.fromList([1, 2, 3]));
    final back = parseSpnego(resp);
    expect(back.responseToken, token);
    expect(back.mechListMic, [1, 2, 3]);

    // A server's accept-incomplete reply with its CHALLENGE.
    final chal = Uint8List.fromList(ascii.encode('NTLMSSP\x00') + List.filled(40, 7));
    final server = derTlv(
      0xa1,
      derTlv(0x30, concatBytes([derTlv(0xa0, derTlv(0x0a, [1])), derTlv(0xa1, derTlv(0x06, ntlmOid)), derTlv(0xa2, derTlv(0x04, chal))])),
    );
    final s = parseSpnego(server);
    expect(s.negState, 1);
    expect(s.supportedMech, ntlmOid);
    expect(s.responseToken, chal);
    // Raw NTLMSSP passes through.
    expect(parseSpnego(chal).responseToken, chal);
  });
}
