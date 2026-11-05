import 'dart:async';
import 'dart:io';

import 'package:explorer/core/services/background_tasks.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

/// Android: what goes on in the app, in the notification shade. [BackgroundTasks]
/// show on their own, with a bar in the theme's colours; Wi-Fi sharing has its
/// own. While any of them is up a foreground service keeps the app running
/// behind it (BackgroundWorkService.kt), so they go on with the app in the
/// background and the screen off.
class TaskNotifications {
  TaskNotifications._();

  static final instance = TaskNotifications._();

  static const _channel = MethodChannel('explorer/notifications');

  static const sharingId = 1;
  static const _taskIds = 1000;
  static const _finishedIds = 5000;

  /// Instead of the native side, in tests.
  @visibleForTesting
  static Future<void> Function(String method, Map<String, Object?> args)? sender;

  /// Whether the app is in front, in tests.
  @visibleForTesting
  static bool? inFrontOverride;

  bool get _enabled => sender != null || Platform.isAndroid;

  bool get _inFront =>
      inFrontOverride ?? WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  final _onAction = <int, VoidCallback>{};

  /// Tasks seen by the clock's last tick: a task that ends before the next
  /// one was too quick to be worth a notification.
  final _seen = <int>{};
  final _shown = <int>{};
  final _last = <int, Map<String, Object?>>{};
  Timer? _ticker;
  Color? _primary;
  bool _asked = false;

  void init() {
    if (!_enabled) return;
    if (sender == null) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'action') press(call.arguments as int);
      });
    }
    BackgroundTasks.instance.addListener(_changed);
  }

  /// The colours of the bars follow the theme's. The native side keeps them,
  /// for the video downloader's notifications too.
  void setTheme(Color primary) {
    if (!_enabled || primary == _primary) return;
    _primary = primary;
    final colors = AppTheme.gradientOf(primary);
    _send('colors', {'from': colors.first.toARGB32(), 'to': colors.last.toARGB32()});
  }

  /// Shows or updates a notification: [title], and with [progress] or
  /// [waiting] a bar, then [name] and [detail] under it; [text] without one.
  /// [route] is the screen a tap opens (see `IncomingRoute`), [action] a button
  /// calling [onAction].
  void show(
    int id, {
    required String title,
    String name = '',
    String detail = '',
    double? progress,
    bool bar = true,
    String icon = 'work',
    String? route,
    String? action,
    VoidCallback? onAction,
    bool ongoing = true,
  }) {
    if (!_enabled) return;
    if (onAction != null) {
      _onAction[id] = onAction;
    } else {
      _onAction.remove(id);
    }
    final args = <String, Object?>{
      'id': id,
      'title': title,
      'name': name,
      'detail': detail,
      'progress': progress,
      'bar': bar,
      'icon': icon,
      'route': route,
      'action': action,
      'ongoing': ongoing,
    };
    if (mapEquals(_last[id], args)) return;
    _last[id] = args;
    _askOnce();
    _send('show', args);
  }

  /// Notification [id]'s button was pressed.
  @visibleForTesting
  void press(int id) => _onAction[id]?.call();

  void cancel(int id) {
    if (!_enabled) return;
    _onAction.remove(id);
    _last.remove(id);
    _send('cancel', {'id': id});
  }

  Future<void> _send(String method, Map<String, Object?> args) async {
    final test = sender;
    if (test != null) return test(method, args);
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      debugPrint('Notification failed: $e');
    }
  }

  /// Android 13 and newer ask the first time there's something to show; only
  /// with the app in front, where the question can be seen.
  Future<void> _askOnce() async {
    if (_asked || sender != null || !_inFront) return;
    _asked = true;
    if (await Permission.notification.isDenied) await Permission.notification.request();
  }

  void _changed() {
    _endFinished();
    if (BackgroundTasks.instance.hasRunning) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  void _tick() {
    final tasks = BackgroundTasks.instance;
    final running = tasks.running;
    for (final task in running) {
      if (_seen.add(task.id)) continue;
      _shown.add(task.id);
      show(
        _taskIds + task.id,
        title: task.headline ?? task.title,
        name: task.message,
        detail: task.detail,
        progress: task.progress,
        icon: task.kind.name,
        action: task.canCancel ? 'Cancel' : null,
        onAction: task.canCancel ? task.cancel : null,
      );
    }
    if (running.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _endFinished() {
    final tasks = BackgroundTasks.instance.all;
    for (final id in _seen.toList()) {
      final task = tasks.where((t) => t.id == id).firstOrNull;
      if (task != null && task.isRunning) continue;
      _seen.remove(id);
      if (!_shown.remove(id)) continue;
      cancel(_taskIds + id);
      // In front, the app's own dock says how it ended.
      if (task != null && !_inFront && task.status != TaskStatus.cancelled) {
        final failed = task.status == TaskStatus.failed;
        show(
          _finishedIds + id,
          title: _finishedTitle(task, failed: failed),
          name: task.message,
          bar: false,
          icon: failed ? 'failed' : 'done',
          ongoing: false,
        );
      }
    }
  }

  static String _finishedTitle(BackgroundTask task, {required bool failed}) {
    const suffix = ' in progress';
    final headline = task.headline;
    final ending = failed ? 'failed' : 'finished';
    if (headline == null || !headline.endsWith(suffix)) return '${task.title}: $ending';
    return '${headline.substring(0, headline.length - suffix.length)} $ending';
  }

  @visibleForTesting
  void reset() {
    BackgroundTasks.instance.removeListener(_changed);
    _ticker?.cancel();
    _ticker = null;
    _seen.clear();
    _shown.clear();
    _last.clear();
    _onAction.clear();
    _primary = null;
    _asked = false;
  }
}
