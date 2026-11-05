import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:folder/core/build_features.dart';
import 'package:folder/core/platform/desktop.dart';
import 'package:folder/core/services/background_tasks.dart';
import 'package:folder/core/services/video_downloader/video_downloader_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// What closing the window does while work is going on (desktop):
/// conversions, copies or downloads carry on, and only a Tasks view is
/// left. On Windows the window hides to the notification area, and the
/// icon there shows the tasks again; on Linux and macOS the window shrinks
/// to the Tasks view and closes itself once everything is done. On macOS
/// Cmd+Q, Quit in the Dock and logging out go the same way as the close
/// button the first time, and quit when asked again.
class BackgroundMode extends ChangeNotifier with WindowListener {
  BackgroundMode._();

  static final instance = BackgroundMode._();

  static const _tray = MethodChannel('explorer/tray');
  static const _tasksSize = Size(460, 560);

  /// The window shows only the tasks.
  bool get tasksOnly => _tasksOnly;
  bool _tasksOnly = false;

  bool _hidden = false;
  bool _quitting = false;
  bool _exitRefused = false;
  Rect? _bounds;
  Timer? _closeWhenDone;

  /// Whether anything would stop if the app quit.
  bool get busy {
    if (BackgroundTasks.instance.hasRunning) return true;
    if (kVideoDownloaderEnabled && VideoDownloaderController.instance.isStarted) {
      return VideoDownloaderController.instance.activeCount > 0;
    }
    return false;
  }

  int get _running =>
      BackgroundTasks.instance.running.length +
      (kVideoDownloaderEnabled && VideoDownloaderController.instance.isStarted
          ? VideoDownloaderController.instance.activeCount
          : 0);

  Future<void> init() async {
    if (!Desktop.isDesktop) return;
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    // macOS asks to quit without closing the window (Cmd+Q, the Dock,
    // logging out). The listener stays registered with the binding.
    if (Platform.isMacOS) AppLifecycleListener(onExitRequested: exitRequested);
    if (Platform.isWindows) {
      _tray.setMethodCallHandler((call) async {
        switch (call.method) {
          case 'clicked':
            await showTasks();
          case 'open':
            await openExplorer();
          case 'quit':
            await quit();
        }
      });
    }
    BackgroundTasks.instance.addListener(_changed);
    if (kVideoDownloaderEnabled) VideoDownloaderController.instance.addListener(_changed);
  }

  @override
  void onWindowClose() => unawaited(close());

  /// macOS asks to quit: while work goes on the Tasks view is shown
  /// instead, as for the close button; [quit] always gets through. Asked
  /// again with the Tasks view up, it quits: the user has seen what would
  /// stop, and logging out or shutting down isn't held up for good.
  @visibleForTesting
  Future<AppExitResponse> exitRequested() async {
    if (_quitting || !busy || (_tasksOnly && _exitRefused)) return AppExitResponse.exit;
    _exitRefused = true;
    unawaited(close());
    return AppExitResponse.cancel;
  }

  /// The window's close button (or the Tasks view's Close).
  Future<void> close() async {
    if (!busy) return quit();
    if (!_tasksOnly) {
      _bounds = await windowManager.getBounds();
      _tasksOnly = true;
      notifyListeners();
    }
    if (Platform.isWindows) {
      _hidden = true;
      await windowManager.hide();
      await _tray.invokeMethod('show', {'tooltip': _tooltip});
      await _tray.invokeMethod('notify', {
        'title': 'Folder is still working',
        'text': _running == 1
            ? 'A task is still running. Click here to see it.'
            : '$_running tasks are still running. Click here to see them.',
      });
    } else {
      // macOS: Quit in the Dock works while the window is minimized or
      // hidden, so it's brought back.
      if (Platform.isMacOS) await windowManager.show();
      await windowManager.setSize(_tasksSize);
      await windowManager.center();
    }
  }

  /// Shows the Tasks view (the tray icon was clicked).
  Future<void> showTasks() async {
    if (!_tasksOnly) {
      _bounds = await windowManager.getBounds();
      _tasksOnly = true;
      notifyListeners();
    }
    _hidden = false;
    await windowManager.setSize(_tasksSize);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }

  /// Back to the whole app.
  Future<void> openExplorer() async {
    _closeWhenDone?.cancel();
    _tasksOnly = false;
    _hidden = false;
    _exitRefused = false;
    notifyListeners();
    final bounds = _bounds;
    if (bounds != null) await windowManager.setBounds(bounds);
    await windowManager.show();
    await windowManager.focus();
    if (Platform.isWindows) await _tray.invokeMethod('hide');
  }

  Future<void> quit() async {
    // On macOS destroy() asks to quit again, through [exitRequested].
    _quitting = true;
    // Gone at once: shutting the engine and plugins down takes seconds
    // (about 4 on Windows), and the window would stay up meanwhile.
    await windowManager.hide();
    if (Platform.isWindows) await _tray.invokeMethod('hide');
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  String get _tooltip => busy
      ? (_running == 1 ? 'Folder: 1 task running' : 'Folder: $_running tasks running')
      : 'Folder: all done';

  void _changed() {
    if (!_tasksOnly) return;
    if (Platform.isWindows) {
      if (_hidden) {
        unawaited(_tray.invokeMethod('show', {'tooltip': _tooltip}));
        if (!busy) {
          unawaited(_tray.invokeMethod('notify', {
            'title': 'Folder is done',
            'text': 'Everything finished. Click here to see it.',
          }));
        }
      }
      return;
    }
    // Linux and macOS: the Tasks window closes itself when everything is
    // done.
    _closeWhenDone?.cancel();
    if (!busy) {
      _closeWhenDone = Timer(const Duration(seconds: 4), () {
        if (_tasksOnly && !busy) unawaited(quit());
      });
    }
  }
}
