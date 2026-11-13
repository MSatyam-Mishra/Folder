import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/smb/smb_bytes.dart';
import 'package:folders/core/services/remote/smb/smb_connection.dart';
import 'package:folders/core/services/remote/smb/smb_constants.dart';
import 'package:folders/core/services/remote/smb/smb_discovery.dart';
import 'package:folders/core/services/remote/smb/smb_errors.dart';
import 'package:folders/core/services/remote/smb/smb_rpc.dart';

/// DCE/RPC share lists, discovery replies (mDNS, NetBIOS, WS-Discovery) and
/// the plain words errors turn into.
void main() {
  group('srvsvc', () {
    test('bind and request PDUs', () {
      final bind = Rpc.bind(1);
      expect(bind.length, 72);
      expect(le16(bind, 8), 72);
      expect(bind.sublist(0, 4), [5, 0, 11, 3]);
      // srvsvc's UUID in wire order, version 3.0.
      expect(hexOf(bind.sublist(32, 52)), 'c84f324b7016d30112785a47bf6ee18803000000');
      final req = Rpc.request(2, 15, Uint8List.fromList([1, 2, 3, 4]));
      expect(req[2], 0);
      expect(le16(req, 8), 28);
      expect(le32(req, 16), 4);
      expect(le16(req, 22), 15);
      final stub = Rpc.netShareEnumRequest('nas');
      // Server name: referent, max 6, offset 0, actual 6, "\\nas" + NUL, padded.
      expect(le32(stub, 4), 6);
      expect(le32(stub, 12), 6);
      expect(fromUtf16le(stub, 16, 28, true), r'\\nas');
      expect(le32(stub, 28), 1, reason: 'level 1 after 4-byte padding');
    });

    test('bind_ack: accepted and refused', () {
      Uint8List ack(int result) {
        final w = ByteWriter()
          ..bytes([5, 0, 12, 3, 0x10, 0, 0, 0])
          ..u16(0)
          ..u16(0)
          ..u32(1)
          ..u16(4280)
          ..u16(4280)
          ..u32(0x1234)
          ..u16(13)
          ..bytes(ascii.encode('\\PIPE\\srvsvc\x00'));
        w.align(4);
        w
          ..u8(1)
          ..zeros(3)
          ..u16(result)
          ..u16(0)
          ..zeros(20);
        final b = Uint8List.fromList(w.toBytes());
        setLe16(b, 8, b.length);
        return b;
      }

      expect(Rpc.parseBindAck(ack(0)), 4280);
      expect(() => Rpc.parseBindAck(ack(2)), throwsA(isA<RpcException>()));
    });

    test('NetrShareEnum reply, with odd-length names and a split reply', () {
      final shares = [('Public', 0, 'Everyone'), (r'IPC$', 0x80000003, 'IPC Service'), ('Photos 2026', 0, ''), (r'C$', 0x80000000, 'Default share')];
      final w = ByteWriter()
        ..u32(1)
        ..u32(1)
        ..u32(0x20000)
        ..u32(shares.length)
        ..u32(0x20004)
        ..u32(shares.length);
      var ref = 0x20008;
      for (final (_, type, _) in shares) {
        w
          ..u32(ref++)
          ..u32(type)
          ..u32(ref++);
      }
      void str(String s) {
        final z = '$s\x00';
        w
          ..u32(z.length)
          ..u32(0)
          ..u32(z.length)
          ..bytes(utf16le(z));
        w.align(4);
      }

      for (final (name, _, remark) in shares) {
        str(name);
        str(remark);
      }
      w
        ..u32(shares.length)
        ..u32(0)
        ..u32(0);
      final stub = Uint8List.fromList(w.toBytes());
      Uint8List frag(Uint8List body, int flags) {
        final f = ByteWriter()
          ..bytes([5, 0, 2, flags, 0x10, 0, 0, 0])
          ..u16(24 + body.length)
          ..u16(0)
          ..u32(2)
          ..u32(body.length)
          ..u16(0)
          ..u16(0)
          ..bytes(body);
        return Uint8List.fromList(f.toBytes());
      }

      final joined = Rpc.stubOf([frag(stub.sublist(0, 50), 1), frag(stub.sublist(50), 2)]);
      final parsed = Rpc.parseNetShareEnum(joined);
      expect(parsed.map((s) => s.name), ['Public', r'IPC$', 'Photos 2026', r'C$']);
      expect(parsed.map((s) => s.remark), ['Everyone', 'IPC Service', '', 'Default share']);
      expect(parsed.where((s) => s.isDisk && !s.isSpecial).map((s) => s.name), ['Public', 'Photos 2026']);
    });

    test('an RPC fault is an error', () {
      final f = Uint8List(32)
        ..setAll(0, [5, 0, 3, 3, 0x10, 0, 0, 0]);
      setLe16(f, 8, 32);
      setLe32(f, 24, 5);
      expect(() => Rpc.stubOf([f]), throwsA(isA<RpcException>()));
    });
  });

  group('discovery', () {
    Uint8List name(List<String> labels) {
      final w = ByteWriter();
      for (final l in labels) {
        final b = utf8.encode(l);
        w
          ..u8(b.length)
          ..bytes(b);
      }
      w.u8(0);
      return Uint8List.fromList(w.toBytes());
    }

    test('mDNS: PTR, SRV and A, with compression, become a host', () {
      final w = ByteWriter()
        ..u16be(0)
        ..u16be(0x8400)
        ..u16be(0)
        ..u16be(1)
        ..u16be(0)
        ..u16be(2);
      final serviceAt = w.length;
      w
        ..bytes(name(['_smb', '_tcp', 'local']))
        ..u16be(12)
        ..u16be(1)
        ..u32be(10);
      final instance = ByteWriter()
        ..u8(13)
        ..bytes(utf8.encode("Satyam's Mac"))
        ..u8(0xc0)
        ..u8(serviceAt);
      // "Satyam's Mac" is 12 bytes; fix the label length.
      final inst = Uint8List.fromList(instance.toBytes())..[0] = 12;
      w
        ..u16be(inst.length)
        ..bytes(inst);
      final instanceAt = w.length - inst.length;
      // SRV for the instance (a pointer to it), target mac.local, port 445.
      w
        ..u8(0xc0)
        ..u8(instanceAt)
        ..u16be(33)
        ..u16be(0x8001)
        ..u32be(10);
      final target = name(['mac', 'local']);
      w
        ..u16be(6 + target.length)
        ..u16be(0)
        ..u16be(0)
        ..u16be(445)
        ..bytes(target);
      w
        ..bytes(target)
        ..u16be(1)
        ..u16be(0x8001)
        ..u32be(10)
        ..u16be(4)
        ..bytes([192, 168, 1, 23]);
      final browser = MdnsSmbBrowser();
      final ask = browser.add(Uint8List.fromList(w.toBytes()));
      expect(ask, isEmpty);
      expect(browser.hosts.length, 1);
      final h = browser.hosts.single;
      expect(h.name, "Satyam's Mac");
      expect(h.address.address, '192.168.1.23');
      expect(h.port, 445);
    });

    test('mDNS: a PTR alone makes it ask for the SRV', () {
      final w = ByteWriter()
        ..u16be(0)
        ..u16be(0x8400)
        ..u16be(0)
        ..u16be(1)
        ..u16be(0)
        ..u16be(0)
        ..bytes(name(['_smb', '_tcp', 'local']))
        ..u16be(12)
        ..u16be(1)
        ..u32be(10);
      final target = name(['NAS', '_smb', '_tcp', 'local']);
      w
        ..u16be(target.length)
        ..bytes(target);
      final browser = MdnsSmbBrowser();
      expect(browser.add(Uint8List.fromList(w.toBytes())), [('nas._smb._tcp.local', 33)]);
      expect(browser.hosts, isEmpty);
    });

    test('NetBIOS names: encoding, node status and name replies', () {
      expect(String.fromCharCodes(netbiosEncodeName('*', 0).sublist(1, 33)), 'CK${'A' * 30}');
      expect(String.fromCharCodes(netbiosEncodeName('foo', 0x20).sublist(1, 33)), 'EGEPEP${'CA' * 13}');

      Uint8List status(List<(String, int, int)> names) {
        final w = ByteWriter()
          ..u16be(0x4e42)
          ..u16be(0x8400)
          ..u16be(0)
          ..u16be(1)
          ..u16be(0)
          ..u16be(0)
          ..bytes(netbiosEncodeName('*', 0))
          ..u16be(0x21)
          ..u16be(1)
          ..u32be(0)
          ..u16be(1 + 18 * names.length + 46)
          ..u8(names.length);
        for (final (n, suffix, flags) in names) {
          w
            ..bytes(latin1.encode(n.padRight(15)))
            ..u8(suffix)
            ..u16be(flags);
        }
        w.zeros(46);
        return Uint8List.fromList(w.toBytes());
      }

      final server = status([('WORKGROUP', 0x00, 0x8400), ('DESKTOP-ABC', 0x00, 0x0400), ('DESKTOP-ABC', 0x20, 0x0400)]);
      expect(parseNbstat(server), 'DESKTOP-ABC');
      final workstation = status([('LAPTOP', 0x00, 0x0400)]);
      expect(parseNbstat(workstation), '');
      expect(parseNbstat(workstation, serverOnly: false), 'LAPTOP');

      final reply = ByteWriter()
        ..u16be(0x4e44)
        ..u16be(0x8500)
        ..u16be(0)
        ..u16be(1)
        ..u16be(0)
        ..u16be(0)
        ..bytes(netbiosEncodeName('NAS', 0x20))
        ..u16be(0x20)
        ..u16be(1)
        ..u32be(300)
        ..u16be(6)
        ..u16be(0)
        ..bytes([10, 0, 0, 7]);
      expect(parseNbNameReply(Uint8List.fromList(reply.toBytes()))?.address, '10.0.0.7');
    });

    test('WS-Discovery: probe, match and the computer name', () {
      final probe = wsdProbe('1234');
      expect(probe, contains('<wsd:Types>wsdp:Device</wsd:Types>'));
      const match = '<?xml version="1.0" encoding="utf-8" ?><soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
          'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
          'xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof" xmlns:pub="http://schemas.microsoft.com/windows/pub/2005/07">'
          '<soap:Header><wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action></soap:Header>'
          '<soap:Body><wsd:ProbeMatches><wsd:ProbeMatch><wsa:EndpointReference><wsa:Address>urn:uuid:9c3e-1</wsa:Address>'
          '</wsa:EndpointReference><wsd:Types>wsdp:Device pub:Computer</wsd:Types>'
          '<wsd:XAddrs>http://192.168.1.10:5357/9c3e-1/ http://[fe80::1]:5357/9c3e-1/</wsd:XAddrs>'
          '<wsd:MetadataVersion>2</wsd:MetadataVersion></wsd:ProbeMatch></wsd:ProbeMatches></soap:Body></soap:Envelope>';
      final m = parseProbeMatch(match)!;
      expect(m.$1, 'urn:uuid:9c3e-1');
      expect(m.$2, contains('Computer'));
      expect(m.$3, 'http://192.168.1.10:5357/9c3e-1/');
      expect(parseProbeMatch('<x/>'), isNull);
      expect(parseWsdComputer('<a><pub:Computer>DESKTOP-ABC/Workgroup:WORKGROUP</pub:Computer></a>'), 'DESKTOP-ABC');
      expect(parseWsdComputer('<a><wsdp:FriendlyName>NAS box</wsdp:FriendlyName></a>'), 'NAS box');
    });

    test('a literal address resolves to itself', () async {
      expect((await resolveSmbHost('192.168.1.5'))?.address, '192.168.1.5');
      expect((await resolveSmbHost('localhost'))?.isLoopback, isTrue);
    });

    test('finds servers on this network (EXPLORER_SMB_DISCOVER=1)', () async {
      final found = await discoverSmbHosts(timeout: const Duration(seconds: 5)).toList();
      // ignore: avoid_print
      print('found: ${found.join('\n')}');
      expect(found.map((h) => h.address.address).toSet().length, found.length);
    }, skip: Platform.environment['EXPLORER_SMB_DISCOVER'] == null ? 'set EXPLORER_SMB_DISCOVER=1' : false);
  });

  group('errors', () {
    RemoteException err(int status, [int command = SmbCommand.create, bool guest = false]) =>
        smbError(SmbStatusException(status, command, 'Public'), host: 'nas', guest: guest);

    test('statuses become kinds with plain words', () {
      expect(err(NtStatus.logonFailure, SmbCommand.sessionSetup).kind, RemoteErrorKind.auth);
      expect(err(NtStatus.logonFailure, SmbCommand.sessionSetup).message, 'The user name or password was refused.');
      expect(err(NtStatus.accessDenied, SmbCommand.treeConnect, true).message, contains('guests'));
      expect(err(NtStatus.accessDenied).kind, RemoteErrorKind.permission);
      expect(err(NtStatus.badNetworkName, SmbCommand.treeConnect).message, 'There\'s no share called Public on nas.');
      expect(err(NtStatus.objectNameNotFound).kind, RemoteErrorKind.notFound);
      expect(err(NtStatus.objectPathNotFound).kind, RemoteErrorKind.notFound);
      expect(err(NtStatus.objectNameCollision).kind, RemoteErrorKind.alreadyExists);
      expect(err(NtStatus.notSameDevice).kind, RemoteErrorKind.unsupported);
      expect(err(NtStatus.accountLockedOut).kind, RemoteErrorKind.auth);
      expect(err(0xc0001234).message, contains('0xc0001234'));
    });

    test('connection problems and protocol problems', () {
      expect(smbError(SmbConnectionException('x', refused: true), host: 'nas', port: 4455).message, contains('nas:4455'));
      expect(smbError(SmbConnectionException('x', timedOut: true), host: 'nas').kind, RemoteErrorKind.network);
      expect(smbError(SmbProtocolException('x', kind: SmbProblem.smb1Only), host: 'nas').message, contains('SMB 1'));
      expect(smbError(SmbProtocolException('x', kind: SmbProblem.encryptionUnavailable), host: 'nas').message, contains('encryption'));
      expect(smbError(const SocketException('no'), host: 'nas').kind, RemoteErrorKind.network);
      expect(smbShouldReconnect(SmbConnectionException('gone')), isTrue);
      expect(smbShouldReconnect(SmbStatusException(NtStatus.networkSessionExpired, 5)), isTrue);
      expect(smbShouldReconnect(SmbStatusException(NtStatus.accessDenied, 5)), isFalse);
    });
  });
}
