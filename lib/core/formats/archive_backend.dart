/// Format-neutral model behind the archive viewer and the comic reader.
///
/// Every container the app opens (ZIP family, TAR family, RAR 4/5, 7z, ISO
/// 9660/UDF) is exposed as an [ArcBackend]: a flat list of [ArcEntry]s plus
/// a way to stream one entry's decoded bytes. Backends are pure Dart (no
/// Flutter) so they run inside the worker isolate (see archive_session.dart)
/// and in command-line tests.
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;

/// What went wrong, in terms the UI can act on.
enum ArcErrorKind {
  /// Encrypted and no password was given.
  needPassword,

  /// The password was rejected (or decryption produced garbage).
  wrongPassword,

  /// Compression method / feature the readers don't implement.
  unsupported,

  /// Damaged headers or data.
  corrupt,

  /// Data decoded but failed its CRC / MAC.
  checksum,

  /// A part of a multi-volume set is missing.
  missingVolume,

  /// A size guard tripped (zip bomb, memory cap, entry count).
  tooLarge,

  /// Not an archive we recognise.
  notArchive,

  /// File-system error (permissions, disk full…).
  io,

  /// The user cancelled.
  cancelled,
}

/// A readable archive error. [message] is shown to the user as is.
class ArcException implements Exception {
  ArcException(this.kind, this.message, {this.entryPath, this.detail});

  final ArcErrorKind kind;
  final String message;
  final String? entryPath;

  /// Technical detail for logs.
  final String? detail;

  /// Whether handing the file to another app might help.
  bool get suggestOtherApp =>
      kind == ArcErrorKind.unsupported ||
      kind == ArcErrorKind.corrupt ||
      kind == ArcErrorKind.notArchive ||
      kind == ArcErrorKind.checksum;

  @override
  String toString() =>
      'ArcException(${kind.name}): $message'
      '${entryPath == null ? '' : ' [$entryPath]'}'
      '${detail == null ? '' : ' ($detail)'}';
}

/// One file, folder or link inside an archive. Plain data, so it crosses
/// isolate boundaries cheaply.
class ArcEntry {
  const ArcEntry({
    required this.index,
    required this.path,
    required this.isDirectory,
    required this.size,
    this.packedSize,
    this.modified,
    this.isEncrypted = false,
    this.isSymlink = false,
    this.linkTarget,
    this.unsafePath = false,
    this.method,
    this.crc32,
    this.unsupportedReason,
    this.sizeIsExact = true,
  });

  /// Position in [ArcBackend.entries]; stable for a given archive file.
  final int index;

  /// Normalised path: `/` separators, no leading `/`, no `.`/`..` segments.
  final String path;
  final bool isDirectory;

  /// Uncompressed size in bytes.
  final int size;

  /// Stored size, when the format records it per entry.
  final int? packedSize;
  final DateTime? modified;
  final bool isEncrypted;
  final bool isSymlink;
  final String? linkTarget;

  /// The stored name tried to escape the archive root (`../`, absolute path,
  /// drive letter) and was sanitised.
  final bool unsafePath;

  /// Short compression method label ("Deflate", "LZMA2", "Stored"…).
  final String? method;
  final int? crc32;

  /// Set when the entry can be listed but not read (e.g. a GNU sparse file).
  final String? unsupportedReason;

  /// False when [size] is only an estimate (a bare .gz records its size
  /// modulo 4 GiB, and only for its last member).
  final bool sizeIsExact;

  String get name {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  bool get isFile => !isDirectory && !isSymlink;

  @override
  String toString() =>
      'ArcEntry#$index($path${isDirectory ? '/' : ''}, $size B)';
}

/// An opened archive.
abstract class ArcBackend {
  /// Human readable format, e.g. "RAR 5 (solid)", "ISO 9660 + Joliet".
  String get formatLabel;

  List<ArcEntry> get entries;

  /// True when reading an entry may require decoding everything before it
  /// (solid RAR, compressed TAR). Callers should read in ascending
  /// [ArcEntry.index] order; random access still works but costs more.
  bool get isSequential => false;

  /// Called while a sequential backend decodes data stored before the
  /// entry being read (solid RAR, compressed TAR), with the share done.
  void Function(double fraction)? onSeek;

  /// Streams the decoded bytes of [entry]. Errors are [ArcException]s,
  /// thrown synchronously or delivered through the stream. Cancelling the
  /// subscription stops decoding.
  Stream<Uint8List> openRead(ArcEntry entry);

  Future<void> close();
}

/// Size and count guards applied while opening and reading.
class ArcLimits {
  const ArcLimits({
    this.maxEntries = 2000000,
    this.maxInMemoryEntry = 1024 * 1024 * 1024,
  });

  /// Archives declaring more entries are rejected (directory bombs).
  final int maxEntries;

  /// Largest entry a reader that must decode in memory (RAR compressed
  /// entries, 7z folders) may materialise.
  final int maxInMemoryEntry;

  /// Phones get a lower in-memory cap: the worker shares the app's heap and
  /// a failed giant allocation can take the whole app down.
  factory ArcLimits.forPlatform() {
    final mobile = Platform.isAndroid || Platform.isIOS;
    return ArcLimits(
      maxInMemoryEntry: mobile ? 512 * 1024 * 1024 : 1024 * 1024 * 1024,
    );
  }
}

// ---------------------------------------------------------------------------
// Byte sources
// ---------------------------------------------------------------------------

/// Several byte sources read back to back as one (split `.001`, `.002`…
/// volumes).
final class ConcatByteSource implements koni.ByteSource {
  ConcatByteSource(this.parts, {this.name})
    : _starts = _offsets(parts),
      length = parts.fold<int>(0, (sum, p) => sum + p.length);

  final List<koni.ByteSource> parts;
  final List<int> _starts;

  @override
  final String? name;

  @override
  final int length;

  static List<int> _offsets(List<koni.ByteSource> parts) {
    final out = <int>[];
    var pos = 0;
    for (final p in parts) {
      out.add(pos);
      pos += p.length;
    }
    return out;
  }

  int _partAt(int offset) {
    var lo = 0, hi = parts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    koni.checkByteSourceRange(this, offset, length);
    if (length == 0) return Uint8List(0);
    var part = _partAt(offset);
    final first = parts[part];
    final inFirst = offset - _starts[part];
    if (inFirst + length <= first.length) {
      return first.read(inFirst, length);
    }
    final out = Uint8List(length);
    var filled = 0;
    var pos = offset;
    while (filled < length) {
      final p = parts[part];
      final within = pos - _starts[part];
      final take = (p.length - within) < (length - filled)
          ? p.length - within
          : length - filled;
      if (take > 0) {
        out.setRange(filled, filled + take, await p.read(within, take));
        filled += take;
        pos += take;
      }
      part++;
    }
    return out;
  }

  @override
  Future<void> close() async {
    for (final p in parts) {
      await p.close();
    }
  }
}

/// Reads `[offset, offset + length)` of [source] as a chunk stream.
Stream<Uint8List> readRange(
  koni.ByteSource source,
  int offset,
  int length, {
  int chunkSize = 1 << 20,
}) async* {
  var pos = offset;
  final end = offset + length;
  while (pos < end) {
    final take = end - pos < chunkSize ? end - pos : chunkSize;
    yield await source.read(pos, take);
    pos += take;
  }
}

/// Maps koni's typed exceptions (RAR/7z readers) to [ArcException].
ArcException mapKoniError(Object error, {String? entryPath}) {
  if (error is ArcException) return error;
  final path = entryPath ?? (error is koni.ArchiveException ? error.entryPath : null);
  if (error is koni.InvalidPasswordException) {
    return ArcException(
      ArcErrorKind.wrongPassword,
      'Wrong password.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.EncryptedArchiveException) {
    final unsupported = error.message.contains('unsupported');
    return ArcException(
      unsupported ? ArcErrorKind.unsupported : ArcErrorKind.needPassword,
      unsupported
          ? 'This archive uses an encryption method Folders can\'t read.'
          : 'This archive is password protected.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.ChecksumMismatchException) {
    return ArcException(
      ArcErrorKind.checksum,
      'The data failed its checksum (CRC) test: the archive is damaged'
      '${path == null ? '' : ' at "$path"'}.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.UnsupportedCompressionException) {
    final method = error.methodName;
    return ArcException(
      ArcErrorKind.unsupported,
      method == null
          ? 'This archive uses a compression method Folders can\'t decode.'
          : 'This archive uses ${_methodLabel(method)} compression, which '
              'Folders can\'t decode.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.UnsupportedFeatureException) {
    return ArcException(
      ArcErrorKind.unsupported,
      'This archive uses a feature Folders can\'t read '
      '(${error.message}).',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.SizeLimitExceededException) {
    return ArcException(
      ArcErrorKind.tooLarge,
      'An entry is larger than Folders can unpack safely.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.UnexpectedEofException) {
    return ArcException(
      ArcErrorKind.corrupt,
      'The archive is truncated (incomplete download or a missing part?).',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.CorruptArchiveException) {
    return ArcException(
      ArcErrorKind.corrupt,
      'The archive is damaged and can\'t be read.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is koni.UnsupportedFormatException) {
    return ArcException(
      ArcErrorKind.notArchive,
      'This isn\'t an archive format Folders recognises.',
      detail: error.message,
    );
  }
  if (error is koni.ArchiveException) {
    return ArcException(
      ArcErrorKind.corrupt,
      'The archive can\'t be read.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is FormatException) {
    return ArcException(
      ArcErrorKind.corrupt,
      'The archive is damaged and can\'t be read.',
      entryPath: path,
      detail: error.message,
    );
  }
  if (error is OutOfMemoryError) {
    return ArcException(
      ArcErrorKind.tooLarge,
      'Not enough memory to unpack this entry.',
      entryPath: path,
    );
  }
  return ArcException(
    ArcErrorKind.io,
    'Couldn\'t read the archive.',
    entryPath: path,
    detail: '$error',
  );
}

String _methodLabel(String method) => switch (method) {
  'bzip2' => 'BZip2',
  'ppmd' => 'PPMd',
  'bcj2' => 'BCJ2',
  'zstd' => 'Zstandard',
  'deflate64' => 'Deflate64',
  _ => method,
};

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

/// Normalises a stored entry name. Returns the clean path and whether the
/// raw name tried to leave the archive root.
({String path, bool escaped}) normalizeArcPath(String raw) {
  final n = koni.normalizeEntryPath(raw);
  final absolute = raw.startsWith('/') ||
      raw.startsWith(r'\') ||
      (raw.length >= 2 && raw.codeUnitAt(1) == 0x3A);
  return (path: n.path, escaped: n.escapedRoot || absolute);
}

/// "Natural" order: digit runs compare by value, so `page2` sorts before
/// `page10`; otherwise case-insensitive.
int naturalCompare(String a, String b) {
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i), cb = b.codeUnitAt(j);
    final da = _isDigit(ca), db = _isDigit(cb);
    if (da && db) {
      var ie = i, je = j;
      while (ie < a.length && _isDigit(a.codeUnitAt(ie))) {
        ie++;
      }
      while (je < b.length && _isDigit(b.codeUnitAt(je))) {
        je++;
      }
      // Compare numerically without overflow: strip leading zeros, then by
      // length, then lexically.
      var is_ = i, js = j;
      while (is_ < ie - 1 && a.codeUnitAt(is_) == 0x30) {
        is_++;
      }
      while (js < je - 1 && b.codeUnitAt(js) == 0x30) {
        js++;
      }
      final la = ie - is_, lb = je - js;
      if (la != lb) return la - lb;
      for (var k = 0; k < la; k++) {
        final d = a.codeUnitAt(is_ + k) - b.codeUnitAt(js + k);
        if (d != 0) return d;
      }
      // Equal value: fewer leading zeros first.
      final z = (ie - i) - (je - j);
      if (z != 0) return z;
      i = ie;
      j = je;
      continue;
    }
    final la = _lower(ca), lb = _lower(cb);
    if (la != lb) return la - lb;
    i++;
    j++;
  }
  final rest = (a.length - i) - (b.length - j);
  if (rest != 0) return rest;
  return a.compareTo(b);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
int _lower(int c) => (c >= 0x41 && c <= 0x5A) ? c + 32 : c;

/// Converts a DOS date/time pair (local time) to a [DateTime].
DateTime? dosDateTime(int date, int time) {
  if (date == 0) return null;
  final year = 1980 + ((date >> 9) & 0x7F);
  final month = (date >> 5) & 0x0F;
  final day = date & 0x1F;
  final hour = (time >> 11) & 0x1F;
  final minute = (time >> 5) & 0x3F;
  final second = (time & 0x1F) * 2;
  if (month < 1 || month > 12 || day < 1 || hour > 23) return null;
  // Local-time DateTime construction is slow (time-zone lookup, ~20 µs on
  // Windows); archives hold few distinct hours, so cache per date and hour.
  final key = (date << 5) | hour;
  final base = _dosHourCache[key] ??= DateTime(year, month, day, hour);
  if (_dosHourCache.length > 4096) _dosHourCache.clear();
  return base.add(Duration(minutes: minute, seconds: second));
}

final Map<int, DateTime> _dosHourCache = {};
