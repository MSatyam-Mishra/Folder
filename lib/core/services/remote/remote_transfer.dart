import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/features/clipboard/paste_task.dart' show PasteProgress;
import 'package:path/path.dart' as p;

/// Stops a transfer at the next chunk.
class RemoteCancel {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  /// Calls [listener] when cancelled (at once if it already was).
  void whenCancelled(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void check() {
    if (_cancelled) throw const RemoteException(RemoteErrorKind.cancelled, 'Cancelled');
  }
}

/// Whether copying [sources] into [destination] involves a network place,
/// so [transferEntities] does it rather than the local copy engine.
bool transferNeedsRemote(List<String> sources, String destination) =>
    RemotePaths.isRemote(destination) || sources.any(RemotePaths.isRemote);

/// [pasteEntities] for network places: copies [sources] into
/// [destination], or moves them when [move], from this device to a place,
/// from a place to this device, within a place or between two. Folders go
/// with everything in them. Paths are this device's or browser paths
/// (`explorer://remote/...`). Returns where they ended up.
///
/// As there: nothing is overwritten (a taken name gets " (2)", a copy into
/// its own folder "name - Copy"), files are streamed, and [onProgress]
/// reports the bytes. A move within one place renames; between places it
/// copies, then deletes. [cancel] stops it at the next chunk, deleting the
/// file half copied. A file whose copy broke off as the line dropped is
/// copied again once.
Future<List<String>> transferEntities(
  List<String> sources,
  String destination, {
  required bool move,
  void Function(PasteProgress progress)? onProgress,
  RemoteCancel? cancel,
  RemotePool? pool,
}) async {
  final stop = cancel ?? RemoteCancel();
  final connections = pool ?? RemotePool.instance;
  _Side sideOf(String path) {
    final parsed = RemotePaths.parse(path);
    return parsed == null ? _LocalSide() : _RemoteSide(parsed.$1, connections);
  }

  final to = sideOf(destination);
  final targets = <String>[];
  final copies = <(_Side, _Node, String)>[];
  // The destination's names, looked at once; names given are added.
  final taken = await to.namesIn(destination);
  for (final source in sources) {
    stop.check();
    final from = sideOf(source);
    final node = await from.stat(source);
    if (node == null) continue;
    final same = from.sameAs(to);
    if (same && node.isDirectory && (from.equal(source, destination) || from.isWithin(source, destination))) {
      throw const RemoteException(RemoteErrorKind.other, "A folder can't be pasted into itself");
    }
    final sameFolder = same && from.equal(from.parentOf(source), destination);
    if (move && sameFolder) {
      targets.add(source); // Already here.
      continue;
    }
    final name = _freeName(taken, from.nameOf(source), isDirectory: node.isDirectory, copyOfItself: sameFolder);
    taken.add(name.toLowerCase());
    final target = to.join(destination, name);
    if (move && same) {
      try {
        await from.rename(source, target);
        targets.add(target);
        continue;
      } on FileSystemException {
        // Another drive: copied, then deleted.
      }
    }
    copies.add((from, node, target));
  }

  var total = 0;
  for (final (from, node, _) in copies) {
    total += await from.sizeOf(node, stop);
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

  for (final (from, node, target) in copies) {
    await _copy(from, node, to, target, progress, stop);
    if (move) await from.delete(node);
    targets.add(target);
  }
  onProgress?.call(PasteProgress(total, total, ''));
  return targets;
}

/// A name in a folder holding [taken] (lower case) that isn't taken.
String _freeName(Set<String> taken, String name, {required bool isDirectory, bool copyOfItself = false}) {
  bool used(String candidate) => taken.contains(candidate.toLowerCase());
  if (!copyOfItself && !used(name)) return name;
  final extension = isDirectory ? '' : p.extension(name);
  final base = name.substring(0, name.length - extension.length);
  for (var i = 1;; i++) {
    final candidate = copyOfItself
        ? (i == 1 ? '$base - Copy$extension' : '$base - Copy ($i)$extension')
        : '$base (${i + 1})$extension';
    if (!used(candidate)) return candidate;
  }
}

Future<void> _copy(
  _Side from,
  _Node node,
  _Side to,
  String target,
  void Function(String name, int bytes) progress,
  RemoteCancel stop,
) async {
  stop.check();
  if (node.isDirectory) {
    await to.mkdir(target);
    for (final child in await from.list(node.path)) {
      await _copy(from, child, to, to.join(target, from.nameOf(child.path)), progress, stop);
    }
    return;
  }
  final name = from.nameOf(node.path);
  for (var attempt = 0;; attempt++) {
    var sent = 0;
    try {
      final data = from.read(node.path).map((chunk) {
        stop.check();
        sent += chunk.length;
        progress(name, chunk.length);
        return chunk;
      });
      await to.write(target, data, node.size, modified: node.modified);
      return;
    } catch (e) {
      final error = e is FileSystemException ? null : remoteError(e);
      if (error?.kind != RemoteErrorKind.alreadyExists) {
        // Half copied: gone, so nothing broken is left behind.
        try {
          await to.deletePath(target);
        } catch (_) {}
      }
      progress(name, -sent);
      if (stop.isCancelled) stop.check();
      if (attempt > 0 || error?.kind != RemoteErrorKind.network) rethrow;
    }
  }
}

class _Node {
  const _Node(this.path, {required this.isDirectory, this.size = 0, this.modified});

  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
}

/// This device, or one network place.
abstract class _Side {
  bool sameAs(_Side other);
  bool equal(String a, String b);
  bool isWithin(String parent, String child);
  String join(String folder, String name);
  String nameOf(String path);
  String parentOf(String path);
  Future<Set<String>> namesIn(String folder);
  Future<_Node?> stat(String path);
  Future<List<_Node>> list(String folder);
  Stream<List<int>> read(String path);

  /// Fails if [path] exists.
  Future<void> write(String path, Stream<List<int>> data, int length, {DateTime? modified});
  Future<void> mkdir(String path);
  Future<void> rename(String from, String to);

  /// [node] with all that's in it.
  Future<void> delete(_Node node);
  Future<void> deletePath(String path);

  Future<int> sizeOf(_Node node, RemoteCancel stop) async {
    if (!node.isDirectory) return node.size;
    var size = 0;
    for (final child in await list(node.path)) {
      stop.check();
      size += await sizeOf(child, stop);
    }
    return size;
  }
}

class _LocalSide extends _Side {
  @override
  bool sameAs(_Side other) => other is _LocalSide;

  @override
  bool equal(String a, String b) => p.equals(a, b);

  @override
  bool isWithin(String parent, String child) => p.isWithin(parent, child);

  @override
  String join(String folder, String name) => p.join(folder, name);

  @override
  String nameOf(String path) => p.basename(path);

  @override
  String parentOf(String path) => p.dirname(path);

  @override
  Future<Set<String>> namesIn(String folder) async {
    final names = <String>{};
    try {
      await for (final entity in Directory(folder).list(followLinks: false)) {
        names.add(p.basename(entity.path).toLowerCase());
      }
    } on FileSystemException {
      // Missing: writing there says so.
    }
    return names;
  }

  Future<_Node?> _node(String path) async {
    final stat = await FileStat.stat(path);
    return switch (stat.type) {
      FileSystemEntityType.directory => _Node(path, isDirectory: true, modified: stat.modified),
      FileSystemEntityType.file => _Node(path, isDirectory: false, size: stat.size, modified: stat.modified),
      _ => null,
    };
  }

  @override
  Future<_Node?> stat(String path) => _node(path);

  @override
  Future<List<_Node>> list(String folder) async {
    final nodes = <_Node>[];
    await for (final entity in Directory(folder).list(followLinks: false)) {
      // A link to a folder could lead back up: only links to files are copied.
      if (entity is Link && await FileSystemEntity.isDirectory(entity.path)) continue;
      final node = await _node(entity.path);
      if (node != null) nodes.add(node);
    }
    return nodes;
  }

  @override
  Stream<List<int>> read(String path) => File(path).openRead();

  @override
  Future<void> write(String path, Stream<List<int>> data, int length, {DateTime? modified}) async {
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '"${p.basename(path)}" is already there');
    }
    final sink = file.openWrite();
    try {
      await sink.addStream(data);
    } finally {
      await sink.close();
    }
    if (modified != null) {
      try {
        await file.setLastModified(modified);
      } on FileSystemException {
        // Some file systems don't allow it; the copy is still good.
      }
    }
  }

  @override
  Future<void> mkdir(String path) => Directory(path).create(recursive: true);

  @override
  Future<void> rename(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    await (type == FileSystemEntityType.directory ? Directory(from) : File(from)).rename(to);
  }

  @override
  Future<void> delete(_Node node) => deletePath(node.path);

  @override
  Future<void> deletePath(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await (type == FileSystemEntityType.directory ? Directory(path) : File(path)).delete(recursive: true);
  }
}

class _RemoteSide extends _Side {
  _RemoteSide(this.id, this.pool);

  final String id;
  final RemotePool pool;

  String _remote(String browserPath) => RemotePaths.parse(browserPath)!.$2;

  String _browser(String remotePath) => RemotePaths.build(id, remotePath);

  _Node _node(RemoteEntry entry) =>
      _Node(_browser(entry.path), isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified);

  @override
  bool sameAs(_Side other) => other is _RemoteSide && other.id == id;

  @override
  bool equal(String a, String b) => _remote(a) == _remote(b);

  @override
  bool isWithin(String parent, String child) {
    final folder = _remote(parent);
    return _remote(child).startsWith(folder == '/' ? '/' : '$folder/') && _remote(child) != folder;
  }

  @override
  String join(String folder, String name) => _browser(RemotePaths.join(_remote(folder), name));

  @override
  String nameOf(String path) => RemotePaths.nameOf(_remote(path));

  @override
  String parentOf(String path) => _browser(RemotePaths.parentOf(_remote(path)));

  @override
  Future<Set<String>> namesIn(String folder) async {
    try {
      final entries = await pool.run(id, (fs) => fs.list(_remote(folder)));
      return {for (final e in entries) e.name.toLowerCase()};
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return {};
      rethrow;
    }
  }

  @override
  Future<_Node?> stat(String path) async {
    try {
      return _node(await pool.run(id, (fs) => fs.stat(_remote(path))));
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<List<_Node>> list(String folder) async =>
      [for (final e in await pool.run(id, (fs) => fs.list(_remote(folder)))) _node(e)];

  @override
  Stream<List<int>> read(String path) => pool.openRead(id, _remote(path));

  @override
  Future<void> write(String path, Stream<List<int>> data, int length, {DateTime? modified}) =>
      pool.run(id, (fs) => fs.write(_remote(path), data, length: length), retry: false);

  @override
  Future<void> mkdir(String path) => pool.run(id, (fs) => fs.createDirectory(_remote(path)));

  @override
  Future<void> rename(String from, String to) => pool.run(id, (fs) => fs.rename(_remote(from), _remote(to)));

  @override
  Future<void> delete(_Node node) => deletePath(node.path);

  @override
  Future<void> deletePath(String path) async {
    try {
      await pool.run(id, (fs) => fs.delete(_remote(path)));
    } on RemoteException catch (e) {
      if (e.kind != RemoteErrorKind.notFound) rethrow;
    }
  }
}
