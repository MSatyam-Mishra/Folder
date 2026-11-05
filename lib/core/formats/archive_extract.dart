/// Extraction engine: writes archive entries to disk safely.
///
/// * Paths are re-sanitised for the local file system and must stay inside
///   the destination (no `..`, absolute paths or drive letters; links are
///   never created).
/// * Each file is written to a temporary name and renamed when complete, so
///   cancelling or a damaged entry never leaves a half-written file.
/// * Decompression bombs: an entry may not unpack past its declared size,
///   the declared total is checked against free space, and entries without
///   a declared size (bare .gz/.xz/.bz2) are capped by compression ratio.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'archive_backend.dart';
import 'archive_index.dart';

enum ConflictPolicy { ask, skip, overwrite, rename }

class ExtractRequest {
  const ExtractRequest({
    required this.archivePath,
    required this.destination,
    this.password,
    this.paths,
    this.stripPrefix = '',
    this.policy = ConflictPolicy.ask,
    this.flat = false,
    this.targets,
    this.freeBytes,
    this.reportEachFile = false,
  });

  final String archivePath;
  final String destination;
  final String? password;

  /// Files/folders (archive paths) to extract; null extracts everything.
  final List<String>? paths;

  /// Archive folder removed from the front of each path (the folder the
  /// user is browsing), so selected items land directly in [destination].
  final String stripPrefix;
  final ConflictPolicy policy;

  /// Write every file directly into [destination] under its own name.
  final bool flat;

  /// Explicit output path per entry index (overrides naming).
  final Map<int, String>? targets;

  /// Free space at the destination, when the caller could measure it.
  final int? freeBytes;

  /// Emit an [ExtractFileDone] per written file.
  final bool reportEachFile;
}

sealed class ExtractEvent {
  const ExtractEvent();
}

class ExtractProgress extends ExtractEvent {
  const ExtractProgress({
    required this.doneBytes,
    required this.totalBytes,
    required this.doneFiles,
    required this.totalFiles,
    required this.current,
    this.tempPath,
    this.seeking,
  });

  final int doneBytes;
  final int totalBytes;
  final int doneFiles;
  final int totalFiles;
  final String current;

  /// File being written right now (deleted by the caller after a hard
  /// cancel).
  final String? tempPath;

  /// While a solid/streamed archive decodes the data stored before the
  /// current file: the share of that work done.
  final double? seeking;

  double? get fraction => totalBytes > 0
      ? (doneBytes / totalBytes).clamp(0.0, 1.0)
      : (totalFiles > 0 ? doneFiles / totalFiles : null);
}

class ExtractConflicts extends ExtractEvent {
  const ExtractConflicts(this.count, this.examples);
  final int count;
  final List<String> examples;
}

class ExtractFileDone extends ExtractEvent {
  const ExtractFileDone(this.index, this.path);
  final int index;
  final String path;
}

class ExtractDone extends ExtractEvent {
  const ExtractDone(this.result);
  final ExtractResult result;
}

class ExtractFailed extends ExtractEvent {
  const ExtractFailed(this.error);
  final ArcException error;
}

class ExtractResult {
  ExtractResult();

  int files = 0;
  int folders = 0;
  int bytes = 0;
  int skippedExisting = 0;
  int skippedUnsafe = 0;
  int skippedLinks = 0;
  final List<(String, String)> failures = [];

  /// Top-level items created in the destination.
  final Set<String> created = {};

  /// Path of the first file written.
  String? firstFile;

  /// Index → path of each file written.
  final Map<int, String> written = {};

  bool get changedDestination => files > 0 || folders > 0;
}

class _Item {
  _Item(this.entry, this.target);
  final ArcEntry entry;
  String target;
}

const _windowsReserved = {
  'con', 'prn', 'aux', 'nul', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6',
  'com7', 'com8', 'com9', 'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6',
  'lpt7', 'lpt8', 'lpt9',
};

/// Makes one path segment safe on Windows, Android (FAT/exFAT SD cards)
/// and Unix. Returns null for segments that must be dropped.
String? sanitizeSegment(String segment) {
  if (segment.isEmpty || segment == '.' || segment == '..') return null;
  final sb = StringBuffer();
  for (final r in segment.runes) {
    if (r < 0x20 || r == 0x7F) {
      sb.write('_');
    } else if ('<>:"|?*\\/'.contains(String.fromCharCode(r))) {
      sb.write('_');
    } else {
      sb.writeCharCode(r);
    }
  }
  var s = sb.toString();
  // Windows drops trailing dots and spaces.
  while (s.endsWith('.') || s.endsWith(' ')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return '_';
  final stem = s.split('.').first.toLowerCase();
  if (_windowsReserved.contains(stem)) s = '_$s';
  // Keep names within common file-system limits (255 UTF-16 units).
  if (s.length > 200) {
    final ext = p.extension(s);
    s = s.substring(0, 200 - (ext.length > 20 ? 0 : ext.length)) +
        (ext.length > 20 ? '' : ext);
  }
  return s;
}

/// Destination path for [archivePath] under [root], or null when it can't
/// be placed safely.
String? safeTarget(String root, String archivePath) {
  final segs = <String>[];
  for (final raw in archivePath.split('/')) {
    final s = sanitizeSegment(raw);
    if (s != null) segs.add(s);
  }
  if (segs.isEmpty) return null;
  final target = p.normalize(p.joinAll([root, ...segs]));
  if (!p.isWithin(p.normalize(root), target)) return null;
  return target;
}

/// "name (1).ext", "name (2).ext"… for the first free variant of [path].
String uniquePath(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return path;
  }
  final dir = p.dirname(path);
  final ext = p.extension(path);
  final stem = p.basenameWithoutExtension(path);
  for (var n = 1; n < 100000; n++) {
    final cand = p.join(dir, '$stem ($n)$ext');
    if (FileSystemEntity.typeSync(cand, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return cand;
    }
  }
  return p.join(dir, '$stem (${DateTime.now().millisecondsSinceEpoch})$ext');
}

/// Runs an extraction against an opened [backend].
Future<ExtractResult> runExtraction(
  ArcBackend backend,
  ExtractRequest req, {
  required void Function(ExtractEvent event) emit,
  required Future<ConflictPolicy?> Function(int count, List<String> examples)
      askConflicts,
  required bool Function() isCancelled,
  int? archiveSize,
}) async {
  final result = ExtractResult();
  final root = p.normalize(p.absolute(req.destination));

  // ---- Plan ----
  final index = ArcIndex.build(backend.entries);
  final selected = req.paths == null
      ? List.of(backend.entries)
      : index.select(req.paths!);
  if (req.targets != null) {
    selected.retainWhere((e) => req.targets!.containsKey(e.index));
  }
  selected.sort((a, b) => a.index - b.index);
  final strip = req.stripPrefix.isEmpty ? '' : '${req.stripPrefix}/';
  final items = <_Item>[];
  final dirs = <_Item>[];
  var total = 0;
  final seenTargets = <String>{};
  for (final e in selected) {
    if (e.isSymlink) {
      result.skippedLinks++;
      continue;
    }
    var rel = e.path;
    if (strip.isNotEmpty && rel.startsWith(strip)) rel = rel.substring(strip.length);
    if (req.flat) rel = e.name;
    final String? target = req.targets?[e.index] ?? safeTarget(root, rel);
    if (target == null) {
      result.skippedUnsafe++;
      continue;
    }
    if (e.isDirectory) {
      if (!req.flat) dirs.add(_Item(e, target));
      continue;
    }
    // A later duplicate of the same path replaces the earlier one.
    if (!seenTargets.add(target)) {
      items.removeWhere((i) => i.target == target);
    }
    final reason = e.unsupportedReason;
    if (reason != null) {
      result.failures.add((e.path, reason));
      continue;
    }
    items.add(_Item(e, target));
    if (e.size > 0) total += e.size;
  }
  final free = req.freeBytes;
  if (free != null && total > free) {
    throw ArcException(
      ArcErrorKind.tooLarge,
      'Not enough free space: the selection unpacks to ${_fmt(total)} but '
      'only ${_fmt(free)} is available.',
    );
  }

  // ---- Conflicts ----
  var policy = req.policy;
  if (policy == ConflictPolicy.ask) {
    final clashes = <String>[];
    var count = 0;
    for (final i in items) {
      if (FileSystemEntity.typeSync(i.target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        count++;
        if (clashes.length < 5) clashes.add(p.relative(i.target, from: root));
      }
      if (isCancelled()) throw _cancelled();
    }
    if (count > 0) {
      final answer = await askConflicts(count, clashes);
      if (answer == null || isCancelled()) throw _cancelled();
      policy = answer;
    } else {
      policy = ConflictPolicy.overwrite; // nothing to clash with
    }
  }

  // ---- Write ----
  try {
    await Directory(root).create(recursive: true);
  } on FileSystemException catch (e) {
    throw _ioError(e, root);
  }
  void noteCreated(String target) {
    final rel = p.relative(target, from: root);
    final top = p.split(rel).first;
    result.created.add(p.join(root, top));
  }

  for (final d in dirs) {
    if (isCancelled()) throw _cancelled();
    final type = FileSystemEntity.typeSync(d.target);
    if (type == FileSystemEntityType.directory) continue;
    final target = type == FileSystemEntityType.notFound
        ? d.target
        : uniquePath(d.target);
    try {
      await Directory(target).create(recursive: true);
      result.folders++;
      noteCreated(target);
    } on FileSystemException catch (e) {
      throw _ioError(e, target);
    }
  }

  final madeDirs = <String>{root};
  // Setting a timestamp costs a few milliseconds per file on Windows; skip
  // it there for big extractions.
  final keepTimes = !Platform.isWindows || items.length <= 2000;
  var doneBytes = 0;
  var doneFiles = 0;
  var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  void progress(
    String current,
    String? temp, {
    bool force = false,
    double? seeking,
  }) {
    final now = DateTime.now();
    if (!force && now.difference(lastEmit).inMilliseconds < 80) return;
    lastEmit = now;
    emit(ExtractProgress(
      doneBytes: doneBytes,
      totalBytes: total,
      doneFiles: doneFiles,
      totalFiles: items.length,
      current: current,
      tempPath: temp,
      seeking: seeking,
    ));
  }

  for (final item in items) {
    if (isCancelled()) throw _cancelled();
    final e = item.entry;
    var target = item.target;
    final type = FileSystemEntity.typeSync(target, followLinks: false);
    var replaces = false;
    if (type != FileSystemEntityType.notFound) {
      if (policy == ConflictPolicy.skip && req.targets == null) {
        result.skippedExisting++;
        doneFiles++;
        if (e.size > 0) doneBytes += e.size;
        continue;
      }
      if (policy == ConflictPolicy.rename ||
          type == FileSystemEntityType.directory) {
        target = uniquePath(target);
      } else {
        replaces = true;
      }
    }
    final temp = '$target.explorer-part';
    // Big entries always announce their temp file, so a hard cancel can
    // remove it; small ones only update the (throttled) progress.
    progress(e.path, temp, force: e.size < 0 || e.size > (1 << 20));
    final parentDir = p.dirname(target);
    if (madeDirs.add(parentDir)) {
      try {
        await Directory(parentDir).create(recursive: true);
      } on FileSystemException catch (err) {
        throw _ioError(err, target);
      }
    }
    RandomAccessFile? out;
    var written = 0;
    // Bare compressed streams don't declare their size: cap by ratio.
    final exact = e.sizeIsExact && e.size >= 0;
    final cap = exact ? e.size : _ratioCap(archiveSize ?? 0);
    backend.onSeek = (f) => progress(e.path, temp, seeking: f);
    try {
      out = await File(temp).open(mode: FileMode.write);
      if (e.size != 0 || !exact) {
        await for (final chunk in backend.openRead(e)) {
          if (isCancelled()) throw _cancelled();
          written += chunk.length;
          if (written > cap) {
            throw ArcException(
              ArcErrorKind.tooLarge,
              exact
                  ? '"${e.name}" unpacks to more data than the archive '
                      'declares (possible zip bomb). Extraction stopped.'
                  : '"${e.name}" expands far beyond any normal compression '
                      'ratio (possible decompression bomb). Extraction '
                      'stopped.',
              entryPath: e.path,
            );
          }
          await out.writeFrom(chunk);
          doneBytes += chunk.length;
          progress(e.path, temp);
        }
      }
      await out.close();
      out = null;
      if (exact && written != e.size) {
        throw ArcException(
          ArcErrorKind.corrupt,
          '"${e.name}" is incomplete in the archive.',
          entryPath: e.path,
        );
      }
      if (replaces &&
          FileSystemEntity.typeSync(target, followLinks: false) ==
              FileSystemEntityType.file) {
        await File(target).delete();
      }
      await File(temp).rename(target);
      final m = e.modified;
      if (m != null && keepTimes) {
        try {
          await File(target).setLastModified(m.toLocal());
        } catch (_) {}
      }
      backend.onSeek = null;
      result.files++;
      result.bytes += written;
      result.firstFile ??= target;
      result.written[e.index] = target;
      noteCreated(target);
      doneFiles++;
      if (req.reportEachFile) emit(ExtractFileDone(e.index, target));
    } catch (err) {
      backend.onSeek = null;
      try {
        await out?.close();
      } catch (_) {}
      try {
        final f = File(temp);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      final ArcException ae = err is ArcException
          ? err
          : err is FileSystemException
          ? _ioError(err, target)
          : mapKoniError(err, entryPath: e.path);
      switch (ae.kind) {
        case ArcErrorKind.corrupt:
        case ArcErrorKind.checksum:
        case ArcErrorKind.unsupported:
          // Damaged or unreadable entry: report it and carry on.
          result.failures.add((e.path, ae.message));
          doneFiles++;
          if (e.size > 0) doneBytes += e.size - written;
        default:
          throw ae;
      }
    }
  }
  progress('', null, force: true);
  return result;
}

int _ratioCap(int packed) {
  const floor = 2 * 1024 * 1024 * 1024;
  final byRatio = packed * 2000;
  return byRatio > floor ? byRatio : floor;
}

ArcException _cancelled() =>
    ArcException(ArcErrorKind.cancelled, 'Extraction cancelled.');

ArcException _ioError(FileSystemException e, String path) {
  final os = e.osError;
  final code = os?.errorCode;
  // ENOSPC (28) / ERROR_DISK_FULL (112) / ERROR_HANDLE_DISK_FULL (39).
  final full = code == 28 || code == 112 || code == 39;
  final denied = code == 13 || code == 5 || code == 1 || code == 30;
  return ArcException(
    ArcErrorKind.io,
    full
        ? 'The storage is full.'
        : denied
        ? 'Folder isn\'t allowed to write to "${p.dirname(path)}". Choose '
            'another folder.'
        : 'Couldn\'t write "${p.basename(path)}"'
            '${os?.message == null || os!.message.isEmpty ? '' : ': ${os.message}'}.',
    detail: '$e',
  );
}

String _fmt(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
}

/// Reads a whole entry into memory, refusing entries larger than [maxBytes].
Future<Uint8List> readEntryBytes(
  ArcBackend backend,
  ArcEntry entry, {
  int maxBytes = 512 * 1024 * 1024,
}) async {
  final exact = entry.sizeIsExact && entry.size >= 0;
  if (exact && entry.size > maxBytes) {
    throw ArcException(
      ArcErrorKind.tooLarge,
      '"${entry.name}" is too large to open in place.',
      entryPath: entry.path,
    );
  }
  final out = exact && entry.size > 0 ? Uint8List(entry.size) : null;
  final bb = out == null ? BytesBuilder(copy: false) : null;
  var pos = 0;
  await for (final chunk in backend.openRead(entry)) {
    if (pos + chunk.length > maxBytes ||
        (out != null && pos + chunk.length > out.length)) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        '"${entry.name}" unpacks to more data than the archive declares.',
        entryPath: entry.path,
      );
    }
    if (out != null) {
      out.setRange(pos, pos + chunk.length, chunk);
    } else {
      bb!.add(chunk);
    }
    pos += chunk.length;
  }
  if (out != null) {
    if (pos != out.length) {
      throw ArcException(
        ArcErrorKind.corrupt,
        '"${entry.name}" is incomplete in the archive.',
        entryPath: entry.path,
      );
    }
    return out;
  }
  return bb!.takeBytes();
}
