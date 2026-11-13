import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:folders/core/services/new_files.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Finder's Trash. Files go there through NSFileManager (`trash` on the
/// `explorer/trash` channel in MainFlutterWindow.swift), or Finder itself
/// through osascript if that's missing. macOS keeps where an item came from
/// to itself, so Folders notes it for what it trashed, to put it back. Since
/// Mojave, reading `~/.Trash` may need Full Disk Access: without it the
/// Trash place lists only what Folders put there, and opens Finder's.
class MacTrash extends Trash {
  MacTrash({String? home}) : home = home ?? Platform.environment['HOME'] ?? '/';

  final String home;

  static const _channel = MethodChannel('explorer/trash');
  static const _recordsKey = 'mac_trash_records';

  String get trashDir => p.join(home, '.Trash');

  @override
  bool contains(String path) => p.isWithin(trashDir, path) || path.contains('/.Trashes/');

  @override
  Future<void> Function()? get openInSystem => () async {
        final shown = await _osascript([
          'tell application "Finder"',
          'activate',
          'open trash',
          'end tell',
        ]);
        if (shown == null) await Process.run('/usr/bin/open', [trashDir]);
      };

  @override
  Future<TrashResult> moveToTrash(List<String> paths) async {
    final trashed = <TrashItem>[];
    final failed = <String, String>{};
    final records = await _records();
    for (final path in paths) {
      if (!canTrash(path)) {
        failed[path] = "It can't go to the Trash";
        continue;
      }
      final isDirectory = FileSystemEntity.isDirectorySync(path);
      String? stored;
      String? error;
      try {
        stored = await _channel.invokeMethod<String>('trash', {'path': path});
      } on MissingPluginException {
        stored = await _finderDelete(path);
      } on PlatformException catch (e) {
        error = e.message;
      }
      if ((stored == null || stored.isEmpty) && error == null) {
        stored = FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound
            // Gone, but macOS didn't say where: most likely here.
            ? p.join(trashDir, p.basename(path))
            : await _finderDelete(path);
      }
      if (stored == null || stored.isEmpty) {
        failed[path] = error ?? "Finder didn't move it";
        continue;
      }
      final now = DateTime.now();
      records.add({'stored': stored, 'original': path, 'at': now.toIso8601String()});
      trashed.add(TrashItem(
        name: p.basename(path),
        originalPath: path,
        storedPath: stored,
        isDirectory: isDirectory,
        deletedAt: now,
      ));
    }
    await _saveRecords(records);
    return TrashResult(trashed: trashed, failed: failed);
  }

  /// Asks Finder to move [path] to the Trash; where it is now, or null.
  Future<String?> _finderDelete(String path) async {
    final out = await _osascript([
      'on run argv',
      'tell application "Finder" to return POSIX path of ((delete ((POSIX file (item 1 of argv)) as alias)) as alias)',
      'end run',
    ], args: [path]);
    if (out == null || out.isEmpty) return null;
    // Folders come back with a trailing slash.
    return out.length > 1 && out.endsWith('/') ? out.substring(0, out.length - 1) : out;
  }

  static Future<String?> _osascript(List<String> lines, {List<String> args = const []}) async {
    try {
      final result = await Process.run('/usr/bin/osascript', [for (final line in lines) ...['-e', line], ...args]);
      if (result.exitCode != 0) return null;
      return '${result.stdout}'.trim();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<TrashItem>> list() async {
    final records = await _records();
    final known = {for (final r in records) r['stored']!: r};
    final items = <TrashItem>[];
    List<FileSystemEntity>? entries;
    try {
      entries = Directory(trashDir).listSync(followLinks: false);
    } catch (_) {
      // No Full Disk Access: only what Folders put there.
    }
    final seen = <String>{};
    for (final entry in entries ?? const <FileSystemEntity>[]) {
      final name = p.basename(entry.path);
      if (name == '.DS_Store' || name == '.localized') continue;
      seen.add(entry.path);
      final record = known[entry.path];
      items.add(_item(entry.path, entry is Directory, record));
    }
    for (final record in records) {
      final stored = record['stored']!;
      if (seen.contains(stored)) continue;
      final type = FileSystemEntity.typeSync(stored, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      items.add(_item(stored, type == FileSystemEntityType.directory, record));
    }
    // Forget what's no longer there.
    if (entries != null) {
      final kept = [
        for (final r in records)
          if (FileSystemEntity.typeSync(r['stored']!, followLinks: false) != FileSystemEntityType.notFound) r,
      ];
      if (kept.length != records.length) await _saveRecords(kept);
    }
    return items;
  }

  TrashItem _item(String stored, bool isDirectory, Map<String, String>? record) {
    final original = record?['original'] ?? '';
    int? size;
    DateTime? at = DateTime.tryParse(record?['at'] ?? '');
    try {
      final stat = FileStat.statSync(stored);
      if (!isDirectory) size = stat.size;
      at ??= stat.changed;
    } catch (_) {}
    return TrashItem(
      name: original.isEmpty ? p.basename(stored) : p.basename(original),
      originalPath: original,
      storedPath: stored,
      isDirectory: isDirectory,
      deletedAt: at,
      size: size,
    );
  }

  @override
  Future<String> restore(TrashItem item) async {
    if (!item.canRestore) throw FileSystemException("Where it was isn't known", item.storedPath);
    var target = item.originalPath;
    final folder = p.dirname(target);
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      final name = p.basename(target);
      final ext = item.isDirectory ? '' : p.extension(name);
      final base = name.substring(0, name.length - ext.length);
      target = p.join(folder, NewFiles.freeName(folder, base, ext.isEmpty ? '' : ext.substring(1)));
    }
    await Directory(folder).create(recursive: true);
    if (item.isDirectory) {
      await Directory(item.storedPath).rename(target);
    } else {
      await File(item.storedPath).rename(target);
    }
    await _forget(item.storedPath);
    return target;
  }

  @override
  Future<void> deleteForGood(TrashItem item) async {
    if (item.isDirectory) {
      await Directory(item.storedPath).delete(recursive: true);
    } else {
      await File(item.storedPath).delete();
    }
    await _forget(item.storedPath);
  }

  @override
  Future<void> empty() async {
    final emptied = await _osascript(['tell application "Finder" to empty trash']);
    if (emptied == null) {
      for (final item in await list()) {
        try {
          await deleteForGood(item);
        } catch (_) {}
      }
    }
    await _saveRecords(const []);
  }

  Future<void> _forget(String stored) async {
    final records = await _records();
    records.removeWhere((r) => r['stored'] == stored);
    await _saveRecords(records);
  }

  static Future<List<Map<String, String>>> _records() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return [
        for (final raw in prefs.getStringList(_recordsKey) ?? const <String>[])
          if (jsonDecode(raw) case {'stored': final String s, 'original': final String o, 'at': final String a})
            {'stored': s, 'original': o, 'at': a},
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveRecords(List<Map<String, String>> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The newest 500 are plenty.
      final kept = records.length > 500 ? records.sublist(records.length - 500) : records;
      await prefs.setStringList(_recordsKey, [for (final r in kept) jsonEncode(r)]);
    } catch (_) {}
  }
}
