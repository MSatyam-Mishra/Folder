/// RAR 4/5 reader built on the vendored koni_rar decoders.
///
/// koni_rar's own `RarReader` keeps every decoded member of a solid run in
/// memory and sizes the solid window to the dictionary, so solid archives
/// larger than the dictionary (most real CBRs) fail after a few members.
/// This driver uses the same header parsers and LZ decoders but:
///
/// * decodes solid runs in a bounded window (dictionary + largest member),
///   sliding the history down when it fills, and keeps nothing else;
/// * streams stored members straight from disk (any size, across volumes);
/// * merges multi-volume sets and names the first missing part.
///
/// The koni_rar package is vendored at a fixed version (third_party/), so
/// its `src/` classes are a stable dependency here.
// ignore_for_file: implementation_imports
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;
import 'package:koni_rar/src/rar20_decoder.dart';
import 'package:koni_rar/src/rar4_container.dart';
import 'package:koni_rar/src/rar5_container.dart';
import 'package:koni_rar/src/rar_crypto.dart';

import 'archive_backend.dart';
import 'archive_rar4_decoder.dart';
import 'archive_rar5_decoder.dart';

/// Resolves volume [number] (2, 3, …) of a multi-volume set.
typedef VolumeResolver = Future<koni.ByteSource?> Function(int number);

class _Segment {
  _Segment(this.source, this.offset, this.size);
  final koni.ByteSource source;
  final int offset;
  final int size;
}

class RarBackend extends ArcBackend {
  RarBackend._(
    this._volumes,
    this._headers,
    this._segments,
    this.entries,
    this.formatLabel,
    this._password,
    this._limits,
  );

  final List<koni.ByteSource> _volumes;
  final List<Rar5FileHeader> _headers;
  final List<List<_Segment>> _segments;
  final String? _password;
  final ArcLimits _limits;

  @override
  final List<ArcEntry> entries;

  @override
  final String formatLabel;

  late final bool _solid = _headers.any((h) => h.solid);

  @override
  bool get isSequential => _solid;

  _SolidRun? _run;
  final Map<String, Rar5Keys> _keyCache = {};
  final Map<String, Rar4Keys> _rar4Cache = {};

  /// Opens a RAR archive whose first volume is [first]. Later volumes come
  /// from [nextVolume]; [volumeName] names a volume number for messages.
  static Future<RarBackend> open(
    koni.ByteSource first, {
    VolumeResolver? nextVolume,
    String Function(int number)? volumeName,
    bool Function(int number)? volumeExists,
    String? password,
    ArcLimits limits = const ArcLimits(),
  }) async {
    final head = await first.read(0, first.length < 8 ? first.length : 8);
    if (head.length < 7 ||
        head[0] != 0x52 ||
        head[1] != 0x61 ||
        head[2] != 0x72 ||
        head[3] != 0x21 ||
        head[4] != 0x1A ||
        head[5] != 0x07) {
      throw ArcException(ArcErrorKind.notArchive, 'This isn\'t a RAR archive.');
    }
    final isRar5 = head[6] == 0x01;
    final pw = (password == null || password.isEmpty) ? null : password;

    Future<Rar5Toc> parse(koni.ByteSource s) async {
      try {
        return isRar5
            ? await Rar5Toc.parse(s, 8, password: pw)
            : await parseRar4(s, 7, password: pw);
      } on koni.InvalidPasswordException {
        throw ArcException(ArcErrorKind.wrongPassword, 'Wrong password.');
      } on koni.ArchiveException catch (e) {
        if (pw != null && e is koni.CorruptArchiveException) {
          // Encrypted headers decrypted with the wrong key read as garbage.
          throw ArcException(
            ArcErrorKind.wrongPassword,
            'Wrong password (or the archive is damaged).',
            detail: e.message,
          );
        }
        throw mapKoniError(e);
      }
    }

    final firstToc = await parse(first);
    if (firstToc.headerEncrypted && pw == null) {
      throw ArcException(
        ArcErrorKind.needPassword,
        'This archive is password protected (file names are encrypted too).',
      );
    }

    final volumes = <koni.ByteSource>[first];
    final headers = <Rar5FileHeader>[];
    final segments = <List<_Segment>>[];
    var expectingContinuation = false;

    void addVolume(koni.ByteSource src, List<Rar5FileHeader> files) {
      for (final h in files) {
        if (h.splitBefore &&
            expectingContinuation &&
            headers.isNotEmpty &&
            headers.last.name == h.name) {
          segments.last.add(_Segment(src, h.dataOffset, h.dataSize));
          // The last piece carries the whole file's CRC.
          if (!h.splitAfter) headers[headers.length - 1] = h;
        } else {
          headers.add(h);
          segments.add([_Segment(src, h.dataOffset, h.dataSize)]);
        }
        expectingContinuation = h.splitAfter;
      }
    }

    addVolume(first, firstToc.files);
    if (firstToc.isVolume) {
      var number = 2;
      while (nextVolume != null) {
        final next = await nextVolume(number);
        if (next == null) break;
        volumes.add(next);
        addVolume(next, (await parse(next)).files);
        number++;
      }
      // A gap: a later part exists although this one doesn't.
      final gap = volumeExists != null &&
          (volumeExists(number + 1) || volumeExists(number + 2));
      if (expectingContinuation || gap) {
        final missing = volumeName?.call(number) ?? 'volume $number';
        throw ArcException(
          ArcErrorKind.missingVolume,
          'Part "$missing" of this multi-volume archive is missing. Put all '
          'parts in the same folder.',
        );
      }
    }
    if (headers.length > limits.maxEntries) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        'The archive has more entries than Folder will open.',
      );
    }

    final entries = <ArcEntry>[];
    for (var i = 0; i < headers.length; i++) {
      final h = headers[i];
      final norm = normalizeArcPath(h.name);
      final packed = segments[i].fold<int>(0, (s, seg) => s + seg.size);
      entries.add(
        ArcEntry(
          index: i,
          path: norm.path,
          isDirectory: h.isDirectory,
          size: h.isDirectory ? 0 : h.unpackedSize,
          packedSize: h.isDirectory ? 0 : packed,
          modified: h.version == 29 ? _rar4Local(h.modified) : h.modified,
          isEncrypted: h.isEncrypted,
          isSymlink: h.redirectTarget != null,
          linkTarget: h.redirectTarget,
          unsafePath: norm.escaped,
          method: h.isDirectory ? null : _methodLabel(h),
          crc32: h.crc32,
          unsupportedReason: h.isDirectory ? null : _unsupported(h),
        ),
      );
    }
    final solid = headers.any((h) => h.solid);
    final label =
        '${isRar5 ? 'RAR 5' : 'RAR 4'}'
        '${solid ? ', solid' : ''}'
        '${volumes.length > 1 ? ', ${volumes.length} parts' : ''}';
    return RarBackend._(
      volumes,
      headers,
      segments,
      entries,
      label,
      pw,
      limits,
    );
  }

  /// RAR4 stores local DOS times; koni_rar labels their fields as UTC.
  static DateTime? _rar4Local(DateTime? naive) {
    if (naive == null || naive.year < 1980) return naive;
    final date =
        ((naive.year - 1980) << 9) | (naive.month << 5) | naive.day;
    final time = (naive.hour << 11) | (naive.minute << 5) | (naive.second >> 1);
    return dosDateTime(date, time);
  }

  static String _methodLabel(Rar5FileHeader h) {
    if (h.method == 0) return 'Stored';
    const names = ['Stored', 'Fastest', 'Fast', 'Normal', 'Good', 'Best'];
    final level = h.method < names.length ? names[h.method] : 'm${h.method}';
    return h.version == 29 ? 'RAR ${h.unpackVersion / 10} $level' : level;
  }

  static String? _unsupported(Rar5FileHeader h) {
    if (h.version != 50 && h.version != 29) {
      return 'This file uses RAR 7 compression (very large dictionary), '
          'which Folder can\'t decode.';
    }
    if (h.version == 29 && h.method != 0) {
      final uv = h.unpackVersion;
      if (uv == 15) {
        return 'RAR 1.5 compression isn\'t supported.';
      }
      if (uv != 20 && uv != 26 && uv != 29) {
        return 'RAR compression version $uv isn\'t supported.';
      }
      if ((uv == 20 || uv == 26) && h.solid) {
        return 'Solid RAR 2.x archives aren\'t supported.';
      }
    }
    if (h.isEncrypted && h.version == 50 &&
        !(h.encryption?.isAes256 ?? false)) {
      return 'Unknown RAR encryption method.';
    }
    if (h.isEncrypted && h.version == 29 && h.rar4Salt == null) {
      return 'This old RAR encryption method isn\'t supported.';
    }
    return null;
  }

  // ---------------------------------------------------------------------------

  @override
  Stream<Uint8List> openRead(ArcEntry entry) {
    final h = _headers[entry.index];
    if (h.isDirectory || entry.isSymlink) return const Stream.empty();
    final reason = entry.unsupportedReason;
    if (reason != null) {
      throw ArcException(ArcErrorKind.unsupported, reason, entryPath: entry.path);
    }
    if (h.isEncrypted && _password == null) {
      throw ArcException(
        ArcErrorKind.needPassword,
        '"${entry.name}" is password protected.',
        entryPath: entry.path,
      );
    }
    return _guard(entry, _read(entry, h));
  }

  Stream<Uint8List> _guard(ArcEntry entry, Stream<Uint8List> s) async* {
    try {
      await for (final chunk in s) {
        yield chunk;
      }
    } on ArcException {
      rethrow;
    } on FormatException catch (e) {
      if (entry.isEncrypted) {
        throw ArcException(
          ArcErrorKind.wrongPassword,
          'Wrong password for "${entry.name}" (or the data is damaged).',
          entryPath: entry.path,
          detail: e.message,
        );
      }
      if (e.message.contains('not supported')) {
        throw ArcException(
          ArcErrorKind.unsupported,
          '"${entry.name}" uses a RAR feature Folder can\'t decode.',
          entryPath: entry.path,
          detail: e.message,
        );
      }
      throw ArcException(
        ArcErrorKind.corrupt,
        '"${entry.name}" is damaged and can\'t be unpacked.',
        entryPath: entry.path,
        detail: e.message,
      );
    } catch (e) {
      throw mapKoniError(e, entryPath: entry.path);
    }
  }

  Stream<Uint8List> _read(ArcEntry entry, Rar5FileHeader h) async* {
    final index = entry.index;
    // Stored and unencrypted: stream the packed bytes directly.
    if (h.method == 0 && !h.isEncrypted) {
      final crc = koni.Crc32();
      var total = 0;
      for (final seg in _segments[index]) {
        _checkSegment(seg, entry);
        await for (final chunk in readRange(seg.source, seg.offset, seg.size)) {
          final take = total + chunk.length > h.unpackedSize
              ? h.unpackedSize - total
              : chunk.length;
          if (take <= 0) break;
          final piece = take == chunk.length
              ? chunk
              : Uint8List.sublistView(chunk, 0, take);
          crc.add(piece);
          total += take;
          yield piece;
        }
      }
      if (total != h.unpackedSize) {
        throw const FormatException('stored entry is truncated');
      }
      _checkCrc(entry, h, crc.value);
      return;
    }
    if (!h.solid && !_solid) {
      final data = await _decodeAlone(index, h, entry);
      _checkCrc(entry, h, koni.Crc32.compute(data));
      yield* _chunks(data);
      return;
    }
    // Solid archive: decode through the run.
    var run = _run;
    final start = _runStart(index);
    if (run == null || run.busy || run.runStart != start ||
        run.nextIndex > index) {
      run = _SolidRun(this, start);
      if (_run == null || !_run!.busy) _run = run;
    }
    run.busy = true;
    try {
      final data = await run.decodeTo(index);
      _checkCrc(entry, h, koni.Crc32.compute(data));
      yield* _chunks(data);
    } catch (_) {
      if (identical(_run, run)) _run = null;
      rethrow;
    } finally {
      run.busy = false;
    }
  }

  Stream<Uint8List> _chunks(Uint8List data) async* {
    for (var i = 0; i < data.length; i += 1 << 20) {
      final end = i + (1 << 20) < data.length ? i + (1 << 20) : data.length;
      yield Uint8List.sublistView(data, i, end);
    }
  }

  void _checkSegment(_Segment seg, ArcEntry entry) {
    if (seg.offset + seg.size > seg.source.length) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The archive is truncated ("${entry.name}" runs past the end of a '
        'part).',
        entryPath: entry.path,
      );
    }
  }

  void _checkCrc(ArcEntry entry, Rar5FileHeader h, int actual) {
    final stored = h.crc32;
    if (stored == null) return;
    var value = actual;
    final enc = h.encryption;
    if (enc != null && enc.useMac) {
      value = _rar5Keys(enc).tweakCrc(actual);
    }
    if (value != stored) {
      if (h.isEncrypted) {
        throw ArcException(
          ArcErrorKind.wrongPassword,
          'Wrong password for "${entry.name}".',
          entryPath: entry.path,
        );
      }
      throw ArcException(
        ArcErrorKind.checksum,
        '"${entry.name}" failed its CRC check: the archive is damaged.',
        entryPath: entry.path,
      );
    }
  }

  int _runStart(int index) {
    var start = index;
    while (start > 0 &&
        (_headers[start].solid || _headers[start].isDirectory)) {
      start--;
    }
    return start;
  }

  /// Packed (and decrypted) data of member [index].
  Future<Uint8List> _readData(int index, Rar5FileHeader h) async {
    final segs = _segments[index];
    var total = 0;
    for (final s in segs) {
      total += s.size;
    }
    if (total > _limits.maxInMemoryEntry) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        '"${h.name}" is too large to unpack in memory.',
        entryPath: h.name,
      );
    }
    Uint8List raw;
    if (segs.length == 1) {
      final s = segs.first;
      if (s.offset + s.size > s.source.length) {
        throw const FormatException('member data runs past the end');
      }
      raw = s.size == 0 ? Uint8List(0) : await s.source.read(s.offset, s.size);
    } else {
      raw = Uint8List(total);
      var pos = 0;
      for (final s in segs) {
        if (s.offset + s.size > s.source.length) {
          throw const FormatException('member data runs past the end');
        }
        if (s.size > 0) {
          raw.setRange(pos, pos + s.size, await s.source.read(s.offset, s.size));
        }
        pos += s.size;
      }
    }
    if (!h.isEncrypted) return raw;
    if (raw.length % 16 != 0) {
      throw const FormatException('encrypted data is not block aligned');
    }
    final out = Uint8List.fromList(raw);
    if (h.version == 29) {
      final salt = h.rar4Salt!.join(',');
      (_rar4Cache[salt] ??= Rar4Keys.derive(_password!, h.rar4Salt!))
          .decrypt(out);
    } else {
      final enc = h.encryption!;
      final keys = _rar5Keys(enc);
      if (enc.usePswCheck &&
          rar5PswCheckIntact(enc.pswCheck!, enc.pswCheckCsum!) &&
          !keys.passwordMatches(enc.pswCheck!)) {
        throw ArcException(
          ArcErrorKind.wrongPassword,
          'Wrong password.',
          entryPath: h.name,
        );
      }
      keys.decrypt(out, enc.iv);
    }
    return out;
  }

  Rar5Keys _rar5Keys(Rar5EncryptionInfo enc) {
    final key = '${enc.lg2Count}:${enc.salt.join(',')}';
    return _keyCache[key] ??= Rar5Keys.derive(_password!, enc.salt, enc.lg2Count);
  }

  static int _pow2Ceil(int v) {
    var p = 0x20000;
    while (p < v) {
      p <<= 1;
    }
    return p;
  }

  /// A non-solid compressed member, decoded whole.
  Future<Uint8List> _decodeAlone(
    int index,
    Rar5FileHeader h,
    ArcEntry entry,
  ) async {
    final data = await _readData(index, h);
    if (h.method == 0) {
      if (data.length < h.unpackedSize) {
        throw const FormatException('stored entry is truncated');
      }
      return Uint8List.sublistView(data, 0, h.unpackedSize);
    }
    final window = _pow2Ceil(
      h.unpackedSize > h.windowSize ? h.unpackedSize : h.windowSize,
    );
    if (window > _limits.maxInMemoryEntry) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        '"${entry.name}" is too large for Folder to unpack '
        '(RAR members are decoded in memory).',
        entryPath: entry.path,
      );
    }
    final output = Uint8List(window);
    Uint8List? filtered;
    if (h.version != 29) {
      final d = Rar5Decoder(output)..decompressFile(data, h.unpackedSize);
      filtered = d.lastFiltered;
    } else if (h.unpackVersion == 20 || h.unpackVersion == 26) {
      Rar20Decoder(output).decompressFile(data, h.unpackedSize);
    } else {
      final d = Rar4Decoder(output)..decompressFile(data, h.unpackedSize);
      filtered = d.lastFiltered;
    }
    return filtered ?? Uint8List.sublistView(output, 0, h.unpackedSize);
  }

  @override
  Future<void> close() async {
    _run = null;
    for (final v in _volumes) {
      await v.close();
    }
  }
}

/// Sequential decoder for one solid run with a bounded window.
class _SolidRun {
  _SolidRun(this.owner, this.runStart) : nextIndex = runStart;

  final RarBackend owner;
  final int runStart;
  int nextIndex;
  bool busy = false;

  Rar5Decoder? _r5;
  Rar4Decoder? _r4;
  bool _ppmd = false;
  int _history = 0;

  List<Rar5FileHeader> get _h => owner._headers;

  int _runEnd() {
    var end = runStart;
    while (end + 1 < _h.length &&
        (_h[end + 1].solid || _h[end + 1].isDirectory)) {
      end++;
    }
    return end;
  }

  Future<void> _init() async {
    final end = _runEnd();
    var total = 0, largest = 0, dict = 0;
    var rar4 = false;
    for (var i = runStart; i <= end; i++) {
      final h = _h[i];
      if (h.isDirectory) continue;
      total += h.unpackedSize;
      if (h.unpackedSize > largest) largest = h.unpackedSize;
      if (h.windowSize > dict) dict = h.windowSize;
      if (h.version == 29) rar4 = true;
    }
    // RAR 2.9–4 dictionaries top out at 4 MiB.
    if (rar4) dict = 0x400000;
    _history = dict < total ? dict : total;
    final size = RarBackend._pow2Ceil(_history + largest);
    if (size > owner._limits.maxInMemoryEntry) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        'This solid archive needs more memory than Folder can use to '
        'unpack it.',
      );
    }
    final window = Uint8List(size);
    if (rar4) {
      _r4 = Rar4Decoder(window);
      _ppmd = await _isPpmdRun(end);
    } else {
      _r5 = Rar5Decoder(window);
    }
  }

  Future<bool> _isPpmdRun(int end) async {
    for (var i = runStart; i <= end; i++) {
      final h = _h[i];
      if (h.method == 0 || h.isDirectory) continue;
      final data = await owner._readData(i, h);
      return data.isNotEmpty && (data[0] & 0x80) != 0;
    }
    return false;
  }

  Uint8List get _window => _r5?.output ?? _r4!.output;
  int get _ptr => _r5?.writePtr ?? _r4!.writePtr;
  set _ptr(int v) {
    if (_r5 != null) {
      _r5!.writePtr = v;
    } else {
      _r4!.writePtr = v;
    }
  }

  /// Makes room for [size] more bytes by sliding the last [_history] bytes
  /// to the start of the window.
  void _ensureRoom(int size) {
    final w = _window;
    final ptr = _ptr;
    if (ptr + size <= w.length) return;
    final keep = _history < ptr ? _history : ptr;
    w.setRange(0, keep, w, ptr - keep);
    _ptr = keep;
  }

  /// Decodes members up to [index] and returns a copy of its content.
  Future<Uint8List> decodeTo(int index) async {
    if (_r5 == null && _r4 == null) await _init();
    Uint8List? result;
    var seekTotal = 0, seekDone = 0;
    for (var i = nextIndex; i < index; i++) {
      seekTotal += _h[i].isDirectory ? 0 : _h[i].unpackedSize;
    }
    for (var i = nextIndex; i <= index; i++) {
      final h = _h[i];
      nextIndex = i + 1;
      if (h.isDirectory) continue;
      if (i < index && seekTotal > 0) {
        owner.onSeek?.call(seekDone / seekTotal);
        seekDone += h.unpackedSize;
      }
      _ensureRoom(h.unpackedSize);
      final start = _ptr;
      final data = await owner._readData(i, h);
      Uint8List? filtered;
      if (h.method == 0) {
        if (data.length < h.unpackedSize) {
          throw const FormatException('stored entry is truncated');
        }
        _window.setRange(start, start + h.unpackedSize, data);
        _ptr = start + h.unpackedSize;
      } else if (_r5 != null) {
        _r5!.beginFileFilters();
        _r5!.decompressFile(data, h.unpackedSize);
        filtered = _r5!.lastFiltered;
      } else if (_ppmd) {
        final slice = _r4!.decompressSolidPpmdFile(data, h.unpackedSize);
        if (slice.end - slice.start != h.unpackedSize) {
          throw const FormatException('PPMd member size mismatch');
        }
      } else {
        _r4!.decompressFile(
          data,
          h.unpackedSize,
          parseTable: !_r4!.hasTables,
        );
        filtered = _r4!.lastFiltered;
      }
      if (i == index) {
        result = filtered ??
            Uint8List.fromList(
              Uint8List.sublistView(_window, start, start + h.unpackedSize),
            );
      }
    }
    return result ?? Uint8List(0);
  }
}
