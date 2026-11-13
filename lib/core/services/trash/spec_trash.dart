import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:folders/core/services/new_files.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:path/path.dart' as p;

/// A Trash folder: what was deleted is in `files/`, and for each item
/// `info/<name>.trashinfo` says where it was and when it was deleted.
@immutable
class TrashDir {
  const TrashDir(this.path, {this.top});

  final String path;

  /// The top of the drive it's on: the paths in its `.trashinfo` files are
  /// relative to it. Null for the home Trash, whose paths are absolute.
  final String? top;

  String get files => p.join(path, 'files');
  String get info => p.join(path, 'info');

  @override
  bool operator ==(Object other) => other is TrashDir && other.path == path && other.top == top;

  @override
  int get hashCode => Object.hash(path, top);
}

/// A Trash laid out as the freedesktop.org Trash specification says: the
/// one Linux desktops share (`~/.local/share/Trash`, and `.Trash-<uid>` at
/// the top of other drives), and Folders' own on Android, laid out the same
/// way in a hidden `.FoldersTrash` at the top of each storage volume, so a
/// move there is only a rename.
class SpecTrash extends Trash {
  SpecTrash({
    required this.dirFor,
    required this.dirs,
    this.own = false,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// A Trash in [folder], for whatever is deleted (tests).
  factory SpecTrash.inFolder(String folder, {bool own = true, DateTime Function()? now}) {
    final dir = TrashDir(folder);
    return SpecTrash(dirFor: (_) => dir, dirs: () => [dir], own: own, now: now);
  }

  /// The Trash a path goes to; null when it has none.
  final TrashDir? Function(String path) dirFor;

  /// Every Trash folder there is now, to list and empty.
  final List<TrashDir> Function() dirs;

  /// Folders' own Trash (Android): it empties itself of old items and keeps
  /// its pictures out of the gallery.
  final bool own;

  final DateTime Function() _now;

  @override
  bool get emptiesItself => own;

  @override
  bool contains(String path) {
    for (final dir in dirs()) {
      if (p.equals(path, dir.path) || p.isWithin(dir.path, path)) return true;
    }
    return false;
  }

  @override
  Future<TrashResult> moveToTrash(List<String> paths) async {
    final trashed = <TrashItem>[];
    final failed = <String, String>{};
    for (final path in paths) {
      if (!canTrash(path)) {
        failed[path] = "It can't go to the Trash";
        continue;
      }
      final dir = dirFor(path);
      if (dir == null) {
        failed[path] = 'This drive has no Trash';
        continue;
      }
      try {
        trashed.add(await _move(path, dir));
      } on FileSystemException catch (e) {
        failed[path] = e.osError?.message ?? e.message;
      } catch (e) {
        failed[path] = '$e';
      }
    }
    return TrashResult(trashed: trashed, failed: failed);
  }

  Future<TrashItem> _move(String path, TrashDir dir) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('Not found', path);
    }
    await _prepare(dir);
    final deletedAt = _now();
    final original = p.normalize(path);
    final name = p.basename(original);
    final ext = type == FileSystemEntityType.directory ? '' : p.extension(name);
    final base = name.substring(0, name.length - ext.length);
    // The .trashinfo file is made first, exclusively: it claims the name.
    for (var n = 1; n < 10000; n++) {
      final candidate = n == 1 ? name : '$base.$n$ext';
      final info = File(p.join(dir.info, '$candidate.trashinfo'));
      final stored = p.join(dir.files, candidate);
      if (FileSystemEntity.typeSync(stored, followLinks: false) != FileSystemEntityType.notFound) continue;
      try {
        await info.create(exclusive: true);
      } on FileSystemException {
        continue;
      }
      try {
        await info.writeAsString(trashInfo(original, deletedAt, top: dir.top), flush: true);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).rename(stored);
        } else if (type == FileSystemEntityType.link) {
          await Link(path).rename(stored);
        } else {
          await File(path).rename(stored);
        }
      } catch (_) {
        try {
          await info.delete();
        } catch (_) {}
        rethrow;
      }
      int? size;
      try {
        if (type == FileSystemEntityType.file) size = File(stored).lengthSync();
      } catch (_) {}
      return TrashItem(
        name: name,
        originalPath: original,
        storedPath: stored,
        isDirectory: type == FileSystemEntityType.directory,
        deletedAt: DateTime.parse(_date(deletedAt)),
        size: size,
      );
    }
    throw FileSystemException('No free name in the Trash', path);
  }

  Future<void> _prepare(TrashDir dir) async {
    final made = !Directory(dir.path).existsSync();
    await Directory(dir.files).create(recursive: true);
    await Directory(dir.info).create(recursive: true);
    if (made) {
      // Only its owner may look inside (the specification asks for 700).
      if (Platform.isLinux || Platform.isAndroid) _chmod(dir.path, 448);
      // Pictures and videos in it stay out of the gallery.
      if (own && Platform.isAndroid) {
        try {
          await File(p.join(dir.path, '.nomedia')).create();
        } catch (_) {}
      }
    }
  }

  @override
  Future<List<TrashItem>> list() async {
    final keep = own ? await TrashSettings.keepDays() : 0;
    final cutoff = keep > 0 ? _now().subtract(Duration(days: keep)) : null;
    final items = <TrashItem>[];
    for (final dir in dirs()) {
      final listed = <String>{};
      List<FileSystemEntity> infos;
      try {
        infos = Directory(dir.info).listSync(followLinks: false);
      } catch (_) {
        infos = const [];
      }
      for (final info in infos) {
        final infoName = p.basename(info.path);
        if (info is! File || !infoName.endsWith('.trashinfo')) continue;
        final storedName = infoName.substring(0, infoName.length - '.trashinfo'.length);
        final stored = p.join(dir.files, storedName);
        final type = FileSystemEntity.typeSync(stored, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        listed.add(storedName);
        ({String path, DateTime? deletedAt})? parsed;
        try {
          parsed = parseTrashInfo(info.readAsStringSync(), top: dir.top);
        } catch (_) {}
        final item = TrashItem(
          name: parsed == null ? storedName : p.basename(parsed.path),
          originalPath: parsed?.path ?? '',
          storedPath: stored,
          isDirectory: type == FileSystemEntityType.directory,
          deletedAt: parsed?.deletedAt,
          size: type == FileSystemEntityType.file ? _length(stored) : null,
        );
        final at = item.deletedAt;
        if (cutoff != null && at != null && at.isBefore(cutoff)) {
          try {
            await deleteForGood(item);
            continue;
          } catch (_) {}
        }
        items.add(item);
      }
      // What's there without its .trashinfo (another program's leftovers):
      // listed, but there's nowhere to put it back.
      List<FileSystemEntity> files;
      try {
        files = Directory(dir.files).listSync(followLinks: false);
      } catch (_) {
        files = const [];
      }
      for (final file in files) {
        final name = p.basename(file.path);
        if (listed.contains(name)) continue;
        items.add(TrashItem(
          name: name,
          originalPath: '',
          storedPath: file.path,
          isDirectory: file is Directory,
          size: file is File ? _length(file.path) : null,
        ));
      }
    }
    return items;
  }

  static int? _length(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return null;
    }
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
    final type = FileSystemEntity.typeSync(item.storedPath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(item.storedPath).rename(target);
    } else if (type == FileSystemEntityType.link) {
      await Link(item.storedPath).rename(target);
    } else {
      await File(item.storedPath).rename(target);
    }
    await _deleteInfo(item);
    return target;
  }

  @override
  Future<void> deleteForGood(TrashItem item) async {
    final type = FileSystemEntity.typeSync(item.storedPath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(item.storedPath).delete(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      await File(item.storedPath).delete();
    }
    await _deleteInfo(item);
  }

  Future<void> _deleteInfo(TrashItem item) async {
    final files = p.dirname(item.storedPath);
    final info = p.join(p.dirname(files), 'info', '${p.basename(item.storedPath)}.trashinfo');
    try {
      await File(info).delete();
    } catch (_) {}
  }

  @override
  Future<void> empty() async {
    for (final dir in dirs()) {
      for (final folder in [dir.files, dir.info]) {
        List<FileSystemEntity> entries;
        try {
          entries = Directory(folder).listSync(followLinks: false);
        } catch (_) {
          continue;
        }
        for (final entry in entries) {
          try {
            await entry.delete(recursive: true);
          } catch (_) {}
        }
      }
      // A cache of folder sizes some desktops keep beside them.
      try {
        await File(p.join(dir.path, 'directorysizes')).delete();
      } catch (_) {}
    }
  }

  /// A `.trashinfo` file for [path], deleted at [deletedAt]; relative to
  /// [top] when it's on another drive's Trash.
  @visibleForTesting
  static String trashInfo(String path, DateTime deletedAt, {String? top}) {
    final shown = top != null && p.isWithin(top, path) ? p.relative(path, from: top) : path;
    return '[Trash Info]\nPath=${_encode(shown)}\nDeletionDate=${_date(deletedAt)}\n';
  }

  /// The path and date in a `.trashinfo` file.
  @visibleForTesting
  static ({String path, DateTime? deletedAt})? parseTrashInfo(String text, {String? top}) {
    String? path;
    DateTime? date;
    var inGroup = false;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inGroup = line == '[Trash Info]';
        continue;
      }
      if (!inGroup) continue;
      if (line.startsWith('Path=')) {
        final value = line.substring(5);
        try {
          path = Uri.decodeComponent(value);
        } catch (_) {
          path = value;
        }
      } else if (line.startsWith('DeletionDate=')) {
        date = DateTime.tryParse(line.substring(13));
      }
    }
    if (path == null || path.isEmpty) return null;
    if (!p.isAbsolute(path) && top != null) path = p.join(top, path);
    return (path: p.normalize(path), deletedAt: date);
  }

  /// Escaped as in a URI, `/` kept.
  static String _encode(String path) => path.split('/').map(Uri.encodeComponent).join('/');

  /// `2026-11-13T09:41:00`, in local time, as the specification has it.
  static String _date(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = at.toLocal();
    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
        'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // Linux ------------------------------------------------------------------

  /// The Trash Linux desktops share.
  factory SpecTrash.linux() {
    final uid = _uid();
    final home = Platform.environment['HOME'] ?? '/';
    final data = Platform.environment['XDG_DATA_HOME'];
    final homeTrash = TrashDir(p.join(data != null && data.isNotEmpty ? data : p.join(home, '.local', 'share'), 'Trash'));
    final mounts = LinuxMounts();
    return SpecTrash(
      dirFor: (path) {
        final top = mounts.topOf(path);
        final homeTop = mounts.topOf(homeTrash.path);
        if (top == homeTop) return homeTrash;
        return volumeTrash(top, uid);
      },
      dirs: () => [
        homeTrash,
        for (final top in mounts.realTops())
          for (final dir in [TrashDir(p.join(top, '.Trash', '$uid'), top: top), TrashDir(p.join(top, '.Trash-$uid'), top: top)])
            if (Directory(dir.path).existsSync()) dir,
      ],
    );
  }

  /// The Trash at the top of another drive: `.Trash/<uid>` if an
  /// administrator made `.Trash` for everyone (sticky, not a link), else
  /// `.Trash-<uid>`.
  @visibleForTesting
  static TrashDir volumeTrash(String top, int uid) {
    final shared = p.join(top, '.Trash');
    try {
      final link = FileSystemEntity.isLinkSync(shared);
      final stat = FileStat.statSync(shared);
      // 512: the sticky bit.
      if (!link && stat.type == FileSystemEntityType.directory && stat.mode & 512 != 0) {
        return TrashDir(p.join(shared, '$uid'), top: top);
      }
    } catch (_) {}
    return TrashDir(p.join(top, '.Trash-$uid'), top: top);
  }

  static int _uid() {
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isAndroid) return 0;
    try {
      return DynamicLibrary.process().lookupFunction<Uint32 Function(), int Function()>('getuid')();
    } catch (_) {
      return 0;
    }
  }

  static void _chmod(String path, int mode) {
    final name = path.toNativeUtf8();
    try {
      DynamicLibrary.process()
          .lookupFunction<Int32 Function(Pointer<Utf8>, Uint32), int Function(Pointer<Utf8>, int)>('chmod')(name, mode);
    } catch (_) {
    } finally {
      calloc.free(name);
    }
  }

  // Android ----------------------------------------------------------------

  /// Folders' own Trash: Android has none for files.
  factory SpecTrash.android() {
    return SpecTrash(
      own: true,
      dirFor: (path) {
        final top = androidVolumeOf(path);
        return top == null ? null : TrashDir(p.join(top, androidTrashName), top: top);
      },
      dirs: () {
        final tops = <String>['/storage/emulated/0'];
        try {
          for (final entry in Directory('/storage').listSync()) {
            final name = p.basename(entry.path);
            if (entry is Directory && name != 'emulated' && name != 'self') tops.add(entry.path);
          }
        } catch (_) {}
        return [
          for (final top in tops)
            if (Directory(p.join(top, androidTrashName)).existsSync()) TrashDir(p.join(top, androidTrashName), top: top),
        ];
      },
    );
  }

  static const androidTrashName = '.FoldersTrash';

  /// The storage volume [path] is on: internal storage or an SD card.
  @visibleForTesting
  static String? androidVolumeOf(String path) {
    const internal = '/storage/emulated/0';
    if (path == internal || path.startsWith('$internal/')) return internal;
    final match = RegExp(r'^/storage/([^/]+)(/|$)').firstMatch(path);
    if (match == null) return null;
    final name = match.group(1)!;
    if (name == 'emulated' || name == 'self') return null;
    return '/storage/$name';
  }
}

/// Where Linux drives are mounted, from `/proc/self/mounts`.
class LinuxMounts {
  LinuxMounts({String Function()? read}) : _read = read ?? (() => File('/proc/self/mounts').readAsStringSync());

  final String Function() _read;

  List<({String device, String point})> _entries() {
    try {
      return [
        for (final line in _read().split('\n'))
          if (line.trim().split(' ') case [final device, final point, ...]) (device: device, point: _unescape(point)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// `\040` for a space, and so on.
  static String _unescape(String field) =>
      field.replaceAllMapped(RegExp(r'\\([0-7]{3})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)));

  /// The mount point [path] is under: the longest that holds it.
  String topOf(String path) {
    var best = '/';
    for (final entry in _entries()) {
      final point = entry.point;
      if ((point == path || p.isWithin(point, path)) && point.length > best.length) best = point;
    }
    return best;
  }

  /// Mount points of real drives (not /proc, /sys and the like).
  List<String> realTops() => [
        for (final entry in _entries())
          if (entry.device.startsWith('/') && entry.point != '/') entry.point,
      ];
}
