import 'dart:io';
import 'dart:isolate';

import 'package:folder/core/platform/explorer_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show IconData;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

enum JunkKind {
  temporary('Temporary files', 'Left behind by apps; nothing needs them', LucideIcons.fileX2, true),
  thumbnails('Thumbnail caches', 'Small previews; they are made again when needed', LucideIcons.images, true),
  appCache("Folder's cache", 'Previews and leftovers of this app', LucideIcons.folderX, true),
  logs('Log files', 'Records apps keep of what they did', LucideIcons.scrollText, false),
  caches('App caches', 'Apps make these again, so they may be slower at first', LucideIcons.layers, false),
  trash('Trash', 'Files you deleted earlier; they are gone for good after this', LucideIcons.trash2, false),
  emptyFolders('Empty folders', 'Folders with nothing in them', LucideIcons.folderOpen, false),
  installers('App installers', 'APK files; check you no longer need them', LucideIcons.package, false);

  const JunkKind(this.label, this.description, this.icon, this.selectedAtFirst);

  final String label;
  final String description;
  final IconData icon;

  /// Only what's certainly safe to lose is ticked to begin with.
  final bool selectedAtFirst;
}

class JunkItem {
  const JunkItem(this.path, this.size, {this.isFolder = false});

  final String path;
  final int size;
  final bool isFolder;
}

class JunkGroup {
  const JunkGroup(this.kind, this.items);

  final JunkKind kind;
  final List<JunkItem> items;

  int get size => items.fold(0, (sum, item) => sum + item.size);
}

/// What a clean-up freed.
class JunkCleanResult {
  const JunkCleanResult(this.freed, this.removed, this.failed);

  final int freed;
  final int removed;

  /// In use or not allowed.
  final int failed;
}

/// Finds junk where each system keeps it: on a phone across its storage; on a
/// computer only in folders meant for it, as elsewhere an odd .log or empty
/// folder may matter (Windows: temporary files and crash dumps; Linux:
/// temporary files, thumbnails and the trash; macOS: temporary files, logs,
/// caches and the trash).
abstract final class JunkScanner {
  /// What [scan] does instead; tests set it.
  @visibleForTesting
  static Future<List<JunkGroup>> Function()? scanOverride;

  static Future<List<JunkGroup>> scan() async {
    final override = scanOverride;
    if (override != null) return override();
    if (Platform.isAndroid) {
      final cache = (await getTemporaryDirectory()).path;
      return Isolate.run(() => scanStorage(ExplorerPaths.androidInternalStorage, appCache: cache));
    }
    final home = ExplorerPaths.homePath;
    final temp = Directory.systemTemp.path;
    final local = Platform.environment['LOCALAPPDATA'];
    return Isolate.run(() {
      if (Platform.isWindows) {
        return scanComputer(temp, logs: [if (local != null) p.join(local, 'CrashDumps')]);
      }
      if (Platform.isMacOS) {
        return scanComputer(
          temp,
          logs: [p.join(home, 'Library', 'Logs')],
          caches: [p.join(home, 'Library', 'Caches')],
          trash: [p.join(home, '.Trash')],
        );
      }
      return scanComputer(
        temp,
        thumbnails: [p.join(home, '.cache', 'thumbnails'), p.join(home, '.thumbnails')],
        trash: [p.join(home, '.local', 'share', 'Trash', 'files'), p.join(home, '.local', 'share', 'Trash', 'info')],
      );
    });
  }

  static int _sizeOf(Directory dir) {
    var total = 0;
    try {
      for (final entry in dir.listSync(recursive: true, followLinks: false)) {
        if (entry is File) total += entry.lengthSync();
      }
    } on FileSystemException {
      // As much as could be read.
    }
    return total;
  }

  /// A phone's shared storage, leaving out Android's app folders. Works in
  /// any isolate.
  @visibleForTesting
  static List<JunkGroup> scanStorage(String root, {String? appCache}) {
    final found = {for (final kind in JunkKind.values) kind: <JunkItem>[]};

    void walk(Directory dir, int depth) {
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      // Folders right in the storage (Music, Movies) are the system's.
      if (entries.isEmpty && depth >= 2) {
        found[JunkKind.emptyFolders]!.add(JunkItem(dir.path, 0, isFolder: true));
        return;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (entry is Directory) {
          if (name == '.thumbnails') {
            found[JunkKind.thumbnails]!.add(JunkItem(entry.path, _sizeOf(entry), isFolder: true));
          } else if (!name.startsWith('.') && name != 'node_modules' && !(depth == 0 && name == 'Android')) {
            walk(entry, depth + 1);
          }
        } else if (entry is File) {
          final kind = switch (p.extension(name).toLowerCase()) {
            '.tmp' || '.temp' => JunkKind.temporary,
            '.log' => JunkKind.logs,
            '.apk' => JunkKind.installers,
            _ => null,
          };
          if (kind != null) found[kind]!.add(JunkItem(entry.path, entry.lengthSync()));
        }
      }
    }

    walk(Directory(root), 0);
    if (appCache != null) _addContents(Directory(appCache), found[JunkKind.appCache]!);
    return _groups(found);
  }

  /// A computer's temporary folder: what's been left there over a day, as
  /// anything newer may be in use. Works in any isolate.
  @visibleForTesting
  static List<JunkGroup> scanComputer(
    String temp, {
    List<String> thumbnails = const [],
    List<String> logs = const [],
    List<String> caches = const [],
    List<String> trash = const [],
    DateTime? now,
  }) {
    final found = {for (final kind in JunkKind.values) kind: <JunkItem>[]};
    final before = (now ?? DateTime.now()).subtract(const Duration(days: 1));
    _addContents(Directory(temp), found[JunkKind.temporary]!, olderThan: before);
    for (final (kind, folders) in [
      (JunkKind.thumbnails, thumbnails),
      (JunkKind.logs, logs),
      (JunkKind.caches, caches),
      (JunkKind.trash, trash),
    ]) {
      for (final folder in folders) {
        _addContents(Directory(folder), found[kind]!);
      }
    }
    return _groups(found);
  }

  static void _addContents(Directory dir, List<JunkItem> into, {DateTime? olderThan}) {
    if (!dir.existsSync()) return;
    try {
      for (final entry in dir.listSync(followLinks: false)) {
        final stat = entry.statSync();
        if (olderThan != null && stat.modified.isAfter(olderThan)) continue;
        if (entry is File) {
          into.add(JunkItem(entry.path, stat.size));
        } else if (entry is Directory) {
          into.add(JunkItem(entry.path, _sizeOf(entry), isFolder: true));
        }
      }
    } on FileSystemException {
      // As much as could be read.
    }
  }

  static List<JunkGroup> _groups(Map<JunkKind, List<JunkItem>> found) => [
        for (final kind in JunkKind.values)
          if (found[kind]!.isNotEmpty) JunkGroup(kind, found[kind]!),
      ];

  /// Deletes exactly [items], for good; what can't go stays and is counted.
  static Future<JunkCleanResult> clean(List<JunkItem> items) => Isolate.run(() {
        var freed = 0;
        var removed = 0;
        var failed = 0;
        for (final item in items) {
          try {
            if (item.isFolder) {
              Directory(item.path).deleteSync(recursive: true);
            } else {
              File(item.path).deleteSync();
            }
            freed += item.size;
            removed++;
          } on FileSystemException {
            failed++;
          }
        }
        return JunkCleanResult(freed, removed, failed);
      });
}
