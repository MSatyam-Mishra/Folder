import 'dart:io';

import 'package:folders/core/platform/macos_files.dart';
import 'package:path/path.dart' as p;

/// How far a paste is: bytes copied of [total], and the file being copied.
class PasteProgress {
  const PasteProgress(this.done, this.total, this.name);

  final int done;
  final int total;
  final String name;
}

/// Copies [sources] into [destination], or moves them when [move], and
/// returns where they ended up.
///
/// Nothing is overwritten: a name that's taken gets " (2)", " (3)"…, and a
/// copy into its own folder becomes "name - Copy". A move renames when it
/// can and copies then deletes across drives. Files keep their modified
/// time; on macOS files and folders also keep their permissions, extended
/// attributes and ACLs, as in Finder. [onPlaced] hears where each item went.
Future<List<String>> pasteEntities(
  List<String> sources,
  String destination, {
  required bool move,
  void Function(PasteProgress progress)? onProgress,
  void Function(String from, String to)? onPlaced,
}) async {
  final targets = <String>[];
  final copies = <(String, String)>[];
  for (final source in sources) {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    final isDirectory = type == FileSystemEntityType.directory;
    if (isDirectory && (p.equals(source, destination) || p.isWithin(source, destination))) {
      throw FileSystemException("A folder can't be pasted into itself", source);
    }
    final sameFolder = p.equals(p.dirname(source), destination);
    if (move && sameFolder) {
      targets.add(source); // Already here.
      continue;
    }
    final target = freeName(
      destination,
      p.basename(source),
      isDirectory: isDirectory,
      copyOfItself: sameFolder,
    );
    if (move) {
      try {
        await _entity(source, type).rename(target);
        targets.add(target);
        onPlaced?.call(source, target);
        continue;
      } on FileSystemException {
        // Another drive: copied, then deleted.
      }
    }
    copies.add((source, target));
  }

  var total = 0;
  for (final (source, _) in copies) {
    total += await _size(source);
  }
  var done = 0;
  var reported = DateTime.fromMillisecondsSinceEpoch(0);
  void progress(String name, int bytes) {
    done += bytes;
    final now = DateTime.now();
    if (now.difference(reported) < const Duration(milliseconds: 100)) return;
    reported = now;
    onProgress?.call(PasteProgress(done, total, name));
  }

  for (final (source, target) in copies) {
    await _copy(source, target, progress);
    if (move) await _entity(source, await FileSystemEntity.type(source, followLinks: false)).delete(recursive: true);
    targets.add(target);
    onPlaced?.call(source, target);
  }
  onProgress?.call(PasteProgress(total, total, ''));
  return targets;
}

/// A path for [name] in [folder] that isn't taken.
String freeName(
  String folder,
  String name, {
  required bool isDirectory,
  bool copyOfItself = false,
}) {
  bool taken(String candidate) =>
      FileSystemEntity.typeSync(p.join(folder, candidate), followLinks: false) !=
      FileSystemEntityType.notFound;
  if (!copyOfItself && !taken(name)) return p.join(folder, name);
  // "archive.tar.gz" keeps ".gz" only, like File Explorer; folders keep all.
  final extension = isDirectory ? '' : p.extension(name);
  final base = name.substring(0, name.length - extension.length);
  for (var i = 1;; i++) {
    final candidate = copyOfItself
        ? (i == 1 ? '$base - Copy$extension' : '$base - Copy ($i)$extension')
        : '$base (${i + 1})$extension';
    if (!taken(candidate)) return p.join(folder, candidate);
  }
}

FileSystemEntity _entity(String path, FileSystemEntityType type) => switch (type) {
      FileSystemEntityType.directory => Directory(path),
      FileSystemEntityType.link => Link(path),
      _ => File(path),
    };

Future<int> _size(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.file) return File(path).length();
  if (type != FileSystemEntityType.directory) return 0;
  var size = 0;
  await for (final entity in Directory(path).list(recursive: true, followLinks: false)) {
    if (entity is File) {
      try {
        size += await entity.length();
      } on FileSystemException {
        // Unreadable: copying it reports the problem.
      }
    }
  }
  return size;
}

Future<void> _copy(String source, String target, void Function(String name, int bytes) progress) async {
  final type = await FileSystemEntity.type(source, followLinks: false);
  switch (type) {
    case FileSystemEntityType.directory:
      await Directory(target).create(recursive: true);
      await for (final entity in Directory(source).list(followLinks: false)) {
        await _copy(entity.path, p.join(target, p.basename(entity.path)), progress);
      }
      // After the contents, so a read-only or locked folder can still be
      // filled, and its modified time stays.
      MacosFiles.copyMetadata(source, target);
    case FileSystemEntityType.link:
      // A link to the same place; copyMetadata would follow it, so not here.
      await Link(target).create(await Link(source).target());
    case FileSystemEntityType.file:
      await _copyFile(File(source), File(target), progress);
    default:
      break;
  }
}

/// Streams the file, so large ones don't fill the memory.
Future<void> _copyFile(File source, File target, void Function(String name, int bytes) progress) async {
  final name = p.basename(source.path);
  final sink = target.openWrite();
  try {
    await for (final chunk in source.openRead()) {
      sink.add(chunk);
      progress(name, chunk.length);
    }
  } finally {
    await sink.close();
  }
  try {
    await target.setLastModified(await source.lastModified());
  } on FileSystemException {
    // Some file systems don't allow it; the copy is still good.
  }
  // macOS: permissions (an app's or script's executable bit), extended
  // attributes and ACLs. Does nothing elsewhere.
  MacosFiles.copyMetadata(source.path, target.path);
}
