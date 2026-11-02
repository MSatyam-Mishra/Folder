import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:win32/win32.dart';
import 'package:ffi/ffi.dart';
import 'package:bootstrap_icons/bootstrap_icons.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// A drive letter root or a known user library folder on Windows.
class WindowsStorageLocation {
  const WindowsStorageLocation({
    required this.displayName,
    required this.path,
    required this.kind,
    required this.icon,
  });

  final String displayName;
  final String path;
  final WindowsStorageKind kind;
  final IconData icon;
}

enum WindowsStorageKind { drive, library }

/// How much a drive holds, in bytes.
class DriveSpace {
  const DriveSpace(this.free, this.total);

  final int free;
  final int total;
}

abstract final class WindowsLocations {
  WindowsLocations._();

  /// Free and total space of the drive at [root]; null if unknown.
  static Future<DriveSpace?> spaceOf(String root) async {
    if (!Platform.isWindows) return null;
    // In the background: a sleeping or network drive can take a while.
    return Isolate.run(() => using((arena) {
          final free = arena<Uint64>();
          final total = arena<Uint64>();
          final ok = GetDiskFreeSpaceEx(root.toNativeUtf16(allocator: arena), free, total, nullptr);
          return ok == 0 ? null : DriveSpace(free.value, total.value);
        }));
  }

  /// A drive's name, as File Explorer shows it: its label, or its kind.
  static String _driveName(String root, String letter) => using((arena) {
        final label = arena<Uint16>(261).cast<Utf16>();
        final hasLabel = GetVolumeInformation(
          root.toNativeUtf16(allocator: arena), label, 261, nullptr, nullptr, nullptr, nullptr, 0,
        );
        final name = hasLabel != 0 ? label.toDartString() : '';
        if (name.isNotEmpty) return '$name ($letter:)';
        final kind = switch (GetDriveType(root.toNativeUtf16(allocator: arena))) {
          DRIVE_REMOVABLE => 'USB Drive',
          DRIVE_REMOTE => 'Network Drive',
          DRIVE_CDROM => 'DVD Drive',
          _ => 'Local Disk',
        };
        return '$kind ($letter:)';
      });

  static Future<List<WindowsStorageLocation>> listDrives() async {
    if (!Platform.isWindows) return [];

    final roots = <String>[];
    for (var code = 65; code <= 90; code++) {
      final root = '${String.fromCharCode(code)}:\\';
      if (await Directory(root).exists()) roots.add(root);
    }
    // In the background: an empty DVD drive can take a while.
    final names = await Isolate.run(() => {for (final root in roots) root: _driveName(root, root[0])});
    return [
      for (final root in roots)
        WindowsStorageLocation(
          displayName: names[root]!,
          path: root,
          kind: WindowsStorageKind.drive,
          icon: BootstrapIcons.hdd_stack_fill,
        ),
    ];
  }

  static Future<List<WindowsStorageLocation>> listLibraries() async {
    if (!Platform.isWindows) return [];

    final profile = Platform.environment['USERPROFILE'];
    if (profile == null || profile.isEmpty) return [];

    const libraryDefs = <(String name, String segment, IconData icon)>[
      ('Desktop', 'Desktop', BootstrapIcons.window_desktop),
      ('Documents', 'Documents', BootstrapIcons.file_earmark_text_fill),
      ('Downloads', 'Downloads', BootstrapIcons.download),
      ('Pictures', 'Pictures', BootstrapIcons.image_fill),
      ('Music', 'Music', BootstrapIcons.music_note_beamed),
      ('Videos', 'Videos', BootstrapIcons.play_circle_fill),
    ];

    final libraries = <WindowsStorageLocation>[];
    for (final def in libraryDefs) {
      final dir = Directory(p.join(profile, def.$2));
      if (await dir.exists()) {
        libraries.add(
          WindowsStorageLocation(
            displayName: def.$1,
            path: dir.path,
            kind: WindowsStorageKind.library,
            icon: def.$3,
          ),
        );
      }
    }

    final home = Directory(profile);
    if (await home.exists()) {
      libraries.insert(
        0,
        WindowsStorageLocation(
          displayName: 'User folder',
          path: home.path,
          kind: WindowsStorageKind.library,
          icon: BootstrapIcons.person_fill,
        ),
      );
    }

    return libraries;
  }

  static Future<List<WindowsStorageLocation>> listAll() async {
    final drives = await listDrives();
    final libraries = await listLibraries();
    return [...drives, ...libraries];
  }
}
