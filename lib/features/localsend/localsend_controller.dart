import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/localsend/localsend.dart';
import 'package:folders/core/services/localsend/localsend_platform.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

/// A file that arrived in this screen session.
class LsReceivedItem {
  const LsReceivedItem({
    required this.path,
    required this.fileName,
    required this.size,
    required this.from,
    required this.at,
  });

  final String path;

  /// Relative name as sent (may contain folders).
  final String fileName;
  final int size;
  final String from;
  final DateTime at;
}

/// Screen state for nearby sharing: owns the [LsService] while the screen is
/// open (server + discovery run only then).
class LocalSendController extends ChangeNotifier with WidgetsBindingObserver {
  LocalSendController({List<FileSystemEntity> initialItems = const []})
    : items = List.of(initialItems) {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Sockets may be gone after the app was in the background (iOS).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_service?.onResumed());
    }
  }

  /// Top-level files/folders picked for sending.
  final List<FileSystemEntity> items;

  LsService? _service;
  LsAndroidHooks? _hooks;
  StreamSubscription<void>? _sub;
  Timer? _notifyTimer;
  bool _dirty = false;
  bool _disposed = false;

  bool starting = true;
  String? startupError;

  /// The public Download folder was not writable; an app folder is used.
  bool destinationFallback = false;

  /// Upper-case fingerprint -> alias of devices whose transfers are accepted
  /// automatically (when enabled in settings).
  Map<String, String> trusted = {};

  final List<LsReceivedItem> received = [];

  /// Expanded [items] (folders resolved), null while counting.
  List<LsSendFile>? sendFiles = const [];
  int _collectGeneration = 0;

  /// Set by the screen: shows the accept/decline dialog.
  Future<LsReceiveDecision> Function(LsIncomingRequest request)?
  incomingHandler;

  /// Set by the screen: asks for the receiver's PIN.
  LsPinPrompt? pinPrompt;

  LsService? get service => _service;
  LsSettings? get settings => _service?.settings;
  List<LsDevice> get devices => _service?.discovery.devices ?? const [];
  bool get scanning => _service?.discovery.isScanning ?? false;
  LsSendSession? get sendSession => _service?.sendSession;
  LsReceiveSession? get receiveSession => _service?.server.session;
  List<LsReceiveSession> get receiveHistory =>
      _service?.receiveHistory ?? const [];
  String? get serverError => _service?.serverError;
  String? get multicastError => _service?.discovery.multicastError;
  List<String> get localAddresses => _service?.localAddresses ?? const [];
  int? get serverPort => _service?.server.port;
  String? get fingerprint => _service?.selfInfo.fingerprint;

  int get sendTotalBytes =>
      (sendFiles ?? const []).fold(0, (s, f) => s + f.size);

  Future<void> start() async {
    try {
      final (settings, fallback) = await LsSettingsStore.load();
      destinationFallback = fallback;
      trusted = await LsSettingsStore.loadTrusted();
      final identity = await LsIdentity.loadOrCreate(
        await LsSettingsStore.identityDirectory(),
      );
      if (_disposed) return;
      _hooks = Platform.isAndroid ? LsAndroidHooks() : null;
      final service =
          LsService(identity: identity, settings: settings, hooks: _hooks)
            ..onIncoming = _onIncoming
            ..trustedFingerprints = (() => trusted.keys.toSet())
            ..onReceiveFinished = _onReceiveFinished;
      _hooks?.onNetworkChanged = () => unawaited(service.onNetworkChanged());
      _service = service;
      _sub = service.changes.listen((_) {
        _trackTransfers();
        _scheduleNotify();
      });
      await service.start();
      if (_disposed) {
        await service.dispose();
        return;
      }
    } catch (e, st) {
      startupError = 'Nearby sharing could not start: $e';
      debugPrint('$e\n$st');
    }
    starting = false;
    _notify();
    unawaited(_collect());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _endTask(_sendTask, TaskStatus.cancelled);
    _endTask(_receiveTask, TaskStatus.cancelled);
    _notifyTimer?.cancel();
    unawaited(_sub?.cancel());
    final service = _service;
    _service = null;
    // Stops the server and discovery and releases the multicast lock.
    unawaited(service?.dispose().whenComplete(() => _hooks?.dispose()));
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  BackgroundTask? _sendTask;
  BackgroundTask? _receiveTask;

  /// Transfers are background tasks, for their notifications and for the app
  /// to stay up while they run.
  void _trackTransfers() {
    final send = sendSession;
    if (send != null && send.state == LsSendState.sending) {
      final task = _sendTask ??= BackgroundTasks.instance.start(
        'Sending files',
        headline: 'Upload in progress',
        kind: TaskKind.upload,
        onCancel: () => unawaited(cancelSend()),
      );
      final sending = send.files.values.where((f) => f.status == LsSendFileStatus.sending);
      task.update(
        message: sending.firstOrNull?.file.fileName ?? task.message,
        progress: send.totalBytes > 0 ? send.sentBytes / send.totalBytes : null,
        detail: '${filesize(send.sentBytes, 1)}/${filesize(send.totalBytes, 1)}',
      );
    } else if (_sendTask != null) {
      _endTask(_sendTask, switch (send?.state) {
        LsSendState.finished => TaskStatus.done,
        LsSendState.cancelled || LsSendState.cancelledByReceiver || null => TaskStatus.cancelled,
        _ => TaskStatus.failed,
      });
      _sendTask = null;
    }

    final receive = receiveSession;
    if (receive != null && receive.isActive) {
      final task = _receiveTask ??= BackgroundTasks.instance.start(
        'Receiving files',
        headline: 'Download in progress',
        kind: TaskKind.download,
        onCancel: () => unawaited(cancelReceive()),
      );
      final receiving = receive.files.values.where((f) => f.status == LsReceiveFileStatus.receiving);
      task.update(
        message: receiving.firstOrNull?.dto.fileName ?? task.message,
        progress: receive.totalBytes > 0 ? receive.receivedBytes / receive.totalBytes : null,
        detail: '${filesize(receive.receivedBytes, 1)}/${filesize(receive.totalBytes, 1)}',
      );
    } else if (_receiveTask != null) {
      _endTask(_receiveTask, switch (receive?.state) {
        LsReceiveState.finished => TaskStatus.done,
        LsReceiveState.stalled => TaskStatus.failed,
        _ => TaskStatus.cancelled,
      });
      _receiveTask = null;
    }
  }

  void _endTask(BackgroundTask? task, TaskStatus status) {
    if (task == null) return;
    switch (status) {
      case TaskStatus.done:
        BackgroundTasks.instance.finish(task, message: 'Done');
      case TaskStatus.failed:
        BackgroundTasks.instance.fail(task, "The transfer didn't finish");
      case TaskStatus.running || TaskStatus.cancelled:
        BackgroundTasks.instance.cancelled(task);
    }
  }

  /// Progress events arrive many times per second: repaint at most ~8x/s.
  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) {
      _dirty = true;
      return;
    }
    _notify();
    _notifyTimer = Timer(const Duration(milliseconds: 120), () {
      if (_dirty) {
        _dirty = false;
        _notify();
      }
    });
  }

  // ------------------------------------------------------------ items

  Future<void> _collect() async {
    final generation = ++_collectGeneration;
    sendFiles = null;
    _notify();
    final files = await LsSendFile.collect(items);
    if (generation != _collectGeneration || _disposed) return;
    sendFiles = files;
    _notify();
  }

  void addItems(Iterable<FileSystemEntity> entities) {
    final known = items.map((e) => p.normalize(e.path)).toSet();
    for (final e in entities) {
      if (known.add(p.normalize(e.path))) items.add(e);
    }
    unawaited(_collect());
  }

  void removeItem(FileSystemEntity entity) {
    items.removeWhere((e) => e.path == entity.path);
    unawaited(_collect());
  }

  void clearItems() {
    items.clear();
    unawaited(_collect());
  }

  /// Number of files and bytes under a top-level item.
  (int, int) statsFor(FileSystemEntity entity) {
    final files = sendFiles;
    if (files == null) return (0, 0);
    if (entity is File) {
      final match = files.where((f) => f.path == entity.path);
      return (match.length, match.fold(0, (s, f) => s + f.size));
    }
    final prefix = '${p.basename(p.normalize(entity.path))}/';
    final root = p.normalize(entity.path);
    final match = files.where(
      (f) => f.fileName.startsWith(prefix) && p.isWithin(root, f.path),
    );
    return (match.length, match.fold(0, (s, f) => s + f.size));
  }

  // ------------------------------------------------------------ sending

  /// Starts sending to [device]. Returns an error message, or null.
  String? sendTo(LsDevice device) {
    final service = _service;
    final files = sendFiles;
    if (service == null) return 'Nearby sharing is not running.';
    if (files == null) return 'Still counting the selected files…';
    if (files.isEmpty) return 'Add files or folders to send first.';
    final current = service.sendSession;
    if (current != null && !current.isDone) {
      return 'Wait for the current transfer to finish.';
    }
    service.startSend(device, files, askPin: pinPrompt);
    _notify();
    return null;
  }

  Future<void> cancelSend() async => _service?.sendSession?.cancel();

  void dismissSend() => _service?.clearSendSession();

  // ------------------------------------------------------------ devices

  Future<void> refresh() async => _service?.refreshDevices();

  Future<void> scan() async => _service?.discovery.scan();

  /// Adds a device by address; returns the device or throws [LsException].
  Future<LsDevice> addByAddress(String address) async {
    final service = _service;
    if (service == null) {
      throw const LsException(LsErrorKind.unknown, 'not running');
    }
    return service.addDevice(address);
  }

  // ------------------------------------------------------------ receiving

  Future<LsReceiveDecision> _onIncoming(LsIncomingRequest request) {
    final handler = incomingHandler;
    if (handler == null || _disposed) {
      return Future.value(const LsReceiveDecision.decline());
    }
    return handler(request);
  }

  void _onReceiveFinished(LsReceiveSession session) {
    for (final f in session.files.values) {
      final path = f.savedPath;
      if (path == null) continue;
      received.insert(
        0,
        LsReceivedItem(
          path: path,
          fileName: f.dto.fileName,
          size: f.dto.size,
          from: session.sender.alias,
          at: session.endedAt ?? DateTime.now(),
        ),
      );
    }
    _notify();
  }

  Future<void> cancelReceive() async => _service?.cancelReceive();

  Future<void> trust(LsDeviceInfo device) async {
    if (device.fingerprint.isEmpty) return;
    trusted[device.fingerprint.toUpperCase()] = device.alias;
    await LsSettingsStore.saveTrusted(trusted);
    _notify();
  }

  Future<void> forgetTrusted() async {
    trusted = {};
    await LsSettingsStore.saveTrusted(trusted);
    _notify();
  }

  void removeReceived(LsReceivedItem item) {
    received.remove(item);
    _notify();
  }

  // ------------------------------------------------------------ settings

  Future<void> applySettings(LsSettings next) async {
    final service = _service;
    if (service == null) return;
    await LsSettingsStore.save(next);
    destinationFallback = false;
    await service.applySettings(next);
    _notify();
  }

  Future<void> retryServer() async {
    await _service?.restartServer();
    _notify();
  }
}
