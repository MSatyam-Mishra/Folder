import 'dart:io';

import 'package:photo_manager/photo_manager.dart' show RequestType;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:explorer/core/services/device_files.dart';
import 'package:explorer/features/category_view/home_media.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/platform/macos_files.dart';
import 'package:explorer/core/platform/windows_locations.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/services/social_files.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart'
    show FILE_ATTRIBUTE_HIDDEN, FILE_ATTRIBUTE_SYSTEM, GetFileAttributes;

/// Abstract repository to handle file system operations.
/// This allows us to swap implementations for Root or Network access later.
abstract class FileRepository {
  Future<List<FileSystemEntity>> listEntities(String path);
  Future<void> delete(String path, {bool recursive = false});
  Future<void> rename(String path, String newPath);
  Future<bool> exists(String path);
  Future<FileSystemEntityType> type(String path);
  Future<void> createDirectory(String path);
  Future<void> createFile(String path);
  Future<List<Directory>> getStorageVolumes();
}

class LocalFileRepository implements FileRepository {
  /// The files of a category; tests replace it.
  @visibleForTesting
  static Future<List<FileSystemEntity>> Function(String name) categoryFiles = _findCategory;

  static Future<List<FileSystemEntity>> _findCategory(String name) async {
    final files = await switch (name) {
      'Photos' => HomeMedia.find(RequestType.image),
      'Video' => HomeMedia.find(RequestType.video),
      'Audio' => HomeMedia.find(RequestType.audio),
      'Documents' => DeviceFiles.find(DeviceFileGroup.documents),
      'Archives' => DeviceFiles.find(DeviceFileGroup.archives),
      _ => Future.value(const <DeviceFile>[]),
    };
    return [for (final file in files) File(file.path)];
  }

  @override
  Future<List<FileSystemEntity>> listEntities(String path) async {
    if (ExplorerPaths.isCategory(path)) {
      return categoryFiles(ExplorerPaths.titleForPath(path));
    }
    if (ExplorerPaths.isSocial(path)) return SocialFiles.list(path);
    if (ExplorerPaths.isWindowsRoots(path)) {
      final locations = await WindowsLocations.listAll();
      final entities = <FileSystemEntity>[];
      for (final location in locations) {
        if (await Directory(location.path).exists()) {
          entities.add(Directory(location.path));
        }
      }
      return entities;
    }

    final dir = Directory(path);
    if (!await dir.exists()) {
      throw FileSystemException("Directory not found", path);
    }
    final entries = await dir.list().toList();
    final prefs = FolderPrefsService();
    await prefs.init();
    if (prefs.showHidden) return entries;
    return [for (final e in entries) if (!isHidden(e.path)) e];
  }

  /// Dotfiles, on Windows files marked hidden or system
  /// (`$Recycle.Bin`, `pagefile.sys`, `desktop.ini`...), and on macOS what
  /// Finder hides (`~/Library`, `/usr`, `/bin`...). Works in any isolate.
  static bool isHidden(String path) {
    if (p.basename(path).startsWith('.')) return true;
    if (Platform.isMacOS) return MacosFiles.isHidden(path);
    if (!Platform.isWindows) return false;
    final name = path.toNativeUtf16();
    try {
      final attributes = GetFileAttributes(name);
      // 0xFFFFFFFF: INVALID_FILE_ATTRIBUTES (unreadable); keep it listed.
      if (attributes == 0xFFFFFFFF) return false;
      return attributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM) != 0;
    } finally {
      calloc.free(name);
    }
  }

  /// Display labels for entries under [ExplorerPaths.windowsRoots].
  Future<Map<String, String>> windowsRootLabels() async {
    final labels = <String, String>{};
    for (final location in await WindowsLocations.listAll()) {
      labels[location.path] = location.displayName;
    }
    return labels;
  }

  @override
  Future<List<Directory>> getStorageVolumes() async {
    if (Platform.isWindows) {
      final drives = await WindowsLocations.listDrives();
      return drives.map((d) => Directory(d.path)).toList();
    }

    if (!Platform.isAndroid) return [];

    final storageRoot = Directory('/storage');
    // We check detecting volumes
    try {
      if (!await storageRoot.exists()) return [];

      final entities = await storageRoot.list().toList();
      final volumes = <Directory>[];

      for (final entity in entities) {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          // Filter out emulated (internal) and self
          if (name != 'emulated' && name != 'self') {
            volumes.add(entity);
          }
        }
      }
      return volumes;
    } catch (e) {
      print("Error scanning storage: $e");
      return [];
    }
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    }
  }

  @override
  Future<void> rename(String path, String newPath) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      await File(path).rename(newPath);
    } else if (type == FileSystemEntityType.directory) {
      await Directory(path).rename(newPath);
    }
  }

  @override
  Future<bool> exists(String path) {
    if (ExplorerPaths.isVirtual(path)) {
      return Future.value(true);
    }
    return FileSystemEntity.type(
      path,
    ).then((type) => type != FileSystemEntityType.notFound);
  }

  @override
  Future<FileSystemEntityType> type(String path) {
    return FileSystemEntity.type(path);
  }

  @override
  Future<void> createDirectory(String path) async {
    await Directory(path).create(recursive: true);
  }

  @override
  Future<void> createFile(String path) async {
    await File(path).create(recursive: true);
  }
}
