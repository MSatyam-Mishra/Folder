import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'smb_bytes.dart';
import 'smb_connection.dart' show netbiosEncodeName;

/// Finding SMB servers on the local network, and resolving names that DNS
/// doesn't know (`NAS`, `macbook.local`), without any system service:
///
/// * mDNS: a `_smb._tcp.local` question (Macs, Synology, QNAP, Linux with
///   Avahi). Sent from a random port, so replies come back by unicast and no
///   multicast lock or port 5353 is needed.
/// * WS-Discovery: how Windows 10 and 11 (and wsdd on Samba) announce
///   themselves now that the old browser service is gone.
/// * NetBIOS: a node status question to each address of the local /24, for
///   older Windows and Samba; a name with the 0x20 suffix means a file server.

enum SmbDiscoverySource { mdns, wsDiscovery, netbios }

class DiscoveredSmbHost {
  const DiscoveredSmbHost({required this.name, required this.address, this.port = 445, required this.source});

  /// What the machine calls itself ("NAS", "Satyam's MacBook Pro"); the
  /// address as text when nothing better was found.
  final String name;
  final InternetAddress address;
  final int port;
  final SmbDiscoverySource source;

  @override
  String toString() => 'DiscoveredSmbHost($name, ${address.address}:$port, ${source.name})';
}

/// SMB servers nearby, each address once, for about [timeout]. The stream
/// closes by itself afterwards.
Stream<DiscoveredSmbHost> discoverSmbHosts({
  Duration timeout = const Duration(seconds: 4),
  bool mdns = true,
  bool wsDiscovery = true,
  bool netbios = true,
}) {
  late StreamController<DiscoveredSmbHost> controller;
  final seen = <String>{};
  var cancelled = false;

  void found(DiscoveredSmbHost h) {
    if (cancelled || controller.isClosed) return;
    if (seen.add(h.address.address)) controller.add(h);
  }

  Future<void> run() async {
    final jobs = <Future<void>>[
      if (mdns) _mdnsDiscover(timeout, found, () => cancelled).catchError((Object _) {}),
      if (wsDiscovery) _wsDiscover(timeout, found, () => cancelled).catchError((Object _) {}),
      if (netbios) _netbiosScan(timeout, found, () => cancelled).catchError((Object _) {}),
    ];
    await Future.wait(jobs);
    if (!controller.isClosed) await controller.close();
  }

  controller = StreamController<DiscoveredSmbHost>(
    onListen: () => unawaited(run()),
    onCancel: () => cancelled = true,
  );
  return controller.stream;
}

/// An address for [host]: DNS first, then mDNS for `.local` names and a
/// NetBIOS broadcast for short ones. Null when nothing knows it (connecting
/// by name then gives the system's own error).
Future<InternetAddress?> resolveSmbHost(String host, {Duration timeout = const Duration(seconds: 3)}) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return literal;
  try {
    final r = await InternetAddress.lookup(host).timeout(const Duration(seconds: 5));
    if (r.isNotEmpty) {
      return r.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => r.first);
    }
  } catch (_) {}
  final lower = host.toLowerCase();
  if (lower.endsWith('.local')) {
    return mdnsResolve(host, timeout: timeout);
  }
  if (!host.contains('.') && host.length <= 15) {
    return netbiosResolve(host, timeout: timeout);
  }
  return null;
}

// ------------------------------------------------------------------ DNS bits

Uint8List _dnsQuestion(int id, List<(String, int)> questions, {bool unicastResponse = true}) {
  final w = ByteWriter()
    ..u16be(id)
    ..u16be(0)
    ..u16be(questions.length)
    ..u16be(0)
    ..u16be(0)
    ..u16be(0);
  for (final (name, type) in questions) {
    for (final label in name.split('.')) {
      if (label.isEmpty) continue;
      final b = utf8.encode(label);
      w
        ..u8(b.length)
        ..bytes(b);
    }
    w
      ..u8(0)
      ..u16be(type)
      ..u16be(unicastResponse ? 0x8001 : 0x0001);
  }
  return Uint8List.fromList(w.toBytes());
}

class _DnsRecord {
  _DnsRecord(this.name, this.type, this.data, this.dataOffset, this.packet);
  final String name;
  final int type;
  final Uint8List data;
  final int dataOffset;
  final Uint8List packet;
}

/// Reads a possibly compressed DNS name at [offset]; returns it and where
/// the name ended in the packet.
(String, int) _readName(Uint8List p, int offset) {
  final labels = <String>[];
  var o = offset;
  var end = -1;
  var jumps = 0;
  while (o < p.length) {
    final len = p[o];
    if (len == 0) {
      o++;
      break;
    }
    if ((len & 0xc0) == 0xc0) {
      if (o + 1 >= p.length || ++jumps > 32) break;
      if (end < 0) end = o + 2;
      o = ((len & 0x3f) << 8) | p[o + 1];
      continue;
    }
    if (o + 1 + len > p.length) break;
    labels.add(utf8.decode(p.sublist(o + 1, o + 1 + len), allowMalformed: true));
    o += 1 + len;
  }
  return (labels.join('.'), end >= 0 ? end : o);
}

List<_DnsRecord> _parseDns(Uint8List p) {
  final out = <_DnsRecord>[];
  if (p.length < 12) return out;
  final qd = (p[4] << 8) | p[5];
  final rr = ((p[6] << 8) | p[7]) + ((p[8] << 8) | p[9]) + ((p[10] << 8) | p[11]);
  var o = 12;
  for (var i = 0; i < qd; i++) {
    final (_, end) = _readName(p, o);
    o = end + 4;
  }
  for (var i = 0; i < rr && o < p.length; i++) {
    final (name, end) = _readName(p, o);
    o = end;
    if (o + 10 > p.length) break;
    final type = (p[o] << 8) | p[o + 1];
    final len = (p[o + 8] << 8) | p[o + 9];
    o += 10;
    if (o + len > p.length) break;
    out.add(_DnsRecord(name.toLowerCase(), type, Uint8List.sublistView(p, o, o + len), o, p));
    o += len;
  }
  return out;
}

final InternetAddress _mdnsGroup = InternetAddress('224.0.0.251');

/// Collects mDNS answers about `_smb._tcp` and says which hosts are complete
/// (name, SRV and address known) and which questions to ask next.
class MdnsSmbBrowser {
  final Map<String, String> _instances = {}; // instance name -> label
  final Map<String, (String, int)> _srv = {}; // instance -> (host, port)
  final Map<String, InternetAddress> _hosts = {};
  final Set<String> _asked = {};

  /// Takes one reply; returns the questions (name, type) still to ask.
  List<(String, int)> add(Uint8List packet) {
    for (final r in _parseDns(packet)) {
      if (r.type == 12 && r.name == '_smb._tcp.local') {
        final (target, _) = _readName(r.packet, r.dataOffset);
        final t = target.toLowerCase();
        final suffix = t.indexOf('._smb._tcp.local');
        _instances[t] = suffix > 0 ? target.substring(0, suffix) : target;
      } else if (r.type == 33 && r.data.length > 6) {
        final port = (r.data[4] << 8) | r.data[5];
        final (target, _) = _readName(r.packet, r.dataOffset + 6);
        _srv[r.name] = (target.toLowerCase(), port);
      } else if (r.type == 1 && r.data.length == 4) {
        _hosts[r.name] = InternetAddress.fromRawAddress(Uint8List.fromList(r.data));
      }
    }
    final ask = <(String, int)>[];
    for (final i in _instances.keys) {
      if (!_srv.containsKey(i) && _asked.add(i)) ask.add((i, 33));
    }
    for (final (host, _) in _srv.values) {
      if (!_hosts.containsKey(host) && _asked.add(host)) ask.add((host, 1));
    }
    return ask;
  }

  /// The hosts known in full so far.
  List<DiscoveredSmbHost> get hosts => [
        for (final e in _srv.entries)
          if (_hosts[e.value.$1] case final addr?)
            DiscoveredSmbHost(
              name: _instances[e.key] ?? e.key.split('.').first,
              address: addr,
              port: e.value.$2,
              source: SmbDiscoverySource.mdns,
            ),
      ];
}

/// A DNS question, as mDNS takes it (with the unicast-reply bit).
Uint8List mdnsQuestion(List<(String, int)> questions) => _dnsQuestion(0x5346, questions);

Future<void> _mdnsDiscover(Duration timeout, void Function(DiscoveredSmbHost) found, bool Function() stop) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final browser = MdnsSmbBrowser();
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    final ask = browser.add(d.data);
    if (ask.isNotEmpty) socket.send(mdnsQuestion(ask), _mdnsGroup, 5353);
    browser.hosts.forEach(found);
  });
  final q = mdnsQuestion([('_smb._tcp.local', 12)]);
  try {
    socket.multicastHops = 255;
  } catch (_) {}
  socket.send(q, _mdnsGroup, 5353);
  await _sleep(const Duration(milliseconds: 700), stop);
  socket.send(q, _mdnsGroup, 5353);
  await _sleep(timeout - const Duration(milliseconds: 700), stop);
  socket.close();
}

/// The address of a `.local` name, by asking mDNS.
Future<InternetAddress?> mdnsResolve(String host, {Duration timeout = const Duration(seconds: 3)}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final done = Completer<InternetAddress?>();
  final want = host.toLowerCase();
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    for (final r in _parseDns(d.data)) {
      if (r.type == 1 && r.data.length == 4 && r.name == want && !done.isCompleted) {
        done.complete(InternetAddress.fromRawAddress(Uint8List.fromList(r.data)));
      }
    }
  });
  socket.send(_dnsQuestion(0x5347, [(host, 1)]), _mdnsGroup, 5353);
  final r = await done.future.timeout(timeout, onTimeout: () => null);
  socket.close();
  return r;
}

// ------------------------------------------------------------------ NetBIOS

Uint8List _nbQuestion(int id, String name, int suffix, {required bool status, bool broadcast = false}) {
  final w = ByteWriter()
    ..u16be(id)
    ..u16be(status ? 0x0000 : (0x0100 | (broadcast ? 0x0010 : 0)))
    ..u16be(1)
    ..u16be(0)
    ..u16be(0)
    ..u16be(0)
    ..bytes(netbiosEncodeName(name, suffix))
    ..u16be(status ? 0x21 : 0x20)
    ..u16be(1);
  return Uint8List.fromList(w.toBytes());
}

/// The file server name (suffix 0x20) in a node status reply; with
/// [serverOnly] false, the machine's name even when it shares nothing.
String? parseNbstat(Uint8List p, {bool serverOnly = true}) {
  if (p.length < 12 + 34 + 10 || ((p[6] << 8) | p[7]) < 1) return null;
  var o = 12;
  final (_, end) = _readNbName(p, o);
  o = end;
  if (o + 11 > p.length) return null;
  final type = (p[o] << 8) | p[o + 1];
  if (type != 0x21) return null;
  o += 10;
  final count = p[o++];
  String? any;
  for (var i = 0; i < count && o + 18 <= p.length; i++) {
    final name = latin1.decode(p.sublist(o, o + 15)).trimRight();
    final suffix = p[o + 15];
    final flags = (p[o + 16] << 8) | p[o + 17];
    final group = (flags & 0x8000) != 0;
    if (!group && suffix == 0x20) return name;
    if (!group && suffix == 0x00) any ??= name;
    o += 18;
  }
  if (any == null) return null;
  return serverOnly ? '' : any;
}

(String, int) _readNbName(Uint8List p, int o) {
  if (o < p.length && (p[o] & 0xc0) == 0xc0) return ('', o + 2);
  final (n, end) = _readName(p, o);
  return (n, end);
}

/// The IPv4 address in a positive name query reply.
InternetAddress? parseNbNameReply(Uint8List p) {
  if (p.length < 12 || ((p[6] << 8) | p[7]) < 1 || (p[3] & 0x0f) != 0) return null;
  final (_, end) = _readNbName(p, 12);
  var o = end;
  if (o + 10 > p.length) return null;
  final type = (p[o] << 8) | p[o + 1];
  final len = (p[o + 8] << 8) | p[o + 9];
  o += 10;
  if (type != 0x20 || len < 6 || o + 6 > p.length) return null;
  return InternetAddress.fromRawAddress(Uint8List.fromList(p.sublist(o + 2, o + 6)));
}

Future<List<InternetAddress>> _localIpv4() async {
  try {
    final list = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    return [
      for (final i in list)
        for (final a in i.addresses)
          if (_isPrivate(a)) a,
    ];
  } catch (_) {
    return const [];
  }
}

bool _isPrivate(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length != 4) return false;
  return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
}

Future<void> _netbiosScan(Duration timeout, void Function(DiscoveredSmbHost) found, bool Function() stop) async {
  final own = await _localIpv4();
  if (own.isEmpty) return;
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    final name = parseNbstat(d.data);
    if (name != null && name.isNotEmpty) {
      found(DiscoveredSmbHost(name: name, address: d.address, source: SmbDiscoverySource.netbios));
    }
  });
  final q = _nbQuestion(0x4e42, '*', 0, status: true);
  final subnets = <String>{};
  for (final a in own.take(3)) {
    final b = a.rawAddress;
    if (!subnets.add('${b[0]}.${b[1]}.${b[2]}')) continue;
    for (var i = 1; i < 255 && !stop(); i++) {
      if (i == b[3]) continue;
      socket.send(q, InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], i])), 137);
      if (i % 32 == 0) await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }
  await _sleep(timeout, stop);
  socket.close();
}

/// The name a machine at [address] gives itself over NetBIOS, if it answers.
Future<String?> netbiosNameOf(InternetAddress address, {Duration timeout = const Duration(milliseconds: 1200)}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final done = Completer<String?>();
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null || done.isCompleted) return;
    final n = parseNbstat(d.data, serverOnly: false);
    if (n != null && n.isNotEmpty) done.complete(n);
  });
  socket.send(_nbQuestion(0x4e43, '*', 0, status: true), address, 137);
  final r = await done.future.timeout(timeout, onTimeout: () => null);
  socket.close();
  return r;
}

/// The address of NetBIOS [name], by broadcast on each local network.
Future<InternetAddress?> netbiosResolve(String name, {Duration timeout = const Duration(seconds: 3)}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final done = Completer<InternetAddress?>();
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null || done.isCompleted) return;
    final a = parseNbNameReply(d.data);
    if (a != null) done.complete(a);
  });
  final q = _nbQuestion(0x4e44, name, 0x20, status: false, broadcast: true);
  final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
  for (final a in await _localIpv4()) {
    final b = a.rawAddress;
    targets.add(InternetAddress.fromRawAddress(Uint8List.fromList([b[0], b[1], b[2], 255])));
  }
  for (final t in targets) {
    try {
      socket.send(q, t, 137);
    } catch (_) {}
  }
  final r = await done.future.timeout(timeout, onTimeout: () => null);
  socket.close();
  return r;
}

// ------------------------------------------------------------------ WS-Discovery

final InternetAddress _wsdGroup = InternetAddress('239.255.255.250');

String _uuid() {
  final b = randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = hexOf(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

String wsdProbe(String messageId) => '<?xml version="1.0" encoding="utf-8"?>'
    '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
    'xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
    'xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof">'
    '<soap:Header>'
    '<wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'
    '<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'
    '<wsa:MessageID>urn:uuid:$messageId</wsa:MessageID>'
    '</soap:Header>'
    '<soap:Body><wsd:Probe><wsd:Types>wsdp:Device</wsd:Types></wsd:Probe></soap:Body>'
    '</soap:Envelope>';

String? _xmlText(String xml, String tag) {
  final m = RegExp('<(?:[\\w-]+:)?$tag(?:\\s[^>]*)?>([^<]*)</(?:[\\w-]+:)?$tag>').firstMatch(xml);
  return m?.group(1)?.trim();
}

/// (endpoint, types, first http address) of a ProbeMatch, or null.
(String, String, String?)? parseProbeMatch(String xml) {
  if (!xml.contains('ProbeMatch')) return null;
  final types = _xmlText(xml, 'Types') ?? '';
  final endpoint = _xmlText(xml, 'Address') ?? '';
  final xaddrs = _xmlText(xml, 'XAddrs');
  final first = xaddrs?.split(RegExp(r'\s+')).firstWhere((u) => u.startsWith('http'), orElse: () => '');
  return (endpoint, types, first == null || first.isEmpty ? null : first);
}

/// The computer name in a WS-Transfer Get reply: `NAME/Workgroup:WG`.
String? parseWsdComputer(String xml) {
  final c = _xmlText(xml, 'Computer');
  if (c != null && c.isNotEmpty) return c.split('/').first;
  final f = _xmlText(xml, 'FriendlyName');
  return f == null || f.isEmpty ? null : f;
}

Future<void> _wsDiscover(Duration timeout, void Function(DiscoveredSmbHost) found, bool Function() stop) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final jobs = <Future<void>>[];
  final handled = <String>{};
  socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null) return;
    final m = parseProbeMatch(utf8.decode(d.data, allowMalformed: true));
    if (m == null) return;
    final (endpoint, types, xaddr) = m;
    if (!types.contains('Computer')) return; // printers, scanners...
    if (!handled.add(d.address.address)) return;
    jobs.add(_nameWsdHost(d.address, endpoint, xaddr).then((name) {
      if (name != null) found(DiscoveredSmbHost(name: name, address: d.address, source: SmbDiscoverySource.wsDiscovery));
    }).catchError((Object _) {}));
  });
  try {
    socket.multicastHops = 4;
  } catch (_) {}
  final probe = utf8.encode(wsdProbe(_uuid()));
  socket.send(probe, _wsdGroup, 3702);
  await _sleep(const Duration(milliseconds: 500), stop);
  socket.send(probe, _wsdGroup, 3702);
  await _sleep(timeout - const Duration(milliseconds: 500), stop);
  socket.close();
  await Future.wait(jobs).timeout(const Duration(seconds: 3), onTimeout: () => const []);
}

/// A WS-Discovery computer's name, once its SMB port answers.
Future<String?> _nameWsdHost(InternetAddress address, String endpoint, String? xaddr) async {
  if (!await _portOpen(address, 445)) return null;
  final nb = await netbiosNameOf(address);
  if (nb != null) return nb;
  if (xaddr != null) {
    try {
      final name = await _wsdGet(xaddr, endpoint);
      if (name != null) return name;
    } catch (_) {}
  }
  try {
    final r = await address.reverse().timeout(const Duration(seconds: 2));
    if (r.host != address.address) return r.host.split('.').first;
  } catch (_) {}
  return address.address;
}

Future<String?> _wsdGet(String url, String endpoint) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">'
        '<soap:Header><wsa:To>$endpoint</wsa:To>'
        '<wsa:Action>http://schemas.xmlsoap.org/ws/2004/09/transfer/Get</wsa:Action>'
        '<wsa:MessageID>urn:uuid:${_uuid()}</wsa:MessageID>'
        '<wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo>'
        '<wsa:From><wsa:Address>urn:uuid:${_uuid()}</wsa:Address></wsa:From>'
        '</soap:Header><soap:Body/></soap:Envelope>';
    final req = await client.postUrl(Uri.parse(url)).timeout(const Duration(seconds: 2));
    req.headers.contentType = ContentType('application', 'soap+xml', charset: 'utf-8');
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 3));
    final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
    return parseWsdComputer(text);
  } finally {
    client.close(force: true);
  }
}

Future<bool> _portOpen(InternetAddress a, int port) async {
  try {
    final s = await Socket.connect(a, port, timeout: const Duration(milliseconds: 800));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _sleep(Duration d, bool Function() stop) async {
  final end = DateTime.now().add(d);
  while (!stop() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(Duration(milliseconds: min(100, max(1, end.difference(DateTime.now()).inMilliseconds))));
  }
}
