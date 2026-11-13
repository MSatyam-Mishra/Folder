import 'dart:io';

import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart';

/// The browser's [FileRepository] for network places
/// (`explorer://remote/<id>/<path>`), through [RemotePool]. Paths never
/// reach dart:io.
class RemoteFileRepository implements FileRepository {
  RemoteFileRepository({RemotePool? pool}) : _pool = pool;

  final RemotePool? _pool;

  RemotePool get pool => _pool ?? RemotePool.instance;

  static (String, String) _parse(String path) {
    final parsed = RemotePaths.parse(path);
    if (parsed == null) throw ArgumentError.value(path, 'path', 'not on a network place');
    return parsed;
  }

  @override
  Future<List<FileSystemEntity>> listEntities(String path) async {
    final (id, remote) = _parse(path);
    final entries = await pool.run(id, (fs) => fs.list(remote));
    final prefs = FolderPrefsService();
    await prefs.init();
    return [
      for (final entry in entries)
        if (prefs.showHidden || !entry.name.startsWith('.')) RemoteEntity.of(id, entry),
    ];
  }

  @override
  Future<void> delete(String path, {bool recursive = false}) async {
    final (id, remote) = _parse(path);
    await pool.run(id, (fs) => fs.delete(remote));
  }

  @override
  Future<void> rename(String path, String newPath) async {
    final (id, from) = _parse(path);
    final (toId, to) = _parse(newPath);
    if (toId != id) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Only within one place: copy it to the other one instead.');
    }
    await pool.run(id, (fs) => fs.rename(from, to));
  }

  @override
  Future<bool> exists(String path) async {
    final (id, remote) = _parse(path);
    try {
      await pool.run(id, (fs) => fs.stat(remote));
      return true;
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return false;
      rethrow;
    }
  }

  @override
  Future<FileSystemEntityType> type(String path) async {
    final (id, remote) = _parse(path);
    try {
      final entry = await pool.run(id, (fs) => fs.stat(remote));
      return entry.isDirectory ? FileSystemEntityType.directory : FileSystemEntityType.file;
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return FileSystemEntityType.notFound;
      rethrow;
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    final (id, remote) = _parse(path);
    await pool.run(id, (fs) => fs.createDirectory(remote));
  }

  @override
  Future<void> createFile(String path) async {
    final (id, remote) = _parse(path);
    await pool.run(id, (fs) => fs.write(remote, const Stream.empty(), length: 0), retry: false);
  }

  @override
  Future<List<Directory>> getStorageVolumes() async => const [];
}
