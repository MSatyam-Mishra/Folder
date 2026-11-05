import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/exif_bytes.dart';

/// One file inside a [DesignContainer].
class DesignEntry {
  const DesignEntry({
    required this.name,
    required this.size,
    this.compressedSize = 0,
    this.method = 0,
    this.headerOffset = 0,
    this.encrypted = false,
  });

  /// Path with '/' separators.
  final String name;

  /// Uncompressed size.
  final int size;
  final int compressedSize;
  final int method;
  final int headerOffset;
  final bool encrypted;

  bool get isDirectory => name.endsWith('/');
}

/// Read access to the files of a ZIP-based document (Sketch, Krita,
/// OpenRaster, Figma, XD, iWork, CorelDRAW X4+...) or of a macOS package
/// directory with the same layout. Only the central directory and the
/// entries asked for are read.
abstract class DesignContainer {
  List<DesignEntry> get entries;

  /// Contents of [entry], or null if it is larger than [maxSize], encrypted,
  /// compressed with an unsupported method, or unreadable.
  Uint8List? read(DesignEntry entry, {int maxSize = 64 << 20});

  /// The first [count] uncompressed bytes of [entry].
  Uint8List? readPrefix(DesignEntry entry, int count);

  void close() {}

  /// Entry named [name] (case-insensitive, ignoring a leading "./" or "/").
  DesignEntry? find(String name) {
    final want = _normalise(name);
    for (final e in entries) {
      if (_normalise(e.name) == want) return e;
    }
    return null;
  }

  /// The first of [names] that exists.
  DesignEntry? findAny(Iterable<String> names) {
    for (final n in names) {
      final e = find(n);
      if (e != null) return e;
    }
    return null;
  }

  Uint8List? readNamed(String name, {int maxSize = 64 << 20}) {
    final e = find(name);
    return e == null ? null : read(e, maxSize: maxSize);
  }

  String? readText(String name, {int maxSize = 16 << 20}) {
    final bytes = readNamed(name, maxSize: maxSize);
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _normalise(String name) {
    var n = name.replaceAll('\\', '/');
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    while (n.startsWith('/')) {
      n = n.substring(1);
    }
    return n.toLowerCase();
  }

  /// Opens [path] as a ZIP archive or, when it is a directory, as a package
  /// directory. Returns null when it is neither.
  static DesignContainer? open(String path) {
    if (FileSystemEntity.isDirectorySync(path)) {
      return DirectoryContainer(Directory(path));
    }
    final src = FileRandomBytes.open(path);
    final zip = ZipContainer.parse(src);
    if (zip == null) src.close();
    return zip;
  }
}

/// A ZIP archive read through [RandomBytes].
class ZipContainer extends DesignContainer {
  ZipContainer._(this.src, this.entries, this._shift);

  final RandomBytes src;
  @override
  final List<DesignEntry> entries;

  /// Bytes prepended to the archive (self-extracting stubs and the like).
  final int _shift;

  static const _maxEntries = 100000;

  /// True when the central directory was missing and the entries were
  /// recovered from the local headers (a truncated or damaged file).
  bool recovered = false;

  /// Parses the central directory of [src]; null if it isn't a ZIP. A ZIP
  /// whose end is missing (an interrupted download or copy) is read from
  /// its local headers instead.
  static ZipContainer? parse(RandomBytes src) {
    return _parseCentral(src) ?? _scanLocal(src);
  }

  static ZipContainer? _scanLocal(RandomBytes src) {
    if (!src.matches(0, const [0x50, 0x4B, 0x03, 0x04])) return null;
    final entries = <DesignEntry>[];
    var pos = 0;
    while (entries.length < _maxEntries &&
        src.matches(pos, const [0x50, 0x4B, 0x03, 0x04])) {
      final h = src.read(pos, 30);
      if (h.length < 30) break;
      final d = ByteData.sublistView(h);
      final flags = d.getUint16(6, Endian.little);
      final method = d.getUint16(8, Endian.little);
      final csize = d.getUint32(18, Endian.little);
      final usize = d.getUint32(22, Endian.little);
      final nameLen = d.getUint16(26, Endian.little);
      final extraLen = d.getUint16(28, Endian.little);
      // Sizes written after the data (bit 3) can't be walked without
      // inflating; stop there.
      if (flags & 8 != 0 && csize == 0) break;
      final name = utf8.decode(src.read(pos + 30, nameLen), allowMalformed: true);
      final dataEnd = pos + 30 + nameLen + extraLen + csize;
      if (dataEnd > src.length) break;
      entries.add(DesignEntry(
        name: name,
        size: usize,
        compressedSize: csize,
        method: method,
        headerOffset: pos,
        encrypted: flags & 1 != 0,
      ));
      pos = dataEnd;
    }
    if (entries.isEmpty) return null;
    return ZipContainer._(src, entries, 0)..recovered = true;
  }

  static ZipContainer? _parseCentral(RandomBytes src) {
    final len = src.length;
    if (len < 22) return null;
    final tailSize = math.min(len, 22 + 0xFFFF);
    final tail = src.read(len - tailSize, tailSize);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return null;
    final eocdAbs = len - tailSize + eocd;
    final t = ByteData.sublistView(tail);
    var count = t.getUint16(eocd + 10, Endian.little);
    var cdSize = t.getUint32(eocd + 12, Endian.little);
    var cdOffset = t.getUint32(eocd + 16, Endian.little);
    var cdEnd = eocdAbs;

    // ZIP64 end of central directory.
    if (count == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      final loc = eocdAbs - 20;
      if (loc >= 0 && src.matches(loc, const [0x50, 0x4B, 0x06, 0x07])) {
        final rec = _u64(src, loc + 8);
        if (src.matches(rec, const [0x50, 0x4B, 0x06, 0x06])) {
          count = _u64(src, rec + 32);
          cdSize = _u64(src, rec + 40);
          cdOffset = _u64(src, rec + 48);
          cdEnd = rec;
        }
      }
    }
    if (count > _maxEntries || cdSize > 256 << 20) return null;
    // Archives with data prepended: offsets are relative to the original
    // start.
    final shift = cdEnd - cdSize - cdOffset;
    final cdStart = cdOffset + (shift > 0 ? shift : 0);
    if (!src.matches(cdStart, const [0x50, 0x4B, 0x01, 0x02]) && count > 0) {
      return null;
    }
    final cd = src.read(cdStart, cdSize);
    final d = ByteData.sublistView(cd);
    final entries = <DesignEntry>[];
    var p = 0;
    for (var i = 0; i < count && p + 46 <= cd.length; i++) {
      if (d.getUint32(p, Endian.little) != 0x02014B50) break;
      final flags = d.getUint16(p + 8, Endian.little);
      final method = d.getUint16(p + 10, Endian.little);
      var csize = d.getUint32(p + 20, Endian.little);
      var usize = d.getUint32(p + 24, Endian.little);
      final nameLen = d.getUint16(p + 28, Endian.little);
      final extraLen = d.getUint16(p + 30, Endian.little);
      final commentLen = d.getUint16(p + 32, Endian.little);
      var offset = d.getUint32(p + 42, Endian.little);
      if (p + 46 + nameLen > cd.length) break;
      final rawName = cd.sublist(p + 46, p + 46 + nameLen);
      final name = flags & 0x800 != 0
          ? utf8.decode(rawName, allowMalformed: true)
          : _isAscii(rawName)
              ? ascii.decode(rawName)
              : utf8.decode(rawName, allowMalformed: true);
      // ZIP64 extra field.
      var e = p + 46 + nameLen;
      final extraEnd = math.min(cd.length, e + extraLen);
      while (e + 4 <= extraEnd) {
        final id = d.getUint16(e, Endian.little);
        final size = d.getUint16(e + 2, Endian.little);
        if (id == 0x0001) {
          var q = e + 4;
          if (usize == 0xFFFFFFFF && q + 8 <= extraEnd) {
            usize = d.getUint64(q, Endian.little);
            q += 8;
          }
          if (csize == 0xFFFFFFFF && q + 8 <= extraEnd) {
            csize = d.getUint64(q, Endian.little);
            q += 8;
          }
          if (offset == 0xFFFFFFFF && q + 8 <= extraEnd) {
            offset = d.getUint64(q, Endian.little);
          }
        }
        e += 4 + size;
      }
      entries.add(DesignEntry(
        name: name,
        size: usize,
        compressedSize: csize,
        method: method,
        headerOffset: offset + (shift > 0 ? shift : 0),
        encrypted: flags & 1 != 0,
      ));
      p += 46 + nameLen + extraLen + commentLen;
    }
    return ZipContainer._(src, entries, shift);
  }

  int? _dataOffset(DesignEntry entry) {
    final h = entry.headerOffset;
    if (!src.matches(h, const [0x50, 0x4B, 0x03, 0x04])) return null;
    final nameLen = src.u16(h + 26, littleEndian: true);
    final extraLen = src.u16(h + 28, littleEndian: true);
    return h + 30 + nameLen + extraLen;
  }

  @override
  Uint8List? read(DesignEntry entry, {int maxSize = 64 << 20}) {
    if (entry.encrypted || entry.size > maxSize) return null;
    if (entry.compressedSize > maxSize * 2 + 1024) return null;
    final at = _dataOffset(entry);
    if (at == null) return null;
    final data = src.read(at, entry.compressedSize);
    if (data.length < entry.compressedSize) return null;
    try {
      switch (entry.method) {
        case 0:
          return Uint8List.fromList(data);
        case 8:
          final out = ZLibDecoder(raw: true).convert(data);
          if (out.length > maxSize) return null;
          return out is Uint8List ? out : Uint8List.fromList(out);
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  @override
  Uint8List? readPrefix(DesignEntry entry, int count) {
    if (entry.encrypted) return null;
    final at = _dataOffset(entry);
    if (at == null) return null;
    if (entry.method == 0) {
      return Uint8List.fromList(src.read(at, math.min(count, entry.size)));
    }
    if (entry.method != 8) return null;
    final out = BytesBuilder(copy: false);
    final inflater = ZLibDecoder(raw: true).startChunkedConversion(
      _CollectSink(out),
    );
    var pos = 0;
    try {
      while (out.length < count && pos < entry.compressedSize) {
        final n = math.min(64 * 1024, entry.compressedSize - pos);
        inflater.add(src.read(at + pos, n));
        pos += n;
      }
      if (pos >= entry.compressedSize) inflater.close();
    } catch (_) {
      // A truncated stream still yields what was inflated.
    }
    final bytes = out.takeBytes();
    return bytes.length > count ? Uint8List.sublistView(bytes, 0, count) : bytes;
  }

  @override
  void close() => src.close();

  int get prefixLength => _shift;

  static int _u64(RandomBytes src, int at) {
    final lo = src.u32(at, littleEndian: true);
    final hi = src.u32(at + 4, littleEndian: true);
    return hi * 0x100000000 + lo;
  }

  static bool _isAscii(List<int> b) => b.every((c) => c < 0x80);
}

class _CollectSink implements Sink<List<int>> {
  _CollectSink(this.out);

  final BytesBuilder out;

  @override
  void add(List<int> data) => out.add(data);

  @override
  void close() {}
}

/// A package directory (e.g. a .pages or .sketch bundle saved unzipped).
class DirectoryContainer extends DesignContainer {
  DirectoryContainer(this.dir) {
    try {
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        final rel = f.path
            .substring(dir.path.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp('^/+'), '');
        _files[rel] = f;
        entries.add(DesignEntry(name: rel, size: f.lengthSync()));
        if (entries.length > 20000) break;
      }
    } catch (_) {}
  }

  final Directory dir;
  final Map<String, File> _files = {};
  @override
  final List<DesignEntry> entries = [];

  @override
  Uint8List? read(DesignEntry entry, {int maxSize = 64 << 20}) {
    if (entry.size > maxSize) return null;
    try {
      return _files[entry.name]?.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  @override
  Uint8List? readPrefix(DesignEntry entry, int count) {
    final f = _files[entry.name];
    if (f == null) return null;
    RandomAccessFile? raf;
    try {
      raf = f.openSync();
      return raf.readSync(count);
    } catch (_) {
      return null;
    } finally {
      raf?.closeSync();
    }
  }
}
