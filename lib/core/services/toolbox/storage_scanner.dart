import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/toolbox/folder_listing.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' show GetCompressedFileSize, GetDiskFreeSpace, GetDiskFreeSpaceEx, GetLastError;

/// What a file is, for the Storage analyzer's colours and summary.
enum StorageKind {
  videos('Videos'),
  photos('Photos'),
  music('Music'),
  documents('Documents'),
  apps('Apps'),
  archives('Archives'),
  other('Other');

  const StorageKind(this.label);

  final String label;

  static final Map<String, StorageKind> _byExtension = {
    for (final ext in FileTypes.video) ext: videos,
    for (final ext in const {'ts', 'rm', 'rmvb', 'asf', 'f4v', 'y4m'}) ext: videos,
    for (final set in [FileTypes.image, FileTypes.rasterImage, FileTypes.svg, FileTypes.cameraRaw])
      for (final ext in set) ext: photos,
    for (final ext in const {'jxl', 'xcf', 'ai', 'kra', 'procreate', 'afphoto'}) ext: photos,
    for (final ext in FileTypes.audio) ext: music,
    for (final ext in const {'mid', 'midi', 'ape', 'wv', 'dsf', 'dff', 'alac', 'm3u', 'm3u8'}) ext: music,
    for (final set in [
      FileTypes.pdf, FileTypes.epub, FileTypes.ebook, FileTypes.comic, FileTypes.word, FileTypes.legacyWord,
      FileTypes.richText, FileTypes.openDocumentText, FileTypes.spreadsheet, FileTypes.legacySpreadsheet,
      FileTypes.delimited, FileTypes.openDocumentSpreadsheet, FileTypes.presentation,
      FileTypes.legacyPresentation, FileTypes.openDocumentPresentation, FileTypes.markdown,
    ])
      for (final ext in set) ext: documents,
    for (final ext in const {'txt', 'pages', 'numbers', 'key', 'one', 'xps', 'oxps', 'djvu', 'chm', 'tex'}) ext: documents,
    for (final ext in FileTypes.archive) ext: archives,
    for (final ext in FileTypes.diskImage) ext: archives,
    for (final ext in const {'zst', 'lz', 'lz4', 'lzma', 'cab', 'arj', 'z', 'img', 'vhd', 'vhdx', 'vmdk', 'wim', 'esd', 'tzst'})
      ext: archives,
    // After the archives: an .apk is a ZIP, but it's an app.
    for (final ext in FileTypes.package) ext: apps,
    for (final ext in const {
      'xapk', 'apks', 'apkm', 'aab', 'msix', 'msixbundle', 'appxbundle', 'appimage', 'flatpak', 'snap',
      'ipa', 'pkg', 'mpkg', 'dll', 'so', 'dylib', 'sys', 'com', 'bat', 'cmd', 'jar',
    })
      ext: apps,
  };

  /// The kind of a file called [name].
  static StorageKind ofName(String name) {
    final dot = name.lastIndexOf('.');
    // No extension, or a name like ".gitignore".
    if (dot <= 0 || dot == name.length - 1) return other;
    final ext = name.substring(dot + 1).toLowerCase();
    final kind = _byExtension[ext];
    if (kind != null) return kind;
    // The parts of a split archive: .001, .002…
    if (ext.length == 3 && _isDigits(ext)) return archives;
    return other;
  }

  static bool _isDigits(String text) {
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }
}

/// A folder or a file in a scanned tree.
sealed class StorageNode {
  StorageNode(this.name, this.parent);

  /// The root's name is its whole path.
  final String name;
  StorageFolder? parent;

  bool get isFolder;

  /// Bytes, as the files' sizes add up.
  int get size;

  /// Bytes taken on the drive: whole clusters, nothing for a file that's
  /// only in the cloud, and less for a compressed one.
  int get disk;

  /// Files in it, however deep (1 for a file).
  int get files;

  String get path {
    final parent = this.parent;
    return parent == null ? name : p.join(parent.path, name);
  }

  /// From the root down to this one.
  List<StorageNode> get trail {
    final trail = <StorageNode>[];
    for (StorageNode? node = this; node != null; node = node.parent) {
      trail.add(node);
    }
    return trail.reversed.toList();
  }

  static int bigFirst(StorageNode a, StorageNode b) => b.disk.compareTo(a.disk);
}

/// A file, small enough an object that millions of them fit in memory.
final class StorageFile extends StorageNode {
  StorageFile(super.name, super.parent, this.size, this.disk, this.kind);

  @override
  final int size;
  @override
  final int disk;
  final StorageKind kind;

  @override
  bool get isFolder => false;

  @override
  int get files => 1;
}

/// A folder: its numbers are all it holds, however deep. Its [children]
/// are its folders and its biggest files, biggest first; files too small to
/// list one by one are only counted ([smallFiles], [smallDisk]), which keeps
/// a scan of millions of files in reasonable memory.
final class StorageFolder extends StorageNode {
  StorageFolder(super.name, super.parent);

  @override
  int size = 0;
  @override
  int disk = 0;
  @override
  int files = 0;

  /// Folders in it, however deep.
  int folders = 0;

  /// Folders and the biggest files, biggest first.
  List<StorageNode> children = const [];

  /// [disk] by [StorageKind].
  Int64List kinds = Int64List(StorageKind.values.length);

  /// Files right in this folder that aren't in [children], and their size.
  int smallFiles = 0;
  int smallDisk = 0;

  /// The folder couldn't be read, so it counts as empty.
  bool unreadable = false;

  /// Shared by the empty folders, which there are many of; never written to.
  static final _noKinds = Int64List(StorageKind.values.length);

  @override
  bool get isFolder => true;

  /// Its folders, the biggest first.
  Iterable<StorageFolder> get subfolders => children.whereType<StorageFolder>();

  /// The [count] biggest files in this folder, however deep. Exact: a file
  /// left out of its folder's [children] has that many bigger ones beside
  /// it as long as [count] is no more than [StorageScanner.keepFiles].
  List<StorageFile> biggestFiles(int count) {
    final found = <StorageFile>[];
    var smallest = 0;
    void visit(StorageFolder folder) {
      for (final child in folder.children) {
        // Nothing in a folder can be bigger than all of it.
        if (found.length >= count && child.disk <= smallest) continue;
        switch (child) {
          case StorageFolder():
            visit(child);
          case StorageFile():
            found.add(child);
            if (found.length > count * 2) {
              found.sort(StorageNode.bigFirst);
              found.length = count;
              // Only grows from here, so what's no bigger can't get in.
              smallest = found.last.disk;
            }
        }
      }
    }

    visit(this);
    found.sort(StorageNode.bigFirst);
    if (found.length > count) found.length = count;
    return found;
  }

  /// Takes [node] out of the tree, as when it's deleted: every folder above
  /// it shrinks by what it held.
  static void remove(StorageNode node) {
    final parent = node.parent;
    if (parent == null) return;
    parent.children = List.unmodifiable([
      for (final child in parent.children)
        if (!identical(child, node)) child,
    ]);
    for (StorageFolder? above = parent; above != null; above = above.parent) {
      above
        ..size -= node.size
        ..disk -= node.disk
        ..files -= node.files;
      if (node is StorageFolder) above.folders -= node.folders + 1;
      // An empty one's kinds are the shared zeros, and change nothing.
      if (node.disk == 0) continue;
      final kinds = above.kinds;
      switch (node) {
        case StorageFolder():
          for (var i = 0; i < kinds.length; i++) {
            kinds[i] -= node.kinds[i];
          }
        case StorageFile():
          kinds[node.kind.index] -= node.disk;
      }
    }
    node.parent = null;
  }
}

/// How far a scan has come, a few times a second.
class StorageScanProgress {
  const StorageScanProgress({required this.files, required this.folders, required this.disk, required this.place});

  final int files;
  final int folders;

  /// Bytes on disk found so far.
  final int disk;

  /// The folder being read.
  final String place;
}

/// What a scan found.
class StorageScanResult {
  const StorageScanResult({
    required this.root,
    required this.unreadable,
    required this.links,
    required this.skipped,
    required this.took,
  });

  final StorageFolder root;

  /// Folders that couldn't be read (the system's own, mostly).
  final int unreadable;

  /// Links and junctions, never followed.
  final int links;

  /// Other drives mounted inside, and the system's virtual folders, left out.
  final int skipped;
  final Duration took;
}

/// Reads a folder tree from the disk, on whatever isolate calls [scan].
class StorageScanner {
  StorageScanner(this.root, {this.report, this.stop, @visibleForTesting Set<String>? skip})
      : _skip = skip ?? mountsInside(root);

  final String root;

  /// Asked before each folder; true ends the scan there, between listings,
  /// so no folder is left open.
  final bool Function()? stop;
  final void Function(StorageScanProgress progress)? report;

  /// Files kept one by one per folder, at the most.
  static const keepFiles = 200;

  /// Small files kept one by one per folder; the rest are counted. Most
  /// files on a disk are small, and they'd take most of the memory.
  static const keepSmallFiles = 20;
  static const smallFile = 64 * 1024;

  final Set<String> _skip;
  final _clock = Stopwatch();
  var _told = -1000;
  var _files = 0;
  var _folders = 0;
  var _disk = 0;
  var _unreadable = 0;
  var _links = 0;
  var _skipped = 0;
  late final int _cluster = clusterSize(root);

  StorageScanResult scan() {
    _clock.start();
    final top = StorageFolder(p.normalize(root), null);
    _scan(top, top.name, inApp: false);
    _tell(top.name, now: true);
    return StorageScanResult(
      root: top,
      unreadable: _unreadable,
      links: _links,
      skipped: _skipped,
      took: _clock.elapsed,
    );
  }

  void _tell(String place, {bool now = false}) {
    final report = this.report;
    if (report == null) return;
    final at = _clock.elapsedMilliseconds;
    if (!now && at - _told < 100) return;
    _told = at;
    report(StorageScanProgress(files: _files, folders: _folders, disk: _disk, place: place));
  }

  /// Reads [folder] at [path] and all it holds, or with [deferred] only
  /// what's right in it: its folders then go to [deferred], empty, for
  /// someone else to read, and [settle] adds them up afterwards.
  void _scan(StorageFolder folder, String path, {required bool inApp, List<_Task>? deferred}) {
    if (stop?.call() ?? false) throw const ScanStopped();
    final entries = FolderListing.list(path);
    if (entries == null) {
      folder.unreadable = true;
      _unreadable++;
      return;
    }
    _folders++;
    _tell(path);
    final prefix = path.endsWith(Platform.pathSeparator) ? path : '$path${Platform.pathSeparator}';
    final kinds = folder.kinds;
    final children = <StorageNode>[];
    List<StorageFile>? files;
    for (final entry in entries) {
      switch (entry.kind) {
        case EntryKind.link:
          _links++;
        case EntryKind.folder:
          final childPath = '$prefix${entry.name}';
          if (_skip.contains(childPath)) {
            _skipped++;
            continue;
          }
          final child = StorageFolder(entry.name, folder);
          // A Mac app is a folder, and all of it is the app.
          final app = inApp || (Platform.isMacOS && entry.name.endsWith('.app'));
          children.add(child);
          if (deferred != null) {
            deferred.add(_Task(child, childPath, app));
            continue;
          }
          _scan(child, childPath, inApp: app);
          folder
            ..size += child.size
            ..disk += child.disk
            ..files += child.files
            ..folders += child.folders + 1;
          final inside = child.kinds;
          for (var i = 0; i < kinds.length; i++) {
            kinds[i] += inside[i];
          }
        case EntryKind.file:
          final disk = _onDisk(entry, prefix);
          final kind = inApp ? StorageKind.apps : StorageKind.ofName(entry.name);
          (files ??= []).add(StorageFile(entry.name, folder, entry.size, disk, kind));
          folder
            ..size += entry.size
            ..disk += disk
            ..files += 1;
          kinds[kind.index] += disk;
          _files++;
          _disk += disk;
          if (_files & 255 == 0) _tell(path);
      }
    }
    if (files != null) {
      files.sort(StorageNode.bigFirst);
      var kept = 0;
      var small = 0;
      for (final file in files) {
        final keep = kept < keepFiles && (file.disk >= smallFile || small < keepSmallFiles);
        if (keep) {
          children.add(file);
          kept++;
          if (file.disk < smallFile) small++;
        } else {
          file.parent = null;
          folder
            ..smallFiles += 1
            ..smallDisk += file.disk;
        }
      }
    }
    if (deferred != null) {
      // Sorted and sealed in settle, once its folders are read.
      folder.children = children;
      return;
    }
    _seal(folder, children);
  }

  static void _seal(StorageFolder folder, List<StorageNode> children) {
    if (children.isNotEmpty) {
      children.sort(StorageNode.bigFirst);
      folder.children = List.unmodifiable(children);
    } else {
      folder.children = const [];
    }
    if (folder.disk == 0) folder.kinds = StorageFolder._noKinds;
  }

  /// Adds the folders read elsewhere into the ones [expanded] read shallow,
  /// the deepest first.
  static void settle(List<StorageFolder> expanded) {
    for (final folder in expanded.reversed) {
      final kinds = folder.kinds;
      for (final child in folder.children) {
        if (child is! StorageFolder) continue;
        folder
          ..size += child.size
          ..disk += child.disk
          ..files += child.files
          ..folders += child.folders + 1;
        for (var i = 0; i < kinds.length; i++) {
          kinds[i] += child.kinds[i];
        }
      }
      _seal(folder, List.of(folder.children));
    }
  }

  /// Reads the folder [task] stands for, as a worker does.
  void _scanTask(_Task task) {
    _clock.start();
    _scan(task.folder, task.path, inApp: task.inApp);
  }

  // Windows' FILE_ATTRIBUTE_*.
  static const _sparse = 0x200;
  static const _compressed = 0x800;
  static const _offline = 0x1000;
  static const _recallOnDataAccess = 0x400000;

  int _onDisk(FolderEntry entry, String prefix) {
    final size = entry.size;
    if (size == 0) return 0;
    final attributes = entry.attributes;
    if (attributes != 0) {
      // OneDrive's and other cloud files that aren't downloaded.
      if (attributes & (_offline | _recallOnDataAccess) != 0) return 0;
      if (attributes & (_sparse | _compressed) != 0 && Platform.isWindows) {
        final actual = _compressedSize('$prefix${entry.name}');
        if (actual != null) return roundUp(actual, _cluster);
      }
    }
    return roundUp(size, _cluster);
  }

  static int roundUp(int size, int cluster) => size == 0 ? 0 : ((size + cluster - 1) ~/ cluster) * cluster;

  static int? _compressedSize(String path) => using((arena) {
        final high = arena<Uint32>();
        final low = GetCompressedFileSize(path.toNativeUtf16(allocator: arena), high);
        if (low == 0xFFFFFFFF && GetLastError() != 0) return null;
        return high.value * 0x100000000 + low;
      });

  /// The drive's allocation unit, which every file's size is rounded up to.
  static int clusterSize(String path) {
    if (!Platform.isWindows) return 4096;
    return using((arena) {
      final sectors = arena<Uint32>();
      final bytes = arena<Uint32>();
      final free = arena<Uint32>();
      final total = arena<Uint32>();
      final root = p.windows.rootPrefix(p.windows.normalize(path));
      final ok = GetDiskFreeSpace(
        (root.endsWith(r'\') ? root : '$root\\').toNativeUtf16(allocator: arena),
        sectors,
        bytes,
        free,
        total,
      );
      final cluster = sectors.value * bytes.value;
      return ok == 0 || cluster <= 0 ? 4096 : cluster;
    });
  }

  /// Folders inside [root] to leave out: other drives mounted there, and
  /// the system's virtual folders, which aren't on any disk.
  static Set<String> mountsInside(String root) {
    if (Platform.isWindows) return const {}; // Mounted folders are junctions there.
    final top = p.normalize(root);
    final skip = <String>{};
    if (Platform.isMacOS) {
      // The data volume is also reached through /System/Volumes/Data.
      skip.addAll(const ['/System/Volumes', '/Volumes', '/dev', '/private/var/vm', '/.vol']);
    }
    if (Platform.isLinux || Platform.isAndroid) {
      skip.addAll(const ['/proc', '/sys', '/dev', '/run']);
      try {
        for (final line in File('/proc/self/mounts').readAsLinesSync()) {
          final parts = line.split(' ');
          if (parts.length > 1) skip.add(decodeMountPath(parts[1]));
        }
      } on FileSystemException {
        // Not readable: only the virtual folders are left out.
      }
    }
    return {
      for (final path in skip)
        if (p.isWithin(top, path)) path,
    };
  }

  /// A path from /proc/self/mounts, where a space is written "\040".
  static String decodeMountPath(String raw) => raw.replaceAllMapped(
        RegExp(r'\\([0-7]{3})'),
        (match) => String.fromCharCode(int.parse(match[1]!, radix: 8)),
      );
}

/// Thrown out of a scan that was asked to stop.
class ScanStopped implements Exception {
  const ScanStopped();
}

/// A folder for a worker to read: an empty node in the tree, filled in place
/// with what the worker found.
class _Task {
  _Task(this.folder, this.path, this.inApp);

  final StorageFolder folder;
  final String path;
  final bool inApp;
}

/// Reads a tree with a few isolates at once: opening a folder is most of
/// what a scan waits for, and the system does several at a time about as
/// fast as one. This isolate reads the first levels itself until there are
/// folders enough to share out, then hands them to [workers] isolates one
/// at a time, and fits what they found into the tree.
class ParallelStorageScan {
  ParallelStorageScan(this.root, {required this.workers, this.report, this.onWorker, this.stopFlag});

  final String root;
  final int workers;

  /// The address of a byte that turns 1 to stop; the workers read it too.
  final int? stopFlag;
  final void Function(StorageScanProgress progress)? report;

  /// Each worker as it starts, so whoever can stop this scan can stop them.
  final void Function(Isolate worker)? onWorker;

  /// Folders shared out per worker, at least, before they start.
  static const _tasksPerWorker = 24;

  Future<StorageScanResult> scan() async {
    final clock = Stopwatch()..start();
    final skip = StorageScanner.mountsInside(root);
    final flag = stopFlag;
    final here = StorageScanner(root, skip: skip, stop: flag == null ? null : _flagReader(flag)).._clock.start();
    final top = StorageFolder(p.normalize(root), null);
    final expanded = <StorageFolder>[];
    final tasks = <_Task>[];
    var level = [_Task(top, top.name, false)];
    for (var depth = 0; level.isNotEmpty; depth++) {
      final next = <_Task>[];
      for (final task in level) {
        expanded.add(task.folder);
        here._scan(task.folder, task.path, inApp: task.inApp, deferred: next);
      }
      if (next.length >= workers * _tasksPerWorker || depth >= 3) {
        tasks.addAll(next);
        break;
      }
      level = next;
    }

    var unreadable = here._unreadable;
    var links = here._links;
    var skipped = here._skipped;
    if (tasks.isNotEmpty) {
      final count = math.min(workers, tasks.length);
      final port = ReceivePort();
      final finished = Completer<void>();
      final ports = List<SendPort?>.filled(count, null);
      final inFlight = List<int?>.filled(count, null);
      final returned = List<bool>.filled(count, false);
      final totals = List<(int, int, int)>.filled(count, (0, 0, 0));
      var place = top.name;
      var next = 0;
      var ended = 0;
      var told = -1000;

      void tell() {
        final report = this.report;
        if (report == null) return;
        final at = clock.elapsedMilliseconds;
        if (at - told < 100) return;
        told = at;
        var files = here._files;
        var folders = here._folders;
        var disk = here._disk;
        for (final (f, d, b) in totals) {
          files += f;
          folders += d;
          disk += b;
        }
        report(StorageScanProgress(files: files, folders: folders, disk: disk, place: place));
      }

      void give(int worker) {
        if (next < tasks.length) {
          final task = tasks[next];
          inFlight[worker] = next;
          ports[worker]!.send([next, task.path, task.inApp]);
          next++;
        } else {
          inFlight[worker] = null;
          ports[worker]!.send(null);
        }
      }

      void end() {
        ended++;
        if (ended == count && !finished.isCompleted) finished.complete();
      }

      port.listen((message) {
        if (message is! List || message.isEmpty) return;
        switch (message[0]) {
          case 'ready':
            final worker = message[1] as int;
            ports[worker] = message[2] as SendPort;
            give(worker);
          case 'next':
            give(message[1] as int);
          case 'progress':
            final worker = message[1] as int;
            totals[worker] = (message[2] as int, message[3] as int, message[4] as int);
            place = message[5] as String;
            tell();
          case 'results':
            final worker = message[1] as int;
            returned[worker] = true;
            final found = message[2] as Map<int, StorageFolder>;
            found.forEach((index, folder) => _fill(tasks[index].folder, folder));
            unreadable += message[3] as int;
            links += message[4] as int;
            skipped += message[5] as int;
            end();
          case 'exit':
            // Ended without its results, as it failed: what it was reading
            // counts as unreadable.
            final worker = message[1] as int;
            if (returned[worker]) return;
            returned[worker] = true;
            final lost = inFlight[worker];
            if (lost != null) tasks[lost].folder.unreadable = true;
            end();
        }
      });
      for (var worker = 0; worker < count; worker++) {
        final isolate = await Isolate.spawn(
          _work,
          (port.sendPort, worker, root, skip, stopFlag),
          paused: true,
          debugName: 'storage scan $worker',
        );
        isolate.addOnExitListener(port.sendPort, response: ['exit', worker]);
        onWorker?.call(isolate);
        isolate.resume(isolate.pauseCapability!);
      }
      await finished.future;
      port.close();
    }
    StorageScanner.settle(expanded);
    return StorageScanResult(root: top, unreadable: unreadable, links: links, skipped: skipped, took: clock.elapsed);
  }

  /// Moves what a worker found into the tree's empty node for it.
  static void _fill(StorageFolder into, StorageFolder from) {
    into
      ..size = from.size
      ..disk = from.disk
      ..files = from.files
      ..folders = from.folders
      ..children = from.children
      ..kinds = from.kinds
      ..smallFiles = from.smallFiles
      ..smallDisk = from.smallDisk
      ..unreadable = from.unreadable;
    for (final child in from.children) {
      child.parent = into;
    }
  }

  /// A worker: reads the folders it's given until it's told there are no
  /// more, then hands back all it found without a copy.
  static bool Function() _flagReader(int address) {
    final flag = Pointer<Uint8>.fromAddress(address);
    return () => flag.value != 0;
  }

  static void _work((SendPort, int, String, Set<String>, int?) job) {
    final (coordinator, worker, root, skip, stopFlag) = job;
    final inbox = RawReceivePort();
    final found = <int, StorageFolder>{};
    final scanner = StorageScanner(
      root,
      skip: skip,
      stop: stopFlag == null ? null : _flagReader(stopFlag),
      report: (progress) =>
          coordinator.send(['progress', worker, progress.files, progress.folders, progress.disk, progress.place]),
    );
    inbox.handler = (Object? message) {
      if (message is List) {
        final index = message[0] as int;
        final path = message[1] as String;
        final folder = StorageFolder(p.basename(path), null);
        try {
          scanner._scanTask(_Task(folder, path, message[2] as bool));
        } on ScanStopped {
          // Asked to stop: it ends without its results, which nobody wants.
          inbox.close();
          Isolate.exit();
        }
        found[index] = folder;
        coordinator.send(['next', worker]);
      } else {
        inbox.close();
        Isolate.exit(coordinator, ['results', worker, found, scanner._unreadable, scanner._links, scanner._skipped]);
      }
    };
    coordinator.send(['ready', worker, inbox.sendPort]);
  }
}

/// A scan in the background: it tells how far it has come and stops at
/// once when asked.
class StorageScan {
  StorageScan(this.root, {this.onProgress, int? workers}) : workers = workers ?? defaultWorkers;

  final String root;
  final void Function(StorageScanProgress progress)? onProgress;

  /// Isolates reading folders at once.
  final int workers;

  /// A few, but never all the cores, so the app stays smooth meanwhile.
  static int get defaultWorkers => math.max(1, math.min(4, Platform.numberOfProcessors - 1));

  Isolate? _isolate;
  final _workers = <Isolate>[];
  var _stopped = false;
  final _done = Completer<StorageScanResult?>();

  /// Turns 1 to stop; the isolates read it before each folder, so they
  /// close what they have open (on Windows a folder held open by a killed
  /// isolate can't be renamed or deleted until the app ends).
  final Pointer<Uint8> _stop = calloc<Uint8>();
  var _exited = false;
  var _killed = false;
  Timer? _fallback;

  /// What the scan found; null if it was stopped. Throws if it failed.
  Future<StorageScanResult?> start() async {
    final port = ReceivePort();
    Object? failure;
    port.listen((message) {
      if (message is StorageScanProgress) {
        if (!_stopped) onProgress?.call(message);
      } else if (message is Isolate) {
        _workers.add(message);
      } else if (message is StorageScanResult) {
        if (!_done.isCompleted) _done.complete(message);
      } else if (message is List) {
        failure = message.firstOrNull;
      } else if (message == null) {
        _exited = true;
        _fallback?.cancel();
        // Workers may still read the flag after a kill: then it stays.
        if (!_killed) calloc.free(_stop);
        if (!_done.isCompleted) {
          _stopped ? _done.complete(null) : _done.completeError(StateError("The scan didn't finish: ${failure ?? 'it ended'}"));
        }
        port.close();
      }
    });
    final send = port.sendPort;
    try {
      _isolate = await Isolate.spawn(_run, (send, root, workers, _stop.address), onExit: send, onError: send);
    } on Object catch (error) {
      port.close();
      _exited = true;
      calloc.free(_stop);
      if (!_done.isCompleted) _done.completeError(error);
    }
    return _done.future;
  }

  static Future<void> _run((SendPort, String, int, int) job) async {
    final (send, root, workers, stopFlag) = job;
    try {
      final result = workers <= 1
          ? StorageScanner(root, report: send.send, stop: ParallelStorageScan._flagReader(stopFlag)).scan()
          : await ParallelStorageScan(root, workers: workers, report: send.send, onWorker: send.send, stopFlag: stopFlag)
              .scan();
      // The whole tree goes back as it is, without a copy.
      Isolate.exit(send, result);
    } on ScanStopped {
      // Stopped: nothing to send.
    }
  }

  /// Stops within a folder or two, workers too; [start] gives null.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    if (!_exited) _stop.value = 1;
    if (!_done.isCompleted) _done.complete(null);
    // A drive that doesn't answer may hold a listing up: then it's ended.
    _fallback = Timer(const Duration(seconds: 10), () {
      if (_exited) return;
      _killed = true;
      _isolate?.kill(priority: Isolate.immediate);
      for (final worker in _workers) {
        worker.kill(priority: Isolate.immediate);
      }
    });
  }
}

/// How much a drive holds, in bytes.
class StorageSpace {
  const StorageSpace(this.total, this.free);

  final int total;
  final int free;

  int get used => total - free;

  /// The drive holding [path]; null if the system won't say.
  static Future<StorageSpace?> of(String path) async {
    try {
      if (Platform.isWindows) {
        return await Isolate.run(() => using((arena) {
              final free = arena<Uint64>();
              final total = arena<Uint64>();
              final folder = path.endsWith(r'\') ? path : '$path\\';
              final ok = GetDiskFreeSpaceEx(folder.toNativeUtf16(allocator: arena), nullptr, total, free);
              return ok == 0 ? null : StorageSpace(total.value, free.value);
            }));
      }
      // POSIX df: blocks of 1 KB.
      final result = await Process.run('df', ['-Pk', path]);
      if (result.exitCode != 0) return null;
      return parseDf('${result.stdout}');
    } on Object {
      return null;
    }
  }

  /// The drive's size and free space from `df -Pk`'s output.
  static StorageSpace? parseDf(String output) {
    final lines = output.trim().split('\n');
    if (lines.length < 2) return null;
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    if (fields.length < 4) return null;
    final total = int.tryParse(fields[1]);
    final free = int.tryParse(fields[3]);
    if (total == null || free == null || total <= 0) return null;
    return StorageSpace(total * 1024, free * 1024);
  }
}
