import 'dart:typed_data';

import 'smb_bytes.dart';

/// Just enough DER and SPNEGO (RFC 4178) to wrap NTLM for SMB2's
/// SESSION_SETUP.

/// 1.3.6.1.4.1.311.2.2.10, NTLMSSP.
final Uint8List ntlmOid = Uint8List.fromList([0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x02, 0x0a]);

/// 1.3.6.1.5.5.2, SPNEGO.
final Uint8List _spnegoOid = Uint8List.fromList([0x2b, 0x06, 0x01, 0x05, 0x05, 0x02]);

Uint8List _len(int n) {
  if (n < 0x80) return Uint8List.fromList([n]);
  if (n < 0x100) return Uint8List.fromList([0x81, n]);
  if (n < 0x10000) return Uint8List.fromList([0x82, n >> 8, n & 0xff]);
  return Uint8List.fromList([0x83, n >> 16, (n >> 8) & 0xff, n & 0xff]);
}

Uint8List derTlv(int tag, List<int> value) => concatBytes([
      [tag],
      _len(value.length),
      value,
    ]);

/// The DER of `MechTypeList ::= SEQUENCE OF MechType` with NTLMSSP alone,
/// which the mechListMIC covers.
Uint8List get ntlmMechTypeList => derTlv(0x30, derTlv(0x06, ntlmOid));

/// GSS-API InitialContextToken carrying a NegTokenInit with NTLMSSP and its
/// first token.
Uint8List spnegoInit(Uint8List mechToken) {
  final negTokenInit = derTlv(
    0x30,
    concatBytes([
      derTlv(0xa0, ntlmMechTypeList),
      derTlv(0xa2, derTlv(0x04, mechToken)),
    ]),
  );
  return derTlv(0x60, concatBytes([derTlv(0x06, _spnegoOid), derTlv(0xa0, negTokenInit)]));
}

/// A NegTokenResp with the client's next token and, optionally, mechListMIC.
Uint8List spnegoResponse(Uint8List responseToken, {Uint8List? mechListMic}) {
  final parts = <List<int>>[derTlv(0xa2, derTlv(0x04, responseToken))];
  if (mechListMic != null) parts.add(derTlv(0xa3, derTlv(0x04, mechListMic)));
  return derTlv(0xa1, derTlv(0x30, concatBytes(parts)));
}

/// What the server's NegTokenResp (or NegTokenInit hint) held.
class SpnegoToken {
  SpnegoToken({this.negState, this.supportedMech, this.responseToken, this.mechListMic, this.mechTypes = const []});

  /// 0 accept-completed, 1 accept-incomplete, 2 reject, 3 request-mic.
  final int? negState;
  final Uint8List? supportedMech;
  final Uint8List? responseToken;
  final Uint8List? mechListMic;

  /// From a NegTokenInit (the NEGOTIATE response's hint).
  final List<Uint8List> mechTypes;

  bool get offersNtlm => mechTypes.any((m) => bytesEqual(m, ntlmOid));
}

class _Tlv {
  _Tlv(this.tag, this.value);
  final int tag;
  final Uint8List value;
}

_Tlv _read(ByteReader r) {
  final tag = r.u8();
  var len = r.u8();
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    if (n == 0 || n > 4) throw const FormatException('Bad DER length');
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | r.u8();
    }
  }
  return _Tlv(tag, r.bytes(len));
}

List<_Tlv> _children(Uint8List value) {
  final r = ByteReader(value);
  final out = <_Tlv>[];
  while (r.remaining > 0) {
    out.add(_read(r));
  }
  return out;
}

/// Parses a server token: a NegTokenResp (`a1`), a NegTokenInit (`a0`), or
/// either wrapped in the GSS-API header (`60`). Raw NTLMSSP comes back as the
/// response token itself.
SpnegoToken parseSpnego(Uint8List token) {
  if (token.length >= 8 && token[0] == 0x4e && token[1] == 0x54 && token[2] == 0x4c && token[3] == 0x4d) {
    return SpnegoToken(responseToken: token);
  }
  var t = _read(ByteReader(token));
  if (t.tag == 0x60) {
    final kids = _children(t.value);
    if (kids.length < 2) throw const FormatException('Bad SPNEGO header');
    t = kids[1];
  }
  if (t.tag != 0xa0 && t.tag != 0xa1) throw const FormatException('Not SPNEGO');
  final seq = _children(t.value);
  if (seq.isEmpty || seq.first.tag != 0x30) throw const FormatException('Bad SPNEGO body');
  final fields = _children(seq.first.value);
  if (t.tag == 0xa0) {
    final mechs = <Uint8List>[];
    Uint8List? mechToken;
    for (final f in fields) {
      if (f.tag == 0xa0) {
        final list = _children(f.value);
        if (list.isNotEmpty) {
          for (final m in _children(list.first.value)) {
            if (m.tag == 0x06) mechs.add(m.value);
          }
        }
      } else if (f.tag == 0xa2) {
        mechToken = _children(f.value).first.value;
      }
    }
    return SpnegoToken(mechTypes: mechs, responseToken: mechToken);
  }
  int? state;
  Uint8List? mech, resp, mic;
  for (final f in fields) {
    final inner = _children(f.value);
    if (inner.isEmpty) continue;
    switch (f.tag) {
      case 0xa0:
        state = inner.first.value.isEmpty ? null : inner.first.value.last;
      case 0xa1:
        mech = inner.first.value;
      case 0xa2:
        resp = inner.first.value;
      case 0xa3:
        mic = inner.first.value;
    }
  }
  return SpnegoToken(negState: state, supportedMech: mech, responseToken: resp, mechListMic: mic);
}
