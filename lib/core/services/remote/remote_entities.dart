import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart';

/// Files and folders of network places as the browser's entities: the list,
/// grid, selection, sorting, grouping and drag and drop all work with
/// dart:io's [File] and [Directory], so these stand in for them. Their
/// [path] is the browser path (`explorer://remote/<id>/<path>`).
///
/// What the listing told is answered at once (stat, exists, length, dates);
/// a folder's [Directory.list] and a file's [File.openRead] go through the
/// place's connection. Anything else throws a [FileSystemException]: such a
/// path must never reach this device's disks, where Windows could make odd
/// folders of it.
abstract interface class RemoteEntity implements FileSystemEntity {
  /// What the listing said.
  RemoteEntry get entry;

  /// The place it's on.
  String get connectionId;

  /// Its path within the place (`/Photos/a.jpg`).
  String get remotePath;

  /// Whether [entity] is one.
  static bool isIn(FileSystemEntity entity) => entity is RemoteEntity;

  /// Whether any of [entities] is one.
  static bool anyIn(Iterable<FileSystemEntity> entities) => entities.any(isIn);

  /// A [RemoteFile] or [RemoteDirectory] for [entry] on [connectionId].
  static FileSystemEntity of(String connectionId, RemoteEntry entry) {
    if (entry.isDirectory) return RemoteDirectory(connectionId, entry);
    final file = RemoteFile(connectionId, entry);
    _sizes.remove(file.path);
    _sizes[file.path] = entry.size;
    if (_sizes.length > 20000) _sizes.remove(_sizes.keys.first);
    return file;
  }

  static final _sizes = <String, int>{};

  /// The size of a file listed lately, by its browser path (what has only
  /// the path, as a thumbnail, asks here).
  static int? knownSize(String path) => _sizes[path];
}

/// [FileStat] of a remote entry, from its listing.
class RemoteFileStat implements FileStat {
  RemoteFileStat(RemoteEntry entry)
      : type = entry.isDirectory ? FileSystemEntityType.directory : FileSystemEntityType.file,
        size = entry.isDirectory ? 0 : entry.size,
        modified = entry.modified ?? _epoch;

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  final FileSystemEntityType type;

  @override
  final int size;

  @override
  final DateTime modified;

  @override
  DateTime get changed => modified;

  @override
  DateTime get accessed => modified;

  /// Unknown: rw-r--r-- for files, rwxr-xr-x for folders.
  @override
  int get mode => type == FileSystemEntityType.directory ? 0x1ED : 0x1A4;

  @override
  String modeString() {
    const codes = ['---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx'];
    final m = mode;
    return '${codes[(m >> 6) & 7]}${codes[(m >> 3) & 7]}${codes[m & 7]}';
  }

  @override
  String toString() => 'FileStat: type $type modified $modified size $size';
}

FileSystemException _notHere(String path) =>
    FileSystemException('This is on another computer, not on this device', path);

/// Shared by [RemoteFile] and [RemoteDirectory].
abstract class _RemoteBase implements RemoteEntity {
  _RemoteBase(this.connectionId, this.entry) : path = RemotePaths.build(connectionId, entry.path);

  @override
  final String connectionId;

  @override
  final RemoteEntry entry;

  @override
  final String path;

  @override
  String get remotePath => entry.path;

  @override
  Uri get uri => Uri.parse(path);

  @override
  bool get isAbsolute => true;

  @override
  Directory get parent => RemoteDirectory(
        connectionId,
        RemoteEntry(path: RemotePaths.parentOf(entry.path), isDirectory: true),
      );

  @override
  Future<bool> exists() async => true;

  @override
  bool existsSync() => true;

  @override
  Future<FileStat> stat() async => RemoteFileStat(entry);

  @override
  FileStat statSync() => RemoteFileStat(entry);

  @override
  Future<String> resolveSymbolicLinks() async => path;

  @override
  String resolveSymbolicLinksSync() => path;

  @override
  Stream<FileSystemEvent> watch({int events = FileSystemEvent.all, bool recursive = false}) =>
      const Stream.empty();

  @override
  bool operator ==(Object other) => other is _RemoteBase && other.runtimeType == runtimeType && other.path == path;

  @override
  int get hashCode => Object.hash(runtimeType, path);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw _notHere(path);
}

class RemoteFile extends _RemoteBase implements File {
  RemoteFile(super.connectionId, super.entry);

  @override
  File get absolute => this;

  @override
  Future<int> length() async => entry.size;

  @override
  int lengthSync() => entry.size;

  @override
  Future<DateTime> lastModified() async => entry.modified ?? RemoteFileStat._epoch;

  @override
  DateTime lastModifiedSync() => entry.modified ?? RemoteFileStat._epoch;

  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      RemotePool.instance.openRead(connectionId, entry.path, start: start ?? 0, end: end);

  @override
  String toString() => "RemoteFile: '$path'";
}

class RemoteDirectory extends _RemoteBase implements Directory {
  RemoteDirectory(super.connectionId, super.entry);

  @override
  Directory get absolute => this;

  /// What's inside, through the place's connection; with [recursive] the
  /// folders inside too, each listed after its folder.
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) async* {
    final pending = [entry.path];
    while (pending.isNotEmpty) {
      final folder = pending.removeAt(0);
      final List<RemoteEntry> entries;
      try {
        entries = await RemotePool.instance.run(connectionId, (fs) => fs.list(folder));
      } on RemoteException catch (e) {
        if (folder == entry.path) throw FileSystemException(e.message, RemotePaths.build(connectionId, folder));
        continue; // An unreadable folder inside: skipped, as dart:io's list does.
      }
      for (final child in entries) {
        yield RemoteEntity.of(connectionId, child);
        if (recursive && child.isDirectory) pending.add(child.path);
      }
    }
  }

  @override
  String toString() => "RemoteDirectory: '$path'";
}
