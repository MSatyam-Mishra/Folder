import 'dart:io';

import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/social_files.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:path/path.dart' as p;

/// Cross-platform paths for the file explorer home and navigation.
abstract final class ExplorerPaths {
  static const String androidInternalStorage = '/storage/emulated/0';

  /// Virtual folder listing drives + libraries on Windows.
  static const String windowsRoots = 'explorer://windows-roots';

  static const String _categoryPrefix = 'explorer://category/';

  /// A category (Video, Documents...) as a folder holding its files.
  static String categoryPath(String name) => '$_categoryPrefix$name';

  static bool isCategory(String path) => path.startsWith(_categoryPrefix);

  static const String _socialPrefix = 'explorer://social/';

  /// What an app has saved (WhatsApp...): all of it, or one [tab] of it.
  static String socialPath(String app, [String? tab]) =>
      '$_socialPrefix$app${tab == null ? '' : '/${Uri.encodeComponent(tab)}'}';

  static bool isSocial(String path) => path.startsWith(_socialPrefix);

  /// The app of a [socialPath].
  static String? socialAppOf(String path) =>
      isSocial(path) ? path.substring(_socialPrefix.length).split('/').first : null;

  /// The tab of a [socialPath]; null for all its files.
  static String? socialTabOf(String path) {
    if (!isSocial(path)) return null;
    final parts = path.substring(_socialPrefix.length).split('/');
    return parts.length > 1 ? Uri.decodeComponent(parts[1]) : null;
  }

  /// What's in the Trash (the Recycle Bin on Windows), as a folder.
  static const String trash = 'explorer://trash';

  static bool isTrash(String path) => path == trash;

  /// Listed by the app, not a folder on disk: nothing can be created or
  /// pasted there, and it has no folder to watch.
  static bool isVirtual(String path) =>
      isWindowsRoots(path) || isCategory(path) || isSocial(path) || TagPaths.isTag(path) || isTrash(path);

  /// On a network place (`explorer://remote/<id>/<path>`): a real folder,
  /// where folders can be made and files pasted, but not through dart:io.
  static bool isRemote(String path) => RemotePaths.isRemote(path);

  /// The top of a network place: going up from it leaves the place.
  static bool isRemoteRoot(String path) => RemotePaths.parse(path)?.$2 == '/';

  /// A folder on this device's disks: neither virtual nor on a network
  /// place. What reads or writes with dart:io needs one.
  static bool isLocal(String path) => !isVirtual(path) && !isRemote(path);

  /// Whether the category [name] opens as such a folder: on computers,
  /// where its files are plain files. macOS's photos and videos are in the
  /// Photos library and phones have their media library; those keep their
  /// own screens.
  static bool categoryIsFolder(String name) => switch (name) {
        'Audio' || 'Documents' || 'Archives' => isDesktop,
        'Photos' || 'Video' => Platform.isWindows || Platform.isLinux,
        _ => false,
      };

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

  /// The user's own folder, a real one on every system, for anything that reads
  /// or writes files: on Windows [homePath] is This PC, which isn't on disk.
  static String get userFolder {
    if (Platform.isWindows) return Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return homePath;
  }

  /// Whether [path] can be a folder on disk. On Windows a path with no drive,
  /// as Git Bash writes them (/c/Users), means the root of the current drive, so
  /// creating it would leave a stray C:\c behind.
  static bool isOnDisk(String path) => isLocal(path) && (!Platform.isWindows || isFullWindowsPath(path));

  static bool isFullWindowsPath(String path) => p.windows.isAbsolute(path) && !p.windows.isRootRelative(path);

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
    if (isCategory(path) || TagPaths.isTag(path) || isTrash(path)) return homePath;
    if (isRemote(path)) {
      final (id, remote) = RemotePaths.parse(path) ?? ('', '/');
      return remote == '/' ? homePath : RemotePaths.build(id, RemotePaths.parentOf(remote));
    }
    if (isSocial(path)) {
      return socialTabOf(path) == null ? homePath : socialPath(socialAppOf(path)!);
    }
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
    if (isTrash(path)) return Platform.isWindows ? 'Recycle Bin' : 'Trash';
    if (isCategory(path)) return path.substring(_categoryPrefix.length);
    if (TagPaths.isTag(path)) return TagPaths.nameOf(path)!;
    if (isSocial(path)) return socialTabOf(path) ?? SocialApp.byId(socialAppOf(path)!)?.label ?? 'Files';
    if (isRemote(path)) {
      final (id, remote) = RemotePaths.parse(path) ?? ('', '/');
      return remote == '/' ? RemotePlaces.instance.byId(id)?.name ?? 'Network place' : RemotePaths.nameOf(remote);
    }
    if (Platform.isAndroid && path == androidInternalStorage) return 'Files';
    if (isDriveRoot(path)) {
      return 'Local Disk (${path[0].toUpperCase()}:)';
    }
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }

  static String displayNameForEntity(String path, {String? label}) {
    if (label != null && label.isNotEmpty) return label;
    if (isRemote(path)) return titleForPath(path);
    if (isDriveRoot(path)) return titleForPath(path);
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }
}
