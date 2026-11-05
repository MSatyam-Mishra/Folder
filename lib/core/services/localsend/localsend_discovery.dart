// Device discovery (spec section 3): UDP multicast announcements answered via
// `POST /register` (UDP fallback), plus the HTTP subnet scan for networks
// that drop multicast, and manual "add by IP".

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folder/core/services/localsend/localsend_client.dart';
import 'package:folder/core/services/localsend/localsend_identity.dart';
import 'package:folder/core/services/localsend/localsend_models.dart';

class LsDiscovery {
  LsDiscovery({
    required this.identity,
    required this.selfInfo,
    this.multicastGroup = LsConst.multicastGroup,
    this.multicastPort = LsConst.defaultPort,
  });

  final LsIdentity identity;
  final LsDeviceInfo Function() selfInfo;
  final String multicastGroup;
  final int multicastPort;

  /// Announcements are answered only while our server runs (the answer
  /// advertises our HTTP port).
  bool Function() canAnswer = () => true;

  /// Port probed by the subnet scan (peers usually keep the default).
  int scanPort = LsConst.defaultPort;

  final Map<String, LsDevice> _devices = {};
  final _changes = StreamController<void>.broadcast();
  final Map<String, DateTime> _lastAnswer = {};
  RawDatagramSocket? _socket;
  List<NetworkInterface> _interfaces = const [];
  LsClient? _client;
  LsClient? _scanClient;
  bool _scanning = false;
  bool _started = false;
  String? _multicastError;
  int _generation = 0;

  Stream<void> get changes => _changes.stream;
  bool get isScanning => _scanning;

  /// Why multicast is unavailable (discovery then relies on the HTTP scan).
  String? get multicastError => _multicastError;

  List<LsDevice> get devices {
    final list = _devices.values.toList()
      ..sort((a, b) => a.alias.toLowerCase().compareTo(b.alias.toLowerCase()));
    return list;
  }

  LsDevice? deviceByKey(String key) => _devices[key.toUpperCase()];

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _client = LsClient(identity, connectTimeout: const Duration(seconds: 3));
    _scanClient = LsClient(
      identity,
      connectTimeout: const Duration(seconds: 1),
    );
    await _bind();
  }

  /// Delay that ends early when discovery stops (no timers outlive it).
  Future<void> _sleep(Duration duration) {
    final completer = Completer<void>();
    late final Timer timer;
    timer = Timer(duration, () {
      _sleepers.remove(timer);
      completer.complete();
    });
    _sleepers[timer] = completer;
    return completer.future;
  }

  final Map<Timer, Completer<void>> _sleepers = {};

  Future<void> stop() async {
    _started = false;
    _generation++;
    for (final e in _sleepers.entries.toList()) {
      e.key.cancel();
      if (!e.value.isCompleted) e.value.complete();
    }
    _sleepers.clear();
    _socket?.close();
    _socket = null;
    _client?.close();
    _scanClient?.close();
    _client = null;
    _scanClient = null;
    _scanning = false;
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ------------------------------------------------------------ multicast

  Future<void> _bind() async {
    _socket?.close();
    _socket = null;
    _multicastError = null;
    try {
      _interfaces = await lsLocalInterfaces();
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        multicastPort,
        reuseAddress: true,
        reusePort: Platform.isMacOS || Platform.isIOS,
      );
      try {
        socket.multicastLoopback = true;
      } catch (_) {}
      final group = InternetAddress(multicastGroup);
      var joined = 0;
      for (final iface in _interfaces) {
        try {
          socket.joinMulticast(group, iface);
          joined++;
        } catch (e) {
          LsLog.d('joinMulticast on ${iface.name} failed: $e');
        }
      }
      if (joined == 0) {
        try {
          socket.joinMulticast(group);
          joined++;
        } catch (e) {
          _multicastError = 'Cannot join multicast group: $e';
        }
      }
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          _onDatagram(datagram!);
        }
      }, onError: (Object e) => LsLog.d('multicast socket error: $e'));
      _socket = socket;
    } catch (e) {
      _multicastError = 'Multicast unavailable: $e';
      LsLog.d(_multicastError!);
    }
    _emit();
  }

  /// Rebinds the multicast socket and announces (e.g. after the app was
  /// suspended: iOS invalidates the sockets of suspended apps).
  Future<void> rebind() async {
    if (!_started) return;
    await _bind();
    unawaited(announce());
  }

  /// Re-reads the network interfaces; rebinds and re-announces when they
  /// changed (Wi-Fi switched, hotspot started...). Returns true on change.
  Future<bool> checkNetworkChange() async {
    if (!_started) return false;
    final now = await lsLocalInterfaces();
    String sig(List<NetworkInterface> l) =>
        (l
                .expand((i) => i.addresses.map((a) => '${i.name}/${a.address}'))
                .toList()
              ..sort())
            .join(',');
    if (sig(now) == sig(_interfaces)) return false;
    LsLog.d('network changed: ${sig(now)}');
    await _bind();
    unawaited(announce());
    return true;
  }

  void _onDatagram(Datagram datagram) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(datagram.data));
    } catch (_) {
      return;
    }
    if (json is! Map) return;
    if (!json.containsKey('version')) {
      // Protocol v1 announcement ("announcement": true): not supported.
      return;
    }
    final info = LsDeviceInfo.tryParse(json);
    if (info == null || (info.majorVersion ?? 0) < 2) return;
    if (info.fingerprint.isEmpty || _isSelf(info.fingerprint)) return;
    final ip = datagram.address.address;
    _upsert(ip, info, LsDiscoverySource.multicast);
    final isAnnouncement = json['announce'] != false;
    if (isAnnouncement && canAnswer()) unawaited(_answer(ip, info));
  }

  bool _isSelf(String fingerprint) =>
      fingerprint.toUpperCase() == selfInfo().fingerprint.toUpperCase();

  Future<void> _answer(String ip, LsDeviceInfo announced) async {
    final key = '${announced.fingerprint}@$ip';
    final last = _lastAnswer[key];
    final now = DateTime.now();
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 1500)) {
      return;
    }
    _lastAnswer[key] = now;
    final client = _client;
    if (client == null) return;
    try {
      final result = await client.register(
        host: ip,
        port: announced.port,
        protocol: announced.protocol,
        self: selfInfo(),
      );
      final certFp = result.certificateFingerprint;
      if (certFp != null &&
          certFp.toUpperCase() != announced.fingerprint.toUpperCase()) {
        LsLog.d('$ip announced ${announced.fingerprint} but presented $certFp');
        _devices.remove(announced.fingerprint.toUpperCase());
        _emit();
        return;
      }
      _upsert(ip, result.info, LsDiscoverySource.register);
    } catch (e) {
      LsLog.d('register with announcing $ip failed ($e); answering via UDP');
      _sendMulticast(selfInfo().toAnnouncementJson(announce: false));
    }
  }

  void _sendMulticast(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null) return;
    final bytes = utf8.encode(jsonEncode(message));
    final group = InternetAddress(multicastGroup);
    if (_interfaces.isEmpty) {
      try {
        socket.send(bytes, group, multicastPort);
      } catch (e) {
        LsLog.d('multicast send failed: $e');
      }
      return;
    }
    for (final iface in _interfaces) {
      try {
        socket.setRawOption(
          RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            Uint8List.fromList(iface.addresses.first.rawAddress),
          ),
        );
        socket.send(bytes, group, multicastPort);
      } catch (e) {
        LsLog.d('multicast send on ${iface.name} failed: $e');
      }
    }
  }

  /// Sends our announcement (a short burst, datagrams get lost).
  Future<void> announce() async {
    final generation = _generation;
    for (final delay in const [100, 500, 2000]) {
      await _sleep(Duration(milliseconds: delay));
      if (!_started || generation != _generation) return;
      _sendMulticast(selfInfo().toAnnouncementJson(announce: true));
    }
  }

  // ------------------------------------------------------------ registry

  LsDevice? _upsert(String ip, LsDeviceInfo info, LsDiscoverySource source) {
    if (!_started) return null;
    final key = info.fingerprint.isEmpty
        ? '$ip:${info.port}'.toUpperCase()
        : info.fingerprint.toUpperCase();
    if (_isSelf(key)) return null;
    final device = LsDevice(
      ip: ip,
      info: info,
      lastSeen: DateTime.now(),
      source: _devices[key]?.source ?? source,
    );
    _devices[key] = device;
    _emit();
    return device;
  }

  /// A device registered with our server.
  void onRegister(String ip, LsDeviceInfo info) {
    if ((info.majorVersion ?? 0) < 2) return;
    _upsert(ip, info, LsDiscoverySource.register);
  }

  void clear() {
    _devices.clear();
    _emit();
  }

  void remove(String key) {
    if (_devices.remove(key.toUpperCase()) != null) _emit();
  }

  /// Announces, and falls back to the subnet scan when nothing answers
  /// within [grace] (networks that block multicast).
  Future<void> refresh({
    bool clearList = true,
    Duration grace = const Duration(seconds: 3),
  }) async {
    if (clearList) clear();
    final before = _devices.length;
    await announce();
    await _sleep(grace);
    if (_started && (_devices.length == before || _multicastError != null)) {
      await scan();
    }
  }

  // ------------------------------------------------------------ HTTP

  /// Sends `POST /register` to every host of our /24 subnets.
  Future<void> scan() async {
    if (_scanning || !_started) return;
    _scanning = true;
    _emit();
    final generation = _generation;
    try {
      final own = <String>{};
      final hosts = <String>[];
      for (final iface in await lsLocalInterfaces()) {
        for (final a in iface.addresses) {
          own.add(a.address);
        }
      }
      final prefixes = <String>{};
      for (final ip in own) {
        if (!lsIsPrivateIPv4(ip)) continue;
        prefixes.add(ip.substring(0, ip.lastIndexOf('.') + 1));
      }
      // Our own addresses are probed too: another LocalSend instance may run
      // on this machine; our own server is recognised by its fingerprint.
      for (final prefix in prefixes.take(4)) {
        for (var i = 1; i < 255; i++) {
          hosts.add('$prefix$i');
        }
      }
      var next = 0;
      Future<void> worker() async {
        while (next < hosts.length && _started && generation == _generation) {
          final host = hosts[next++];
          await _probe(host, scanPort, LsDiscoverySource.scan, _scanClient);
        }
      }

      await Future.wait(List.generate(48, (_) => worker()));
    } finally {
      if (generation == _generation) {
        _scanning = false;
        _emit();
      }
    }
  }

  Future<LsDevice?> _probe(
    String host,
    int port,
    LsDiscoverySource source,
    LsClient? client, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    if (client == null) return null;
    LsException? last;
    for (final protocol in LsProtocol.values.reversed) {
      // https first, then http when the TLS handshake fails (plain server).
      try {
        final result = await client.register(
          host: host,
          port: port,
          protocol: protocol,
          self: selfInfo(),
          timeout: timeout,
        );
        if (_isSelf(result.info.fingerprint)) return null;
        return _upsert(host, result.info, source);
      } on LsException catch (e) {
        last = e;
        if (e.kind != LsErrorKind.tls) break;
      }
    }
    if (source == LsDiscoverySource.manual && last != null) throw last;
    return null;
  }

  /// Adds a device by address (`host` or `host:port`).
  Future<LsDevice> addByAddress(String address) async {
    var host = address.trim();
    var port = LsConst.defaultPort;
    final colon = host.lastIndexOf(':');
    if (colon > 0 && !host.contains(']') && host.indexOf(':') == colon) {
      port = int.tryParse(host.substring(colon + 1)) ?? port;
      host = host.substring(0, colon);
    }
    if (host.isEmpty) {
      throw const LsException(LsErrorKind.badRequest, 'empty address');
    }
    final device = await _probe(
      host,
      port,
      LsDiscoverySource.manual,
      _client,
      timeout: const Duration(seconds: 4),
    );
    if (device == null) {
      throw const LsException(
        LsErrorKind.protocol,
        'that address belongs to this device',
      );
    }
    return device;
  }
}

/// Up, non-loopback IPv4 interfaces (virtual adapters included).
Future<List<NetworkInterface>> lsLocalInterfaces() async {
  try {
    final list = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return list
        .where((i) => i.addresses.any((a) => !a.address.startsWith('169.254.')))
        .toList();
  } catch (_) {
    return const [];
  }
}

bool lsIsPrivateIPv4(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final a = parts[0]!, b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// Our IPv4 addresses, private LAN addresses first.
Future<List<String>> lsLocalAddresses() async {
  final ips = <String>[
    for (final i in await lsLocalInterfaces())
      for (final a in i.addresses)
        if (!a.address.startsWith('169.254.')) a.address,
  ];
  ips.sort((a, b) {
    final pa = lsIsPrivateIPv4(a) ? 0 : 1;
    final pb = lsIsPrivateIPv4(b) ? 0 : 1;
    if (pa != pb) return pa - pb;
    final wa = a.startsWith('192.168.') ? 0 : 1;
    final wb = b.startsWith('192.168.') ? 0 : 1;
    return wa - wb;
  });
  return ips;
}
