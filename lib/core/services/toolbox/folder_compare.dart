import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/toolbox/folder_listing.dart';
import 'package:path/path.dart' as p;

/// How a name differs between the two folders. Names that are the same on
/// both sides aren't items; [FolderComparison.identical] counts them.
enum SyncDiff {
  onlyLeft('Only on the left'),
  onlyRight('Only on the right'),
  newerLeft('Newer on the left'),
  newerRight('Newer on the right'),
  differentSize('Same date, different size'),
  differentContents('Same date and size, different contents'),
  typeClash('A file on one side, a folder on the other');

  const SyncDiff(this.label);

  final String label;
}

/// A file or folder on one side. A folder's [size] and [files] are all it
/// holds, however deep.
class SyncStat {
  const SyncStat({required this.isFolder, required this.size, required this.modified, this.files = 1});

  final bool isFolder;
  final int size;

  /// Milliseconds since the epoch.
  final int modified;
  final int files;

  DateTime get modifiedTime => DateTime.fromMillisecondsSinceEpoch(modified);
}

/// One name that differs: its path from either folder, and what each side has.
class SyncItem {
  const SyncItem(this.path, this.diff, {this.left, this.right});

  /// From the compared folders, with this system's separator.
  final String path;
  final SyncDiff diff;
  final SyncStat? left;
  final SyncStat? right;

  String get name => p.basename(path);

  /// The larger of the two sides, for sorting and totals.
  int get size {
    final l = left?.size ?? 0;
    final r = right?.size ?? 0;
    return l > r ? l : r;
  }
}

/// What a comparison is told to do.
class CompareOptions {
  const CompareOptions({this.contents = false, this.ignoreHourShift = false});

  /// Reads files whose size matches, as the same size and date can still
  /// hide a change.
  final bool contents;

  /// Takes times exactly an hour apart as the same: FAT and exFAT drives
  /// store local time, so daylight saving moves them.
  final bool ignoreHourShift;
}

/// What comparing two folders found.
class FolderComparison {
  FolderComparison({
    required this.left,
    required this.right,
    required this.options,
    required this.items,
    required this.identical,
    required this.identicalBytes,
    required this.leftFiles,
    required this.rightFiles,
    required this.skippedLinks,
    required this.unreadable,
    required this.at,
  });

  final String left;
  final String right;
  final CompareOptions options;
  final List<SyncItem> items;

  /// Files the same on both sides, and their size.
  final int identical;
  final int identicalBytes;
  final int leftFiles;
  final int rightFiles;

  /// Links and junctions, left alone on both sides.
  final int skippedLinks;

  /// Folders that couldn't be read, from either side.
  final List<String> unreadable;
  final DateTime at;

  List<SyncItem> of(SyncDiff diff) => [for (final item in items) if (item.diff == diff) item];

  bool get matches => items.isEmpty;
}

enum ComparePhase { listing, contents }

/// How far a comparison has come, a few times a second.
class CompareProgress {
  const CompareProgress({
    required this.phase,
    required this.place,
    required this.files,
    this.bytesDone = 0,
    this.bytesTotal = 0,
  });

  final ComparePhase phase;

  /// The folder being listed, or the file being read, from the compared ones.
  final String place;

  /// Files looked at so far, on both sides.
  final int files;

  /// While reading contents: how much has been read of how much.
  final int bytesDone;
  final int bytesTotal;
}

typedef CompareReport = void Function(CompareProgress progress);

/// Compares two folders in the background: it tells how far it has come and
/// stops at once when asked.
class FolderCompare {
  FolderCompare(this.left, this.right, {this.options = const CompareOptions(), this.onProgress});

  final String left;
  final String right;
  final CompareOptions options;
  final CompareReport? onProgress;

  Isolate? _isolate;
  ReceivePort? _port;
  bool _stopped = false;
  final _done = Completer<FolderComparison?>();

  /// What the comparison found; null if it was stopped. Throws if it failed.
  Future<FolderComparison?> start() async {
    final port = _port = ReceivePort();
    Object? failure;
    port.listen((message) {
      if (message is CompareProgress) {
        if (!_stopped) onProgress?.call(message);
      } else if (message is FolderComparison) {
        if (!_done.isCompleted) _done.complete(message);
      } else if (message is List) {
        failure = message.firstOrNull;
      } else if (message == null) {
        if (!_done.isCompleted) _done.completeError(StateError("The comparison didn't finish: ${failure ?? 'it ended'}"));
        port.close();
      }
    });
    final send = port.sendPort;
    try {
      _isolate = await Isolate.spawn(_run, (send, left, right, options), onExit: send, onError: send);
    } on Object catch (error) {
      port.close();
      if (!_done.isCompleted) _done.completeError(error);
    }
    if (_stopped) _isolate?.kill(priority: Isolate.immediate);
    return _done.future;
  }

  static void _run((SendPort, String, String, CompareOptions) job) {
    final (send, left, right, options) = job;
    Isolate.exit(send, FolderComparer.compare(left, right, options: options, report: send.send));
  }

  /// Stops at once; [start] gives null.
  void stop() {
    _stopped = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    if (!_done.isCompleted) _done.complete(null);
  }
}

/// Compares two folder trees by relative path, size and modified time, and
/// if asked by contents. Links and junctions are never followed, on either
/// side, and a name that's a link on either side is left out.
abstract final class FolderComparer {
  /// How far apart two times may be and still count as the same: FAT and
  /// exFAT keep times to 2 seconds, and some systems drop the milliseconds.
  static const tolerance = Duration(seconds: 2);

  /// Whether names that differ only in case are the same file here: they
  /// are on Windows, macOS and Android's shared storage.
  static bool get caseInsensitive => !Platform.isLinux;

  /// Partly copied files a sync leaves while it works; never compared.
  static bool isSyncTemporary(String name) => name.startsWith('.') && name.endsWith(_temporarySuffix);

  static const _temporarySuffix = '.folders-sync.tmp';

  /// A name for a file being copied to [target], beside it, that nothing
  /// else uses.
  static String temporaryFor(String target) {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return p.join(p.dirname(target), '.${p.basename(target)}.$stamp$_temporarySuffix');
  }

  /// 1 if [a] is later than [b], -1 if earlier, 0 if the same within
  /// [tolerance] (or exactly an hour apart, with [ignoreHourShift]).
  static int compareTimes(int a, int b, {bool ignoreHourShift = false}) {
    final gap = (a - b).abs();
    final slack = tolerance.inMilliseconds;
    if (gap <= slack) return 0;
    if (ignoreHourShift && (gap - const Duration(hours: 1).inMilliseconds).abs() <= slack) return 0;
    return a > b ? 1 : -1;
  }

  /// Why [left] and [right] can't be compared, or null if they can.
  static String? problem(String? left, String? right) {
    if (left == null || right == null || left.isEmpty || right.isEmpty) return 'Choose both folders';
    for (final path in [left, right]) {
      if (RemotePaths.isRemote(path) || path.startsWith('content://') || !ExplorerPaths.isOnDisk(path)) {
        return 'Only folders on this device can be synced';
      }
    }
    String key(String path) {
      final normal = p.normalize(p.absolute(path));
      return caseInsensitive ? normal.toLowerCase() : normal;
    }

    final l = key(left);
    final r = key(right);
    if (l == r) return 'These are the same folder';
    if (p.isWithin(l, r) || p.isWithin(r, l)) return 'One folder is inside the other';
    for (final path in [left, right]) {
      // The chosen folders themselves may be links; what's in them isn't followed.
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.directory) {
        return '"${p.basename(path)}" is not there any more';
      }
    }
    return null;
  }

  /// Compares [left] and [right]; [report] hears how far it has come.
  static FolderComparison compare(
    String left,
    String right, {
    CompareOptions options = const CompareOptions(),
    CompareReport? report,
  }) =>
      _Comparer(left, right, options, report).run();

  /// Whether two files hold the same bytes; [onRead] hears each chunk read
  /// (from both together). It stops at the first difference.
  static bool sameContents(String a, String b, {void Function(int bytes)? onRead}) {
    final first = File(a).openSync();
    try {
      final second = File(b).openSync();
      try {
        final length = first.lengthSync();
        if (length != second.lengthSync()) return false;
        if (length == 0) return true;
        // Made once per isolate: a fresh megabyte for every small file
        // made reading thousands of them dozens of times slower.
        final one = _one ??= Uint8List(_chunk);
        final two = _two ??= Uint8List(_chunk);
        while (true) {
          final read = first.readIntoSync(one);
          var read2 = 0;
          while (read2 < read) {
            final got = second.readIntoSync(two, read2, read);
            if (got == 0) return false;
            read2 += got;
          }
          if (read == 0) return second.readIntoSync(two, 0, 1) == 0;
          if (!_equal(one, two, read)) return false;
          onRead?.call(read);
        }
      } finally {
        second.closeSync();
      }
    } finally {
      first.closeSync();
    }
  }

  static const _chunk = 1 << 20;
  static Uint8List? _one;
  static Uint8List? _two;

  static bool _equal(Uint8List a, Uint8List b, int length) {
    final words = length ~/ 8;
    final x = a.buffer.asInt64List(a.offsetInBytes, words);
    final y = b.buffer.asInt64List(b.offsetInBytes, words);
    for (var i = 0; i < words; i++) {
      if (x[i] != y[i]) return false;
    }
    for (var i = words * 8; i < length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A pair of files of the same size, to be read when comparing contents.
class _SameSize {
  const _SameSize(this.path, this.left, this.right);

  final String path;
  final SyncStat left;
  final SyncStat right;
}

class _Comparer {
  _Comparer(this.leftRoot, this.rightRoot, this.options, this.report);

  final String leftRoot;
  final String rightRoot;
  final CompareOptions options;
  final CompareReport? report;

  final items = <SyncItem>[];
  final sameSize = <_SameSize>[];
  final unreadable = <String>[];
  var identical = 0;
  var identicalBytes = 0;
  var leftFiles = 0;
  var rightFiles = 0;
  var links = 0;

  static const _every = 100;
  final _clock = Stopwatch()..start();
  var _told = -_every;
  var _phase = ComparePhase.listing;
  var _place = '';
  var _bytesDone = 0;
  var _bytesTotal = 0;

  void _tell({bool now = false}) {
    final report = this.report;
    if (report == null) return;
    final at = _clock.elapsedMilliseconds;
    if (at - _told < _every && !now) return;
    _told = at;
    report(CompareProgress(
      phase: _phase,
      place: _place,
      files: leftFiles + rightFiles,
      bytesDone: _bytesDone,
      bytesTotal: _bytesTotal,
    ));
  }

  String _key(String name) => FolderComparer.caseInsensitive ? name.toLowerCase() : name;

  /// What's right in [folder], by name (sync's own temporary files left
  /// out); null if it can't be read.
  Map<String, FolderEntry>? _list(String folder) {
    final entries = FolderListing.list(folder);
    if (entries == null) {
      unreadable.add(folder);
      return null;
    }
    return {
      for (final entry in entries)
        if (!FolderComparer.isSyncTemporary(entry.name)) _key(entry.name): entry,
    };
  }

  /// A folder on one side only, as one item: all it holds.
  SyncStat _folderStat(String folder, int modified, {required bool left}) {
    var size = 0;
    var files = 0;
    void walk(String path) {
      final entries = FolderListing.list(path);
      if (entries == null) {
        unreadable.add(path);
        return;
      }
      for (final entry in entries) {
        switch (entry.kind) {
          case EntryKind.file:
            size += entry.size;
            files++;
            if (left) {
              leftFiles++;
            } else {
              rightFiles++;
            }
            _tell();
          case EntryKind.folder:
            walk(p.join(path, entry.name));
          case EntryKind.link:
            links++;
        }
      }
    }

    walk(folder);
    return SyncStat(isFolder: true, size: size, modified: modified, files: files);
  }

  SyncStat? _stat(String folder, FolderEntry? entry, {required bool left}) => switch (entry?.kind) {
        null || EntryKind.link => null,
        EntryKind.folder => _folderStat(p.join(folder, entry!.name), entry.modified, left: left),
        EntryKind.file => SyncStat(isFolder: false, size: entry!.size, modified: entry.modified),
      };

  void _compareFolder(String relative) {
    final leftDir = relative.isEmpty ? leftRoot : p.join(leftRoot, relative);
    final rightDir = relative.isEmpty ? rightRoot : p.join(rightRoot, relative);
    _place = relative;
    _tell();
    final lefts = _list(leftDir);
    final rights = _list(rightDir);
    if (lefts == null || rights == null) return;
    final keys = {...lefts.keys, ...rights.keys}.toList()..sort();
    for (final key in keys) {
      final l = lefts[key];
      final r = rights[key];
      // A link on either side: neither followed nor replaced.
      final lLink = l?.kind == EntryKind.link;
      final rLink = r?.kind == EntryKind.link;
      if (lLink || rLink) {
        if (lLink) links++;
        if (rLink) links++;
        continue;
      }
      final name = (l ?? r)!.name;
      final path = relative.isEmpty ? name : p.join(relative, name);
      if (l?.kind == EntryKind.folder && r?.kind == EntryKind.folder) {
        _compareFolder(path);
        _place = relative;
        continue;
      }
      final leftStat = _stat(leftDir, l, left: true);
      final rightStat = _stat(rightDir, r, left: false);
      if (l?.kind == EntryKind.file) leftFiles++;
      if (r?.kind == EntryKind.file) rightFiles++;
      _tell();
      if (leftStat == null && rightStat == null) continue;
      if (rightStat == null) {
        items.add(SyncItem(path, SyncDiff.onlyLeft, left: leftStat));
      } else if (leftStat == null) {
        items.add(SyncItem(path, SyncDiff.onlyRight, right: rightStat));
      } else if (leftStat.isFolder != rightStat.isFolder) {
        items.add(SyncItem(path, SyncDiff.typeClash, left: leftStat, right: rightStat));
      } else if (leftStat.size == rightStat.size && options.contents) {
        sameSize.add(_SameSize(path, leftStat, rightStat));
      } else {
        _decide(path, leftStat, rightStat, sameBytes: leftStat.size == rightStat.size);
      }
    }
  }

  /// Two files: the same, or which is newer. With [sameBytes] (the same
  /// size, or the same contents) and the same time they're the same.
  void _decide(String path, SyncStat left, SyncStat right, {required bool sameBytes, bool readContents = false}) {
    final time = FolderComparer.compareTimes(left.modified, right.modified, ignoreHourShift: options.ignoreHourShift);
    if (time == 0 && sameBytes) {
      identical++;
      identicalBytes += left.size;
      return;
    }
    final diff = switch (time) {
      > 0 => SyncDiff.newerLeft,
      < 0 => SyncDiff.newerRight,
      _ => readContents ? SyncDiff.differentContents : SyncDiff.differentSize,
    };
    items.add(SyncItem(path, diff, left: left, right: right));
  }

  void _readContents() {
    _phase = ComparePhase.contents;
    _bytesTotal = sameSize.fold(0, (sum, pair) => sum + pair.left.size);
    _tell(now: true);
    for (final pair in sameSize) {
      _place = pair.path;
      _tell();
      final start = _bytesDone;
      bool same;
      try {
        same = FolderComparer.sameContents(
          p.join(leftRoot, pair.path),
          p.join(rightRoot, pair.path),
          onRead: (bytes) {
            _bytesDone += bytes;
            _tell();
          },
        );
      } on FileSystemException {
        // Can't be read: taken as different, so a sync looks at it again.
        same = false;
      }
      _bytesDone = start + pair.left.size;
      if (same) {
        identical++;
        identicalBytes += pair.left.size;
      } else {
        _decide(pair.path, pair.left, pair.right, sameBytes: false, readContents: true);
      }
    }
  }

  FolderComparison run() {
    final at = DateTime.now();
    _compareFolder('');
    if (sameSize.isNotEmpty) _readContents();
    _tell(now: true);
    final order = SyncDiff.values;
    items.sort((a, b) {
      final kind = order.indexOf(a.diff).compareTo(order.indexOf(b.diff));
      return kind != 0 ? kind : a.path.compareTo(b.path);
    });
    return FolderComparison(
      left: leftRoot,
      right: rightRoot,
      options: options,
      items: items,
      identical: identical,
      identicalBytes: identicalBytes,
      leftFiles: leftFiles,
      rightFiles: rightFiles,
      skippedLinks: links,
      unreadable: unreadable,
      at: at,
    );
  }
}

/// For tests: what a comparison found, by path.
@visibleForTesting
Map<String, SyncDiff> diffsByPath(FolderComparison comparison) => {
      for (final item in comparison.items) item.path.replaceAll(r'\', '/'): item.diff,
    };
