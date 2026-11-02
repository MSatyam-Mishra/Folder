import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:io';
import 'dart:isolate';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/services/thumbnails/windows_shell_thumbnail.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// The icons the system itself shows for folders and drives, asked for
/// while running: File Explorer's on Windows, Finder's on a Mac. They're
/// the system's own, so they match it exactly, and none are bundled.
abstract final class SystemIcons {
  static final bool supported = (Platform.isWindows || Platform.isMacOS) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  static const _channel = MethodChannel('explorer/system_icons');

  /// This PC, for the shell.
  static const _thisPc = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}';

  /// Sizes icons are asked for: the ones Windows draws icons at, so they
  /// stay sharp, and steps above them.
  static const _sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];

  static int _sizeFor(int pixels) => _sizes.firstWhere((s) => s >= pixels, orElse: () => _sizes.last);

  static final _icons = <String, Uint8List?>{};
  static final _pending = <String, Future<Uint8List?>>{};
  static final _plain = <int, Uint8List?>{};
  static final _plainPending = <int, Future<Uint8List?>>{};

  /// What can be shown for [path] at once: its icon if asked for before,
  /// else (for folders) the plain folder's.
  static Uint8List? known(String path, int pixels) {
    final size = _sizeFor(pixels);
    final key = '$path|$size';
    if (_icons.containsKey(key)) return _icons[key];
    return _isVirtualOrDrive(path) ? null : _plain[size];
  }

  /// [path]'s icon, [pixels] wide or a little more; null if the system
  /// gives none.
  static Future<Uint8List?> load(String path, int pixels) async {
    final size = _sizeFor(pixels);
    final key = '$path|$size';
    if (_icons.containsKey(key)) return _icons[key];
    return _pending[key] ??= _load(path, size).then((bytes) {
      _pending.remove(key);
      _icons[key] = bytes;
      return bytes;
    });
  }

  static bool _isVirtualOrDrive(String path) =>
      ExplorerPaths.isWindowsRoots(path) || ExplorerPaths.isDriveRoot(path);

  static Future<Uint8List?> _load(String path, int size) async {
    if (ExplorerPaths.isWindowsRoots(path)) return _fetch(_thisPc, size);
    if (Platform.isWindows && !ExplorerPaths.isDriveRoot(path)) {
      // Folders with an icon of their own (Documents, Downloads...) say so
      // in a desktop.ini, or are the user's own folder; the rest share one,
      // asked for once.
      final profile = Platform.environment['USERPROFILE'];
      final own = (profile != null && p.equals(path, profile)) ||
          await File(p.join(path, 'desktop.ini')).exists();
      if (!own) return _plainFolder(size);
    }
    return _fetch(path, size);
  }

  static Future<Uint8List?> _plainFolder(int size) async {
    if (_plain.containsKey(size)) return _plain[size];
    return _plainPending[size] ??= _fetch(Directory.systemTemp.path, size).then((bytes) {
      _plainPending.remove(size);
      _plain[size] = bytes;
      return bytes;
    });
  }

  static int _running = 0;
  static final _waiting = Queue<Completer<void>>();

  /// A few at a time.
  static Future<Uint8List?> _fetch(String source, int size) async {
    if (_running >= 3) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      if (Platform.isWindows) return await Isolate.run(() => windowsShellIcon(source, size));
      return await _channel.invokeMethod<Uint8List>('icon', {'path': source, 'size': size});
    } catch (_) {
      return null;
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}
