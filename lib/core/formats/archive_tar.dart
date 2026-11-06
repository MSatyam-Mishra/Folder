/// TAR family reader: plain TAR (random access, listing by seeking over
/// headers), TAR inside gzip/bzip2/xz (one streaming pass to list, forward
/// reads after that), and bare `.gz`/`.bz2`/`.xz` files (one entry).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;

import 'archive_backend.dart';
import 'archive_codecs.dart';

/// Outer compression of a TAR (or bare compressed file).
enum TarCompression { none, gzip, bzip2, xz }

class _TarItem {
  _TarItem(this.dataOffset, this.size);
  final int dataOffset; // in the decompressed TAR stream
  final int size;
}

/// Checks a 512-byte TAR header block.
bool looksLikeTarHeader(Uint8List h) {
  if (h.length < 512) return false;
  var allZero = true;
  for (var i = 0; i < 512; i++) {
    if (h[i] != 0) {
      allZero = false;
      break;
    }
  }
  if (allZero) return false;
  final stored = _parseNumber(h, 148, 8);
  if (stored == null) return false;
  var unsigned = 0, signed = 0;
  for (var i = 0; i < 512; i++) {
    final b = (i >= 148 && i < 156) ? 0x20 : h[i];
    unsigned += b;
    signed += b >= 128 ? b - 256 : b;
  }
  return stored == unsigned || stored == signed;
}

int? _parseNumber(Uint8List h, int off, int len) {
  if (h[off] & 0x80 != 0) {
    // GNU base-256 (big-endian, first byte's top bit is the marker).
    var v = h[off] & 0x3F;
    if (h[off] & 0x40 != 0) return null; // negative
    for (var i = 1; i < len; i++) {
      v = (v << 8) | h[off + i];
    }
    return v;
  }
  var v = 0;
  var any = false;
  for (var i = 0; i < len; i++) {
    final c = h[off + i];
    if (c == 0 || c == 0x20) {
      if (any) break;
      continue;
    }
    if (c < 0x30 || c > 0x37) return null;
    v = v * 8 + (c - 0x30);
    any = true;
  }
  return any ? v : 0;
}

String _cString(Uint8List h, int off, int len) {
  var end = off;
  while (end < off + len && h[end] != 0) {
    end++;
  }
  return utf8.decode(Uint8List.sublistView(h, off, end), allowMalformed: true);
}

/// Forward reader over a byte stream that counts its position.
class _Forward {
  _Forward(Stream<Uint8List> input) : _it = StreamIterator(input);

  final StreamIterator<Uint8List> _it;
  Uint8List _buf = Uint8List(0);
  int _p = 0;
  int pos = 0;
  bool busy = false;

  Future<bool> _more() async {
    while (_p >= _buf.length) {
      if (!await _it.moveNext()) return false;
      _buf = _it.current;
      _p = 0;
    }
    return true;
  }

  /// Reads up to [n] bytes (fewer only at end of stream).
  Future<Uint8List> read(int n) async {
    if (_p < _buf.length && _buf.length - _p >= n) {
      final out = Uint8List.sublistView(_buf, _p, _p + n);
      _p += n;
      pos += n;
      return out;
    }
    final out = BytesBuilder(copy: true);
    var need = n;
    while (need > 0 && await _more()) {
      final take = _buf.length - _p < need ? _buf.length - _p : need;
      out.add(Uint8List.sublistView(_buf, _p, _p + take));
      _p += take;
      need -= take;
      pos += take;
    }
    return out.takeBytes();
  }

  /// Hands out up to [max] bytes as they arrive (no copying).
  Future<Uint8List?> next(int max) async {
    if (!await _more()) return null;
    final take = _buf.length - _p < max ? _buf.length - _p : max;
    final out = Uint8List.sublistView(_buf, _p, _p + take);
    _p += take;
    pos += take;
    return out;
  }

  Future<void> skip(int n) async {
    var need = n;
    while (need > 0 && await _more()) {
      final take = _buf.length - _p < need ? _buf.length - _p : need;
      _p += take;
      need -= take;
      pos += take;
    }
    if (need > 0) throw const FormatException('unexpected end of TAR data');
  }

  Future<void> cancel() => _it.cancel();
}

class TarBackend extends ArcBackend {
  TarBackend._(
    this._source,
    this.compression,
    this.entries,
    this._items,
    this.formatLabel, {
    this.bare = false,
  });

  final koni.ByteSource _source;
  final TarCompression compression;
  final List<_TarItem> _items;
  final bool bare;

  @override
  final List<ArcEntry> entries;

  @override
  final String formatLabel;

  _Forward? _cursor;

  @override
  bool get isSequential => compression != TarCompression.none;

  /// Decompressed view of the whole source.
  Stream<Uint8List> _stream({void Function(int read)? onRaw}) {
    final raw = readRange(
      _source,
      0,
      _source.length,
      chunkSize: 256 * 1024,
    ).map((c) {
      onRaw?.call(c.length);
      return c;
    });
    return decompressStream(compression, raw);
  }

  static Stream<Uint8List> decompressStream(
    TarCompression c,
    Stream<Uint8List> raw,
  ) => switch (c) {
    TarCompression.none => raw,
    TarCompression.gzip => gunzipStream(raw),
    TarCompression.bzip2 => bzip2Stream(raw),
    TarCompression.xz => xzStream(raw),
  };

  /// Opens a TAR or compressed stream. [name] is the file name, used for a
  /// bare compressed file's single entry. [onProgress] reports the share of
  /// the compressed input read while listing a compressed TAR, and
  /// [onEntries] receives entries as they are found.
  static Future<TarBackend> open(
    koni.ByteSource source,
    TarCompression compression, {
    required String name,
    ArcLimits limits = const ArcLimits(),
    void Function(double progress)? onProgress,
    void Function(List<ArcEntry> batch)? onEntries,
  }) async {
    if (compression == TarCompression.none) {
      return _openPlain(source, limits, onEntries);
    }
    // Peek the first decompressed block: TAR inside, or a bare file?
    final probe = _Forward(
      decompressStream(
        compression,
        readRange(source, 0, source.length, chunkSize: 64 * 1024),
      ),
    );
    Uint8List head;
    try {
      head = await probe.read(512);
    } on FormatException catch (e) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The ${_label(compression)} data is damaged.',
        detail: e.message,
      );
    } finally {
      await probe.cancel();
    }
    if (head.length == 512 && looksLikeTarHeader(head)) {
      return _openCompressedTar(
        source,
        compression,
        limits,
        onProgress,
        onEntries,
      );
    }
    return _openBare(source, compression, name);
  }

  static String _label(TarCompression c) => switch (c) {
    TarCompression.none => 'TAR',
    TarCompression.gzip => 'gzip',
    TarCompression.bzip2 => 'bzip2',
    TarCompression.xz => 'XZ',
  };

  static Future<TarBackend> _openBare(
    koni.ByteSource source,
    TarCompression compression,
    String fileName,
  ) async {
    var inner = fileName;
    final lower = fileName.toLowerCase();
    for (final ext in ['.gz', '.gzip', '.bz2', '.xz', '.z']) {
      if (lower.endsWith(ext)) {
        inner = fileName.substring(0, fileName.length - ext.length);
        break;
      }
    }
    var size = -1;
    DateTime? modified;
    if (compression == TarCompression.gzip && source.length >= 18) {
      final hdr = await source.read(0, source.length < 1024 ? source.length : 1024);
      final flags = hdr[3];
      final mtime = hdr[4] | (hdr[5] << 8) | (hdr[6] << 16) | (hdr[7] << 24);
      if (mtime > 0) {
        modified = DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true);
      }
      var p = 10;
      if (flags & 0x04 != 0 && p + 2 <= hdr.length) {
        p += 2 + (hdr[p] | (hdr[p + 1] << 8));
      }
      if (flags & 0x08 != 0) {
        final start = p;
        while (p < hdr.length && hdr[p] != 0) {
          p++;
        }
        if (p < hdr.length && p > start) {
          final stored = latin1.decode(Uint8List.sublistView(hdr, start, p));
          final base = stored.split(RegExp(r'[\\/]')).last;
          if (base.isNotEmpty) inner = base;
        }
      }
      // ISIZE is the size modulo 2^32, and multi-member files only record
      // their last member: shown as an estimate (sizeIsExact: false).
      final tail = await source.read(source.length - 4, 4);
      size = ByteData.sublistView(tail).getUint32(0, Endian.little);
    }
    if (inner.isEmpty || inner == fileName) inner = '$fileName.out';
    final norm = normalizeArcPath(inner);
    return TarBackend._(
      source,
      compression,
      [
        ArcEntry(
          index: 0,
          path: norm.path.isEmpty ? 'data' : norm.path,
          isDirectory: false,
          size: size,
          packedSize: source.length,
          modified: modified,
          method: _label(compression),
          sizeIsExact: false,
        ),
      ],
      [_TarItem(0, size)],
      _label(compression).toUpperCase(),
      bare: true,
    );
  }

  static Future<TarBackend> _openPlain(
    koni.ByteSource source,
    ArcLimits limits,
    void Function(List<ArcEntry> batch)? onEntries,
  ) async {
    final entries = <ArcEntry>[];
    final items = <_TarItem>[];
    final walker = _TarWalker(entries, items, limits);
    var pos = 0;
    var batchStart = 0;
    while (pos + 512 <= source.length) {
      final h = await source.read(pos, 512);
      final r = await walker.header(h, pos, (len) => source.read(pos + 512, len));
      if (r == null) break;
      pos = r;
      if (onEntries != null && entries.length - batchStart >= 500) {
        onEntries(entries.sublist(batchStart));
        batchStart = entries.length;
      }
    }
    if (entries.isEmpty && !walker.sawHeader) {
      throw ArcException(ArcErrorKind.notArchive, 'This isn\'t a TAR archive.');
    }
    if (onEntries != null && batchStart < entries.length) {
      onEntries(entries.sublist(batchStart));
    }
    return TarBackend._(
      source,
      TarCompression.none,
      entries,
      items,
      'TAR',
    );
  }

  static Future<TarBackend> _openCompressedTar(
    koni.ByteSource source,
    TarCompression compression,
    ArcLimits limits,
    void Function(double progress)? onProgress,
    void Function(List<ArcEntry> batch)? onEntries,
  ) async {
    final entries = <ArcEntry>[];
    final items = <_TarItem>[];
    final walker = _TarWalker(entries, items, limits);
    var raw = 0;
    var lastReport = 0;
    final total = source.length;
    final backend = TarBackend._(
      source,
      compression,
      entries,
      items,
      'TAR.${_label(compression).toUpperCase()}',
    );
    final f = _Forward(
      backend._stream(
        onRaw: (n) {
          raw += n;
          if (onProgress != null && raw - lastReport > total ~/ 200) {
            lastReport = raw;
            onProgress(raw / total);
          }
        },
      ),
    );
    var batchStart = 0;
    try {
      while (true) {
        final pos = f.pos;
        final h = await f.read(512);
        if (h.length < 512) break;
        final next = await walker.header(h, pos, (len) => f.read(len));
        if (next == null) break;
        // Skip the data (and padding) that the walker didn't consume.
        if (next > f.pos) await f.skip(next - f.pos);
        if (onEntries != null && entries.length - batchStart >= 500) {
          onEntries(entries.sublist(batchStart));
          batchStart = entries.length;
        }
      }
    } on FormatException catch (e) {
      if (entries.isEmpty) {
        throw ArcException(
          ArcErrorKind.corrupt,
          'The ${_label(compression)} data is damaged.',
          detail: e.message,
        );
      }
      // Keep what was listed before the damage.
    } finally {
      await f.cancel();
    }
    if (onEntries != null && batchStart < entries.length) {
      onEntries(entries.sublist(batchStart));
    }
    onProgress?.call(1);
    return backend;
  }

  @override
  Stream<Uint8List> openRead(ArcEntry entry) {
    if (entry.isDirectory || entry.isSymlink) return const Stream.empty();
    final reason = entry.unsupportedReason;
    if (reason != null) {
      throw ArcException(ArcErrorKind.unsupported, reason, entryPath: entry.path);
    }
    final item = _items[entry.index];
    if (compression == TarCompression.none) {
      if (item.dataOffset + item.size > _source.length) {
        throw ArcException(
          ArcErrorKind.corrupt,
          'The archive is truncated ("${entry.name}" runs past its end).',
          entryPath: entry.path,
        );
      }
      return readRange(_source, item.dataOffset, item.size);
    }
    return _readSequential(entry, item);
  }

  Stream<Uint8List> _readSequential(ArcEntry entry, _TarItem item) async* {
    var cursor = _cursor;
    if (cursor == null || cursor.busy || cursor.pos > item.dataOffset) {
      if (cursor != null && !cursor.busy) await cursor.cancel();
      cursor = _Forward(_stream());
      _cursor = cursor;
    }
    cursor.busy = true;
    try {
      final gap = item.dataOffset - cursor.pos;
      var skipped = 0;
      while (skipped < gap) {
        final step = gap - skipped < (8 << 20) ? gap - skipped : 8 << 20;
        await cursor.skip(step);
        skipped += step;
        if (gap > (8 << 20)) onSeek?.call(skipped / gap);
      }
      var left = bare ? 1 << 62 : item.size;
      while (left > 0) {
        final chunk = await cursor.next(left < (1 << 20) ? left : 1 << 20);
        if (chunk == null) {
          if (bare) break;
          throw const FormatException('unexpected end of TAR data');
        }
        left -= chunk.length;
        // The cursor's buffer is handed out as is; copy so later reads
        // can't alias it.
        yield Uint8List.fromList(chunk);
      }
    } on FormatException catch (e) {
      _cursor = null;
      await cursor.cancel();
      throw ArcException(
        ArcErrorKind.corrupt,
        '"${entry.name}" can\'t be unpacked: the archive is damaged.',
        entryPath: entry.path,
        detail: e.message,
      );
    } finally {
      cursor.busy = false;
    }
  }

  @override
  Future<void> close() async {
    await _cursor?.cancel();
    _cursor = null;
    await _source.close();
  }
}

/// Header-walking state shared by the seekable and the streaming paths.
class _TarWalker {
  _TarWalker(this.entries, this.items, this.limits);

  final List<ArcEntry> entries;
  final List<_TarItem> items;
  final ArcLimits limits;
  bool sawHeader = false;

  String? _longName;
  String? _longLink;
  Map<String, String> _pax = {};
  Map<String, String> _globalPax = {};

  static int _padded(int size) => (size + 511) & ~511;

  /// Handles the header [h] at [pos]. [readData] reads the start of its
  /// data area (only used for metadata records). Returns the offset of the
  /// next header, or null at the end of the archive.
  Future<int?> header(
    Uint8List h,
    int pos,
    Future<Uint8List> Function(int len) readData,
  ) async {
    if (!looksLikeTarHeader(h)) {
      var zero = true;
      for (var i = 0; i < 512; i++) {
        if (h[i] != 0) {
          zero = false;
          break;
        }
      }
      if (zero || sawHeader) return null; // end marker / trailing garbage
      throw ArcException(ArcErrorKind.notArchive, 'This isn\'t a TAR archive.');
    }
    sawHeader = true;
    final type = h[156];
    var size = _parseNumber(h, 124, 12) ?? 0;
    final dataPos = pos + 512;

    Future<String> readText() async {
      if (size > 8 * 1024 * 1024) {
        throw const FormatException('oversized TAR metadata record');
      }
      final data = await readData(size);
      return utf8.decode(data, allowMalformed: true);
    }

    switch (type) {
      case 0x4C: // 'L' GNU long name
        _longName = (await readText()).split('\u0000').first;
        return dataPos + _padded(size);
      case 0x4B: // 'K' GNU long link
        _longLink = (await readText()).split('\u0000').first;
        return dataPos + _padded(size);
      case 0x78: // 'x' pax per-file
        _pax = _parsePax(await readText());
        return dataPos + _padded(size);
      case 0x67: // 'g' pax global
        _globalPax = {..._globalPax, ..._parsePax(await readText())};
        return dataPos + _padded(size);
      case 0x56: // 'V' volume label
        return dataPos + _padded(size);
    }

    final pax = {..._globalPax, ..._pax};
    var name = pax['path'] ?? _longName;
    if (name == null) {
      name = _cString(h, 0, 100);
      final magic = String.fromCharCodes(Uint8List.sublistView(h, 257, 263));
      if (magic == 'ustar\u0000') {
        final prefix = _cString(h, 345, 155);
        if (prefix.isNotEmpty) name = '$prefix/$name';
      }
    }
    final link = pax['linkpath'] ?? _longLink ?? _cString(h, 157, 100);
    final paxSize = int.tryParse(pax['size'] ?? '');
    if (paxSize != null) size = paxSize;
    DateTime? modified;
    final paxTime = double.tryParse(pax['mtime'] ?? '');
    if (paxTime != null) {
      modified = DateTime.fromMillisecondsSinceEpoch(
        (paxTime * 1000).round(),
        isUtc: true,
      );
    } else {
      final t = _parseNumber(h, 136, 12);
      if (t != null && t > 0) {
        modified = DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true);
      }
    }
    _longName = null;
    _longLink = null;
    _pax = {};

    final isDir = type == 0x35 || (type == 0x30 || type == 0) && name.endsWith('/');
    final isFile = type == 0x30 || type == 0 || type == 0x37;
    final isSymlink = type == 0x32;
    final isHardlink = type == 0x31;
    String? unsupported;
    if (type == 0x53) {
      unsupported = 'GNU sparse files aren\'t supported.';
    } else if (type == 0x4D) {
      unsupported = 'This entry continues from another TAR volume.';
    }
    // Device nodes, FIFOs and hard links carry no data of their own.
    final hasData = isFile || type == 0x53 || type == 0x4D ||
        !(isDir || isSymlink || isHardlink || type == 0x33 || type == 0x34 ||
            type == 0x36);
    if (isFile || isDir || isSymlink || isHardlink || unsupported != null ||
        hasData) {
      final norm = normalizeArcPath(name);
      if (norm.path.isNotEmpty) {
        final index = entries.length;
        entries.add(
          ArcEntry(
            index: index,
            path: norm.path,
            isDirectory: isDir,
            size: isDir ? 0 : (hasData ? size : 0),
            modified: modified,
            isSymlink: isSymlink || isHardlink,
            linkTarget: (isSymlink || isHardlink) ? link : null,
            unsafePath: norm.escaped,
            unsupportedReason: unsupported,
          ),
        );
        items.add(_TarItem(dataPos, hasData ? size : 0));
        if (entries.length > limits.maxEntries) {
          throw ArcException(
            ArcErrorKind.tooLarge,
            'The archive has more entries than Folders will open.',
          );
        }
      }
    }
    return dataPos + (hasData ? _padded(size) : 0);
  }

  static Map<String, String> _parsePax(String text) {
    final out = <String, String>{};
    var i = 0;
    while (i < text.length) {
      final space = text.indexOf(' ', i);
      if (space < 0) break;
      final len = int.tryParse(text.substring(i, space));
      if (len == null || len <= 0) break;
      // The length counts bytes, but records are almost always ASCII keys
      // with UTF-8 values; find the record end by the newline instead.
      final nl = text.indexOf('\n', space);
      if (nl < 0) break;
      final record = text.substring(space + 1, nl);
      final eq = record.indexOf('=');
      if (eq > 0) out[record.substring(0, eq)] = record.substring(eq + 1);
      i = nl + 1;
    }
    return out;
  }
}
