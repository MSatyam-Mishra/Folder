import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/search/smart_query.dart';
import 'package:folders/core/services/social_files.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Where "Search everywhere" and places such as "downloads" look.
abstract final class SearchPlaces {
  /// The system's own folders on the Windows drive: nothing of the user's
  /// is there, and they hold hundreds of thousands of files.
  static const _windowsSystemFolders = {
    'windows', 'program files', 'program files (x86)', 'programdata', 'users', 'perflogs',
    'recovery', r'$recycle.bin', 'system volume information', r'$windows.~bt', r'$windows.~ws',
    r'$winreagent', 'msocache', 'config.msi', 'onedrivetemp',
  };

  /// The folders "everywhere" means: the home folder and the other drives
  /// (USB sticks and memory cards too, not network or DVD drives). On
  /// Windows also the system drive's own folders, less the system's.
  static Future<List<String>> everywhere() => everywhereOverride?.call() ?? Isolate.run(_everywhere);

  /// Tests search a folder of theirs instead of the whole computer.
  @visibleForTesting
  static Future<List<String>> Function()? everywhereOverride;

  static List<String> _everywhere() {
    final roots = <String>[];
    void addChildren(String folder, {Set<String> except = const {}}) {
      try {
        for (final entry in Directory(folder).listSync(followLinks: false)) {
          if (entry is Directory && !except.contains(p.basename(entry.path).toLowerCase())) roots.add(entry.path);
        }
      } on FileSystemException {
        // Not there, or not readable.
      }
    }

    if (Platform.isWindows) {
      roots.add(ExplorerPaths.userFolder);
      final system = (Platform.environment['SystemDrive'] ?? 'C:').toUpperCase();
      for (final drive in _windowsDrives()) {
        if (drive.toUpperCase().startsWith(system)) {
          addChildren(drive, except: _windowsSystemFolders);
        } else {
          roots.add(drive);
        }
      }
    } else if (Platform.isAndroid) {
      roots.add(ExplorerPaths.androidInternalStorage);
      try {
        for (final entry in Directory('/storage').listSync(followLinks: false)) {
          final name = p.basename(entry.path);
          if (entry is Directory && name != 'emulated' && name != 'self') roots.add(entry.path);
        }
      } on FileSystemException {
        // Only internal storage, then.
      }
    } else {
      roots.add(ExplorerPaths.userFolder);
      if (Platform.isMacOS) {
        // The start-up disk is a link to / there.
        addChildren('/Volumes');
      } else {
        final user = Platform.environment['USER'] ?? '';
        if (user.isNotEmpty) {
          addChildren('/media/$user');
          addChildren('/run/media/$user');
        }
        addChildren('/mnt');
      }
    }
    return outermost(roots);
  }

  static List<String> _windowsDrives() {
    final drives = <String>[];
    for (var code = 0x41; code <= 0x5A; code++) {
      final root = '${String.fromCharCode(code)}:\\';
      final type = using((arena) => GetDriveType(root.toNativeUtf16(allocator: arena)));
      if (type == DRIVE_FIXED || type == DRIVE_REMOVABLE) drives.add(root);
    }
    return drives;
  }

  /// [folders] without those inside another of them, or twice.
  static List<String> outermost(List<String> folders) {
    final kept = <String>[];
    for (final folder in folders) {
      if (folders.any((other) => other != folder && p.isWithin(other, folder))) continue;
      if (kept.any((other) => p.equals(other, folder))) continue;
      kept.add(folder);
    }
    return kept;
  }

  static String get _storage => Platform.isAndroid ? ExplorerPaths.androidInternalStorage : ExplorerPaths.userFolder;

  /// [place]'s folders on this system, where they exist: a file in one is
  /// "in" the place.
  static List<String> foldersFor(SearchPlace place) {
    final s = _storage;
    final android = Platform.isAndroid;
    final List<String> folders = switch (place) {
      SearchPlace.downloads => [android ? p.join(s, 'Download') : p.join(s, 'Downloads')],
      SearchPlace.screenshots => android
          ? [p.join(s, 'Pictures', 'Screenshots'), p.join(s, 'DCIM', 'Screenshots')]
          : [p.join(s, 'Pictures', 'Screenshots'), if (Platform.isWindows) p.join(s, 'OneDrive', 'Pictures', 'Screenshots')],
      SearchPlace.camera => android
          ? [p.join(s, 'DCIM')]
          : [if (Platform.isWindows) p.join(s, 'Pictures', 'Camera Roll')],
      SearchPlace.whatsapp => SocialFiles.folders(SocialApp.whatsapp),
      SearchPlace.telegram => SocialFiles.folders(SocialApp.telegram),
      SearchPlace.instagram => SocialFiles.folders(SocialApp.instagram),
      SearchPlace.twitter => SocialFiles.folders(SocialApp.twitter),
    };
    return [for (final folder in folders) if (Directory(folder).existsSync()) folder];
  }

  /// Where to look for [place]'s files: its folders, and on a Mac the
  /// Desktop, where screenshots go (they're known there by their names).
  static List<String> rootsFor(SearchPlace place) => [
        ...foldersFor(place),
        if (place == SearchPlace.screenshots && Platform.isMacOS && Directory(p.join(_storage, 'Desktop')).existsSync())
          p.join(_storage, 'Desktop'),
      ];
}
