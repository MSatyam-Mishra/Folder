import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:folders/core/services/compress/archive_sink.dart';
import 'package:folders/core/services/compress/pbkdf2_sha1.dart';
import 'package:koni_codecs/crypto.dart';

/// Thrown out of a writer when the user cancels; the job removes what was
/// written.
class CompressCancelled implements Exception {
  const CompressCancelled();
}

/// What a writer is told while it reads a file: how many more bytes it
/// read; and whether to stop.
typedef ReadProgress = void Function(int bytes);
typedef ShouldStop = bool Function();

/// Opens [file] to read, before anything about it is written: one that
/// can't be read is left out, and nothing of it is in the archive.
RandomAccessFile openInput(String file) => File(file).openSync();

/// Reads [input] a chunk at a time into [onChunk] (the same buffer each
/// time, so the receiver copies what it keeps), then closes it.
void readChunks(RandomAccessFile input, void Function(Uint8List chunk, int length) onChunk, {ShouldStop? stop}) {
  try {
    final buffer = Uint8List(1 << 20);
    while (true) {
      if (stop != null && stop()) throw const CompressCancelled();
      final read = input.readIntoSync(buffer);
      if (read == 0) break;
      onChunk(buffer, read);
    }
  } finally {
    input.closeSync();
  }
}

/// Files that are compressed already: a codec only spends time on them for
/// nothing, so archives store them as they are.
bool isCompressedAlready(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return _compressedExtensions.contains(name.substring(dot + 1).toLowerCase());
}

const _compressedExtensions = {
  // Pictures
  'jpg', 'jpeg', 'jfif', 'png', 'gif', 'webp', 'heic', 'heif', 'avif', 'jxl',
  // Video and sound
  'mp4', 'm4v', 'mkv', 'webm', 'avi', 'mov', '3gp', 'wmv', 'flv', 'mpg', 'mpeg', 'ts', 'm2ts',
  'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wma', 'weba',
  // Archives and packages
  'zip', '7z', 'rar', 'gz', 'tgz', 'bz2', 'xz', 'txz', 'zst', 'lz4', 'cab', 'jar', 'apk', 'xapk',
  'apks', 'aab', 'ipa', 'msix', 'appx', 'deb', 'rpm', 'dmg', 'cbz', 'cbr', 'cb7',
  // Documents that are ZIPs inside
  'docx', 'xlsx', 'pptx', 'odt', 'ods', 'odp', 'epub',
};

/// Writes a ZIP a file at a time, straight to [sink]: Deflate through the
/// system's zlib, CRC-32 as it goes, and each local header filled in once
/// its file is written, so nothing waits in memory. Zip64 when a size or an
/// offset needs it; names in UTF-8; folders as entries; modified times to
/// the second (the extended timestamp) as well as DOS's two.
///
/// With a password, each file is encrypted with WinZip's AES-256 (AE-2): a
/// salt of its own, PBKDF2-HMAC-SHA1 over 1000 rounds, AES in counter mode
/// and an HMAC-SHA1 code, which 7-Zip, WinRAR, WinZip and macOS's Archive
/// Utility read. (Windows' own ZIP folders don't.)
class ZipWriter {
  ZipWriter(this.sink, {this.level = 6, this.password}) {
    if (level < 0 || level > 9) throw ArgumentError.value(level, 'level');
  }

  final ArchiveSink sink;

  /// 0 stores; 1–9 are zlib's levels.
  final int level;
  final String? password;

  final _central = <_CentralEntry>[];
  static final _random = math.Random.secure();

  /// Big enough that its compressed form may pass 4 GB: a Zip64 local header.
  static const _mayNeedZip64 = 0xFFFFFFFF - (64 << 20);

  void addFolder(String name, DateTime modified) {
    final entryName = name.endsWith('/') ? name : '$name/';
    final offset = sink.position;
    _writeLocal(entryName, modified, method: 0, flags: _flagsFor(entryName, encrypted: false), zip64: false);
    _central.add(_CentralEntry(entryName, modified, method: 0, flags: _flagsFor(entryName, encrypted: false),
        crc: 0, compressed: 0, size: 0, offset: offset, folder: true));
  }

  /// Adds [file] as [name]; [size] is its size when it was listed.
  void addFile(String name, String file, int size, DateTime modified, {ReadProgress? onRead, ShouldStop? stop}) {
    final input = openInput(file);
    final deflate = level > 0 && size > 0 && !isCompressedAlready(name);
    final method = deflate ? 8 : 0;
    final encrypted = password != null;
    final flags = _flagsFor(name, encrypted: encrypted);
    final zip64 = size >= _mayNeedZip64;
    final offset = sink.position;
    final headerAt = _writeLocal(name, modified,
        method: encrypted ? 99 : method, flags: flags, zip64: zip64, aesMethod: encrypted ? method : null);
    final dataStart = sink.position;

    _Aes? aes;
    if (encrypted) {
      aes = _Aes(password!);
      sink
        ..add(aes.salt)
        ..add(aes.verifier);
    }
    var crc = 0;
    var read = 0;
    void emit(List<int> bytes) {
      if (bytes.isEmpty) return;
      if (aes != null) {
        final copy = Uint8List.fromList(bytes);
        aes.encrypt(copy);
        sink.add(copy);
      } else {
        sink.add(bytes);
      }
    }

    final filter = deflate ? RawZLibFilter.deflateFilter(level: level, raw: true) : null;
    readChunks(input, (chunk, length) {
      read += length;
      if (!encrypted) crc = getCrc32(Uint8List.sublistView(chunk, 0, length), crc);
      if (filter == null) {
        emit(Uint8List.sublistView(chunk, 0, length));
      } else {
        filter.process(chunk, 0, length);
        for (List<int>? out; (out = filter.processed(flush: false)) != null;) {
          emit(out!);
        }
      }
      onRead?.call(length);
    }, stop: stop);
    if (filter != null) {
      filter.process(const [], 0, 0);
      for (List<int>? out; (out = filter.processed(end: true)) != null;) {
        emit(out!);
      }
    }
    if (aes != null) sink.add(aes.finish());
    final compressed = sink.position - dataStart;

    // The sizes and checksum, now they're known. AE-2 leaves the CRC out:
    // the HMAC checks the data.
    final storedCrc = encrypted ? 0 : crc;
    final fields = ByteData(12)
      ..setUint32(0, storedCrc, Endian.little)
      ..setUint32(4, zip64 ? 0xFFFFFFFF : compressed, Endian.little)
      ..setUint32(8, zip64 ? 0xFFFFFFFF : read, Endian.little);
    sink.patch(headerAt + 14, fields.buffer.asUint8List());
    if (zip64) {
      final sizes = ByteData(16)
        ..setUint64(0, read, Endian.little)
        ..setUint64(8, compressed, Endian.little);
      // The Zip64 extra comes first after the name.
      sink.patch(headerAt + 30 + _nameBytes(name).length + 4, sizes.buffer.asUint8List());
    } else if (compressed > 0xFFFFFFFF || read > 0xFFFFFFFF) {
      throw const FileSystemException('A file grew past 4 GB while it was being compressed');
    }
    _central.add(_CentralEntry(name, modified,
        method: encrypted ? 99 : method,
        aesMethod: encrypted ? method : null,
        flags: flags,
        crc: storedCrc,
        compressed: compressed,
        size: read,
        offset: offset,
        folder: false));
  }

  static Uint8List _nameBytes(String name) => Uint8List.fromList(utf8.encode(name));

  static int _flagsFor(String name, {required bool encrypted}) {
    var flags = 0;
    if (encrypted) flags |= 1;
    // UTF-8 names, when there's anything beyond ASCII.
    if (name.codeUnits.any((c) => c > 0x7E)) flags |= 0x800;
    return flags;
  }

  /// Writes a local header; returns where it starts.
  int _writeLocal(String name, DateTime modified,
      {required int method, required int flags, required bool zip64, int? aesMethod}) {
    final at = sink.position;
    final nameBytes = _nameBytes(name);
    final extra = BytesBuilder();
    if (zip64) extra.add(_zip64Extra(size: 0, compressed: 0));
    extra.add(_timeExtra(modified));
    if (aesMethod != null) extra.add(_aesExtra(aesMethod));
    final extraBytes = extra.toBytes();
    final (time, date) = _dosTime(modified);
    final header = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, _versionNeeded(zip64: zip64, aes: aesMethod != null), Endian.little)
      ..setUint16(6, flags, Endian.little)
      ..setUint16(8, method, Endian.little)
      ..setUint16(10, time, Endian.little)
      ..setUint16(12, date, Endian.little)
      ..setUint32(14, 0, Endian.little)
      ..setUint32(18, zip64 ? 0xFFFFFFFF : 0, Endian.little)
      ..setUint32(22, zip64 ? 0xFFFFFFFF : 0, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, extraBytes.length, Endian.little);
    sink
      ..add(header.buffer.asUint8List())
      ..add(nameBytes)
      ..add(extraBytes);
    return at;
  }

  static int _versionNeeded({required bool zip64, required bool aes}) => aes ? 51 : (zip64 ? 45 : 20);

  static Uint8List _zip64Extra({int? size, int? compressed, int? offset}) {
    final fields = [?size, ?compressed, ?offset];
    final data = ByteData(4 + fields.length * 8)
      ..setUint16(0, 0x0001, Endian.little)
      ..setUint16(2, fields.length * 8, Endian.little);
    for (var i = 0; i < fields.length; i++) {
      data.setUint64(4 + i * 8, fields[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// The extended timestamp: the modified time to the second, in UTC.
  static Uint8List _timeExtra(DateTime modified) {
    final seconds = (modified.millisecondsSinceEpoch ~/ 1000).clamp(0, 0xFFFFFFFF);
    return (ByteData(9)
          ..setUint16(0, 0x5455, Endian.little)
          ..setUint16(2, 5, Endian.little)
          ..setUint8(4, 1)
          ..setUint32(5, seconds, Endian.little))
        .buffer
        .asUint8List();
  }

  /// WinZip's AES extra: AE-2, AES-256, and the method under it.
  static Uint8List _aesExtra(int method) => (ByteData(11)
        ..setUint16(0, 0x9901, Endian.little)
        ..setUint16(2, 7, Endian.little)
        ..setUint16(4, 2, Endian.little)
        ..setUint8(6, 0x41)
        ..setUint8(7, 0x45)
        ..setUint8(8, 3)
        ..setUint16(9, method, Endian.little))
      .buffer
      .asUint8List();

  /// DOS's local time, two seconds at a time, from 1980.
  static (int, int) _dosTime(DateTime when) {
    final t = when.toLocal();
    if (t.year < 1980) return (0, (1 << 5) | 1);
    final year = math.min(t.year, 2107);
    return (
      (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2),
      ((year - 1980) << 9) | (t.month << 5) | t.day,
    );
  }

  /// The central directory and its end records.
  void close() {
    final start = sink.position;
    for (final entry in _central) {
      final nameBytes = _nameBytes(entry.name);
      final bigSize = entry.size >= 0xFFFFFFFF || entry.compressed >= 0xFFFFFFFF;
      final bigOffset = entry.offset >= 0xFFFFFFFF;
      final extra = BytesBuilder();
      if (bigSize || bigOffset) {
        extra.add(_zip64Extra(
          size: bigSize ? entry.size : null,
          compressed: bigSize ? entry.compressed : null,
          offset: bigOffset ? entry.offset : null,
        ));
      }
      extra.add(_timeExtra(entry.modified));
      if (entry.aesMethod != null) extra.add(_aesExtra(entry.aesMethod!));
      final extraBytes = extra.toBytes();
      final (time, date) = _dosTime(entry.modified);
      final zip64 = bigSize || bigOffset;
      final header = ByteData(46)
        ..setUint32(0, 0x02014b50, Endian.little)
        // Made by: MS-DOS attributes, ZIP 6.3.
        ..setUint16(4, 63, Endian.little)
        ..setUint16(6, _versionNeeded(zip64: zip64, aes: entry.aesMethod != null), Endian.little)
        ..setUint16(8, entry.flags, Endian.little)
        ..setUint16(10, entry.method, Endian.little)
        ..setUint16(12, time, Endian.little)
        ..setUint16(14, date, Endian.little)
        ..setUint32(16, entry.crc, Endian.little)
        ..setUint32(20, bigSize ? 0xFFFFFFFF : entry.compressed, Endian.little)
        ..setUint32(24, bigSize ? 0xFFFFFFFF : entry.size, Endian.little)
        ..setUint16(28, nameBytes.length, Endian.little)
        ..setUint16(30, extraBytes.length, Endian.little)
        ..setUint16(32, 0, Endian.little)
        ..setUint16(34, 0, Endian.little)
        ..setUint16(36, 0, Endian.little)
        ..setUint32(38, entry.folder ? 0x10 : 0x20, Endian.little)
        ..setUint32(42, bigOffset ? 0xFFFFFFFF : entry.offset, Endian.little);
      sink
        ..add(header.buffer.asUint8List())
        ..add(nameBytes)
        ..add(extraBytes);
    }
    final size = sink.position - start;
    final count = _central.length;
    final zip64 = count >= 0xFFFF || start >= 0xFFFFFFFF || size >= 0xFFFFFFFF;
    if (zip64) {
      final recordAt = sink.position;
      sink.add((ByteData(56)
            ..setUint32(0, 0x06064b50, Endian.little)
            ..setUint64(4, 44, Endian.little)
            ..setUint16(12, 45, Endian.little)
            ..setUint16(14, 45, Endian.little)
            ..setUint32(16, 0, Endian.little)
            ..setUint32(20, 0, Endian.little)
            ..setUint64(24, count, Endian.little)
            ..setUint64(32, count, Endian.little)
            ..setUint64(40, size, Endian.little)
            ..setUint64(48, start, Endian.little))
          .buffer
          .asUint8List());
      sink.add((ByteData(20)
            ..setUint32(0, 0x07064b50, Endian.little)
            ..setUint32(4, 0, Endian.little)
            ..setUint64(8, recordAt, Endian.little)
            ..setUint32(16, 1, Endian.little))
          .buffer
          .asUint8List());
    }
    sink.add((ByteData(22)
          ..setUint32(0, 0x06054b50, Endian.little)
          ..setUint16(4, 0, Endian.little)
          ..setUint16(6, 0, Endian.little)
          ..setUint16(8, zip64 ? 0xFFFF : count, Endian.little)
          ..setUint16(10, zip64 ? 0xFFFF : count, Endian.little)
          ..setUint32(12, zip64 ? 0xFFFFFFFF : size, Endian.little)
          ..setUint32(16, zip64 ? 0xFFFFFFFF : start, Endian.little)
          ..setUint16(20, 0, Endian.little))
        .buffer
        .asUint8List());
  }
}

class _CentralEntry {
  _CentralEntry(this.name, this.modified,
      {required this.method,
      this.aesMethod,
      required this.flags,
      required this.crc,
      required this.compressed,
      required this.size,
      required this.offset,
      required this.folder});

  final String name;
  final DateTime modified;
  final int method;
  final int? aesMethod;
  final int flags;
  final int crc;
  final int compressed;
  final int size;
  final int offset;
  final bool folder;
}

/// One file's WinZip AES-256: its salt and the keys made from it, the
/// counter-mode keystream and the HMAC over what it encrypts.
class _Aes {
  _Aes(String password) {
    for (var i = 0; i < salt.length; i++) {
      salt[i] = ZipWriter._random.nextInt(256);
    }
    final keys = pbkdf2HmacSha1(utf8.encode(password), salt, 1000, 66);
    _ctr = AesCtrLeStream(Aes(Uint8List.sublistView(keys, 0, 32)));
    _mac = Hmac.sha1(Uint8List.sublistView(keys, 32, 64));
    verifier = Uint8List.sublistView(keys, 64, 66);
  }

  final salt = Uint8List(16);
  late final Uint8List verifier;
  late final AesCtrLeStream _ctr;
  late final Hmac _mac;

  void encrypt(Uint8List data) {
    _ctr.processInPlace(data);
    _mac.add(data);
  }

  /// The authentication code: the HMAC's first ten bytes.
  Uint8List finish() => Uint8List.sublistView(_mac.finish(), 0, 10);
}
