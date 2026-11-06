// Ties identity, server, discovery and transfers together. Pure Dart: the
// Flutter screen wraps it, the test harness drives it directly.

import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/localsend/localsend_client.dart';
import 'package:folders/core/services/localsend/localsend_discovery.dart';
import 'package:folders/core/services/localsend/localsend_identity.dart';
import 'package:folders/core/services/localsend/localsend_models.dart';
import 'package:folders/core/services/localsend/localsend_sender.dart';
import 'package:folders/core/services/localsend/localsend_server.dart';

class LsSettings {
  const LsSettings({
    required this.alias,
    required this.destination,
    required this.httpFingerprint,
    this.port = LsConst.defaultPort,
    this.https = true,
    this.pin,
    this.autoAcceptTrusted = false,
    this.deviceModel,
    this.deviceType = LsDeviceType.desktop,
    this.sendChecksums = false,
  });

  final String alias;
  final int port;
  final bool https;

  /// Required from senders when set (empty = none).
  final String? pin;
  final bool autoAcceptTrusted;
  final String destination;
  final String? deviceModel;
  final LsDeviceType deviceType;
  final bool sendChecksums;

  /// Fingerprint used in HTTP mode (spec: a random string), kept stable.
  final String httpFingerprint;

  LsSettings copyWith({
    String? alias,
    int? port,
    bool? https,
    String? pin,
    bool clearPin = false,
    bool? autoAcceptTrusted,
    String? destination,
    String? deviceModel,
    LsDeviceType? deviceType,
    bool? sendChecksums,
  }) => LsSettings(
    alias: alias ?? this.alias,
    port: port ?? this.port,
    https: https ?? this.https,
    pin: clearPin ? null : (pin ?? this.pin),
    autoAcceptTrusted: autoAcceptTrusted ?? this.autoAcceptTrusted,
    destination: destination ?? this.destination,
    deviceModel: deviceModel ?? this.deviceModel,
    deviceType: deviceType ?? this.deviceType,
    sendChecksums: sendChecksums ?? this.sendChecksums,
    httpFingerprint: httpFingerprint,
  );
}

/// Platform specifics (Android multicast lock, network callbacks).
abstract class LsPlatformHooks {
  Future<void> acquireMulticastLock();
  Future<void> releaseMulticastLock();
}

class LsService {
  LsService({
    required this.identity,
    required LsSettings settings,
    this.hooks,
    int multicastPort = LsConst.defaultPort,
  }) : _settings = settings {
    server = LsServer(identity: identity, selfInfo: () => selfInfo)
      ..onRegister = _onRegister
      ..onIncoming = _onIncoming
      ..onSessionChanged = _onSessionChanged
      ..onForeignCancel = _onForeignCancel;
    discovery = LsDiscovery(
      identity: identity,
      selfInfo: () => selfInfo,
      multicastPort: multicastPort,
    )..canAnswer = () => server.isRunning;
  }

  final LsIdentity identity;
  final LsPlatformHooks? hooks;
  late final LsServer server;
  late final LsDiscovery discovery;
  LsSettings _settings;

  /// Decides on incoming transfers (UI dialog). Auto-accept is applied first.
  Future<LsReceiveDecision> Function(LsIncomingRequest request)? onIncoming;

  /// Trusted device fingerprints for auto-accept.
  Set<String> Function() trustedFingerprints = () => const {};

  /// Called for every finished receive session (e.g. to refresh a listing).
  void Function(LsReceiveSession session)? onReceiveFinished;

  final _changes = StreamController<void>.broadcast();
  final List<LsReceiveSession> receiveHistory = [];
  final Set<String> _finishedReported = {};
  StreamSubscription<void>? _discoverySub;
  StreamSubscription<void>? _sendSub;
  LsSendSession? sendSession;
  String? serverError;
  List<String> localAddresses = const [];
  Timer? _networkTimer;
  int _ticks = 0;
  bool _running = false;

  Stream<void> get changes => _changes.stream;
  LsSettings get settings => _settings;
  bool get isRunning => _running;

  LsDeviceInfo get selfInfo => LsDeviceInfo(
    alias: _settings.alias,
    version: LsConst.protocolVersion,
    deviceModel: _settings.deviceModel,
    deviceType: _settings.deviceType,
    fingerprint: _settings.https
        ? identity.fingerprint
        : _settings.httpFingerprint,
    port: server.port ?? _settings.port,
    protocol: _settings.https ? LsProtocol.https : LsProtocol.http,
  );

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await hooks?.acquireMulticastLock();
    } catch (e) {
      LsLog.d('multicast lock: $e');
    }
    await _startServer();
    _discoverySub = discovery.changes.listen((_) => _emit());
    await discovery.start();
    localAddresses = await lsLocalAddresses();
    _ticks = 0;
    _networkTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_tick()),
    );
    _emit();
    unawaited(discovery.refresh(clearList: false));
  }

  Future<void> _startServer() async {
    serverError = null;
    try {
      await LsServer.cleanupStaleTemp(_settings.destination);
      await server.start(
        port: _settings.port,
        https: _settings.https,
        pin: _settings.pin,
        destination: _settings.destination,
      );
    } on SocketException catch (e) {
      serverError =
          'Cannot listen on port ${_settings.port} '
          '(${e.osError?.message ?? e.message}). Another LocalSend app may be '
          'running: close it or pick another port in settings.';
      LsLog.d(serverError!);
    } catch (e) {
      serverError = 'Cannot start the receiver: $e';
      LsLog.d(serverError!);
    }
    _emit();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _networkTimer?.cancel();
    _networkTimer = null;
    final send = sendSession;
    if (send != null && !send.isDone) await send.cancel();
    await cancelReceive();
    await server.stop();
    await discovery.stop();
    await _discoverySub?.cancel();
    await _sendSub?.cancel();
    try {
      await hooks?.releaseMulticastLock();
    } catch (e) {
      LsLog.d('multicast lock: $e');
    }
  }

  Future<void> dispose() async {
    await stop();
    await discovery.dispose();
    await _changes.close();
  }

  /// Applies new settings, restarting the server when port/protocol change.
  Future<void> applySettings(LsSettings next) async {
    final prev = _settings;
    _settings = next;
    if (!_running) return;
    if (prev.port != next.port ||
        prev.https != next.https ||
        server.port == null) {
      await server.stop();
      await _startServer();
    } else {
      server.update(pin: next.pin, destination: next.destination);
    }
    _emit();
    unawaited(discovery.announce());
  }

  /// Retry binding the server (e.g. after the port became free).
  Future<void> restartServer() async {
    await server.stop();
    await _startServer();
    unawaited(discovery.announce());
  }

  /// Every 5 s: watch the network. While nothing has been found, announce
  /// again every 15 s (the other device may have started after us and
  /// missed our announcement) and rescan the subnet every 60 s.
  Future<void> _tick() async {
    _ticks++;
    await onNetworkChanged();
    if (!_running || discovery.devices.isNotEmpty) return;
    if (_ticks % 12 == 0) {
      unawaited(discovery.scan());
    } else if (_ticks % 3 == 0) {
      unawaited(discovery.announce());
    }
  }

  Future<void> onNetworkChanged() async {
    if (!_running) return;
    final changed = await discovery.checkNetworkChange();
    final addresses = await lsLocalAddresses();
    if (changed || addresses.join() != localAddresses.join()) {
      localAddresses = addresses;
      _emit();
    }
  }

  /// The app came back to the foreground.
  Future<void> onResumed() async {
    if (!_running) return;
    await discovery.rebind();
    localAddresses = await lsLocalAddresses();
    final idle = server.session == null && server.pendingRequest == null;
    if (Platform.isIOS && idle) await restartServer();
    _emit();
  }

  Future<void> refreshDevices() => discovery.refresh();

  Future<LsDevice> addDevice(String address) => discovery.addByAddress(address);

  // ------------------------------------------------------------ sending

  LsSendSession startSend(
    LsDevice target,
    List<LsSendFile> files, {
    LsPinPrompt? askPin,
    int concurrency = 3,
  }) {
    final current = sendSession;
    if (current != null && !current.isDone) {
      throw const LsException(LsErrorKind.busy, 'a transfer is running');
    }
    final client = LsClient(
      identity,
      expectedFingerprint: target.protocol == LsProtocol.https
          ? target.fingerprint
          : null,
    );
    final session = LsSendSession(
      client: client,
      target: target,
      self: selfInfo,
      files: files,
      concurrency: concurrency,
      withChecksums: _settings.sendChecksums,
      askPin: askPin,
    );
    sendSession = session;
    unawaited(_sendSub?.cancel());
    _sendSub = session.changes.listen((_) => _emit());
    _emit();
    unawaited(session.run().whenComplete(_emit));
    return session;
  }

  void clearSendSession() {
    final s = sendSession;
    if (s != null && !s.isDone) return;
    sendSession = null;
    _emit();
  }

  void _onForeignCancel(String ip, String? sessionId) {
    final s = sendSession;
    if (s == null || s.isDone || s.target.ip != ip) return;
    if (sessionId != null && s.sessionId != null && sessionId != s.sessionId) {
      return;
    }
    s.cancelledByReceiver();
  }

  // ------------------------------------------------------------ receiving

  void _onRegister(String ip, LsDeviceInfo info) =>
      discovery.onRegister(ip, info);

  Future<LsReceiveDecision> _onIncoming(LsIncomingRequest request) async {
    // The sender just talked to us: make sure it is listed.
    discovery.onRegister(request.senderIp, request.sender);
    if (_settings.autoAcceptTrusted &&
        request.sender.fingerprint.isNotEmpty &&
        trustedFingerprints().contains(
          request.sender.fingerprint.toUpperCase(),
        )) {
      return const LsReceiveDecision.accept();
    }
    final decide = onIncoming;
    if (decide == null) return const LsReceiveDecision.decline();
    return decide(request);
  }

  void _onSessionChanged(LsReceiveSession session) {
    if (!receiveHistory.contains(session)) {
      receiveHistory.insert(0, session);
      if (receiveHistory.length > 20) receiveHistory.removeLast();
    }
    if (!session.isActive && _finishedReported.add(session.id)) {
      onReceiveFinished?.call(session);
    }
    _emit();
  }

  /// The receiving user cancels the current incoming transfer.
  Future<void> cancelReceive() async {
    final session = server.cancelSession(abortUploads: false);
    _emit();
    if (session == null) return;
    try {
      await _tellSenderCancelled(
        session,
      ).timeout(const Duration(seconds: 2), onTimeout: () {});
    } finally {
      server.abortUploads(session);
    }
  }

  Future<void> _tellSenderCancelled(LsReceiveSession session) async {
    // Tell the sender (official apps cancel their send on this).
    final client = LsClient(
      identity,
      connectTimeout: const Duration(seconds: 2),
    );
    try {
      await client.cancel(
        device: LsDevice(
          ip: session.senderIp,
          info: session.sender,
          lastSeen: DateTime.now(),
          source: LsDiscoverySource.register,
        ),
        sessionId: session.id,
      );
    } finally {
      client.close();
    }
  }
}
