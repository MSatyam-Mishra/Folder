import 'dart:io';

import 'package:path/path.dart' as p;

/// Cross-platform paths for the file explorer home and navigation.
abstract final class ExplorerPaths {
  static const String androidInternalStorage = '/storage/emulated/0';

  /// Virtual folder listing drives + libraries on Windows.
  static const String windowsRoots = 'explorer://windows-roots';

  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// The folder to start in instead of the usual home (a new desktop
  /// window, or a folder passed on the command line).
  static String? startFolder;

  static String get initialPath => startFolder ?? homePath;

  /// Where browsing starts: This PC on Windows, internal storage on
  /// Android, the home folder elsewhere. New tabs open here.
  static String get homePath {
    if (Platform.isWindows) return windowsRoots;
    if (Platform.isAndroid) return androidInternalStorage;
    return Platform.environment['HOME'] ?? '/';
  }

  static bool isWindowsRoots(String path) => path == windowsRoots;

  static bool isAppRoot(String path) {
    if (Platform.isWindows) return isWindowsRoots(path);
    if (Platform.isAndroid) return path == androidInternalStorage;
    return false;
  }

  static bool isDriveRoot(String path) {
    if (!Platform.isWindows) return false;
    return RegExp(r'^[A-Za-z]:\\$').hasMatch(path);
  }

  /// Parent path for back navigation; returns null when already at app root.
  static String? parentOf(String path) {
    if (isAppRoot(path)) return null;
    if (Platform.isWindows && isDriveRoot(path)) return windowsRoots;

    final parent = p.dirname(path);
    if (parent.isEmpty || parent == path || parent == '.') {
      return Platform.isWindows ? windowsRoots : null;
    }
    if (Platform.isWindows && isDriveRoot(parent)) return windowsRoots;
    return parent;
  }

  static String titleForPath(String path) {
    if (isWindowsRoots(path)) return 'This PC';
    if (Platform.isAndroid && path == androidInternalStorage) return 'Files';
    if (isDriveRoot(path)) {
      return 'Local Disk (${path[0].toUpperCase()}:)';
    }
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }

  static String displayNameForEntity(String path, {String? label}) {
    if (label != null && label.isNotEmpty) return label;
    if (isDriveRoot(path)) return titleForPath(path);
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }
}
