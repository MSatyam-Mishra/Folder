import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/trash/mac_trash.dart';
import 'package:folders/core/services/trash/spec_trash.dart';
import 'package:folders/core/services/trash/windows_recycle_bin.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Something in the Trash.
@immutable
class TrashItem {
  const TrashItem({
    required this.name,
    required this.originalPath,
    required this.storedPath,
    required this.isDirectory,
    this.deletedAt,
    this.size,
  });

  /// Its name before it went to the Trash.
  final String name;

  /// Where it was; empty when the system didn't say (macOS, for items
  /// another app put there).
  final String originalPath;

  /// Where it is now: a file or a folder that can be read, but shouldn't be
  /// changed except through the Trash.
  final String storedPath;

  final bool isDirectory;
  final DateTime? deletedAt;

  /// In bytes, when the Trash knows it (folders' sizes often aren't kept).
  final int? size;

  bool get canRestore => originalPath.isNotEmpty;

  String get originalFolder => originalPath.isEmpty ? '' : p.dirname(originalPath);

  FileSystemEntity get entity => isDirectory ? Directory(storedPath) : File(storedPath);

  @override
  String toString() => 'TrashItem($name from $originalPath at $storedPath)';
}

/// What a move to the Trash did.
class TrashResult {
  const TrashResult({this.trashed = const [], this.failed = const {}});

  /// What's in the Trash now, to put back with Undo.
  final List<TrashItem> trashed;

  /// What couldn't go, with why.
  final Map<String, String> failed;
}

/// The system's Trash: the Recycle Bin on Windows, the freedesktop.org Trash
/// on Linux, Finder's on a Mac, and Folders' own on Android (Android has
/// none for files). Delete moves files there; the Trash place in the sidebar
/// lists them, puts them back or deletes them for good.
abstract class Trash {
  /// The Trash files go to; tests replace it.
  static Trash instance = _forThisSystem();

  static Trash _forThisSystem() {
    // Tests must never fill the real Recycle Bin: they use their own.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return const NoTrash();
    if (Platform.isWindows) return WindowsRecycleBin();
    if (Platform.isMacOS) return MacTrash();
    if (Platform.isLinux) return SpecTrash.linux();
    if (Platform.isAndroid) return SpecTrash.android();
    return const NoTrash();
  }

  const Trash();

  /// What the system calls it.
  String get label => 'Trash';

  /// Whether [path] can go to the Trash at all; a move may still fail (a
  /// drive without one). Remote places have no Trash: deletes there are for
  /// good.
  bool canTrash(String path) =>
      !ExplorerPaths.isVirtual(path) && !RemotePaths.isRemote(path) && !contains(path);

  /// Whether [path] is inside the Trash itself.
  bool contains(String path) => false;

  Future<TrashResult> moveToTrash(List<String> paths);

  Future<List<TrashItem>> list();

  /// Puts [item] back where it was (under a free name if that's taken now);
  /// gives the path it's at.
  Future<String> restore(TrashItem item);

  Future<void> deleteForGood(TrashItem item);

  /// Deletes everything in it for good.
  Future<void> empty();

  /// Folders' own Trash empties itself of what's older than
  /// [TrashSettings.keepDays]; the systems' Trashes are theirs to manage.
  bool get emptiesItself => false;

  /// Opens the Trash in the system's file manager, where Folders can't list
  /// it all (a Mac) or as a second way in (Windows); null where there's none.
  Future<void> Function()? get openInSystem => null;
}

/// No Trash: deletes are for good, as they were (tests, unknown systems).
class NoTrash extends Trash {
  const NoTrash();

  @override
  bool canTrash(String path) => false;

  @override
  Future<TrashResult> moveToTrash(List<String> paths) async =>
      TrashResult(failed: {for (final path in paths) path: 'There is no Trash here'});

  @override
  Future<List<TrashItem>> list() async => const [];

  @override
  Future<String> restore(TrashItem item) => throw UnsupportedError('No Trash');

  @override
  Future<void> deleteForGood(TrashItem item) async {}

  @override
  Future<void> empty() async {}
}

/// Whether Delete uses the Trash, and how long Folders' own Trash keeps
/// things.
abstract final class TrashSettings {
  static const _enabledKey = 'trash_enabled';
  static const _keepDaysKey = 'trash_keep_days';

  /// Whether Delete moves to the Trash (true at first).
  static Future<bool> enabled() async {
    try {
      return (await SharedPreferences.getInstance()).getBool(_enabledKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_enabledKey, value);

  /// Days Folders' own Trash keeps things (30 at first); 0 keeps them until
  /// it's emptied.
  static Future<int> keepDays() async {
    try {
      return (await SharedPreferences.getInstance()).getInt(_keepDaysKey) ?? 30;
    } catch (_) {
      return 30;
    }
  }

  static Future<void> setKeepDays(int days) async =>
      (await SharedPreferences.getInstance()).setInt(_keepDaysKey, days);
}

/// The Trash as the browser lists it (`explorer://trash`): its items as
/// files and folders, named as they were.
abstract final class TrashListing {
  static Map<String, TrashItem> _byPath = const {};

  /// Lists the Trash, and keeps what it found for [itemAt] and [labels].
  static Future<List<FileSystemEntity>> load() async {
    final items = await Trash.instance.list();
    _byPath = {for (final item in items) item.storedPath: item};
    return [for (final item in items) item.entity];
  }

  /// The item listed at [storedPath].
  static TrashItem? itemAt(String storedPath) => _byPath[storedPath];

  /// Every item's name before it went to the Trash, by where it is now.
  static Map<String, String> get labels => {for (final e in _byPath.entries) e.key: e.value.name};

  /// The items of [entities] (what's selected in the Trash).
  static List<TrashItem> itemsOf(Iterable<FileSystemEntity> entities) => [
        for (final e in entities)
          if (_byPath[e.path] case final item?) item,
      ];

  @visibleForTesting
  static void clear() => _byPath = const {};
}
