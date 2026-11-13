import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:folders/core/services/compress/archive_sink.dart';
import 'package:folders/core/services/compress/stream_codecs.dart';
import 'package:folders/core/services/compress/zip_writer.dart'
    show ReadProgress, ShouldStop, isCompressedAlready, openInput, readChunks;
import 'package:koni_codecs/crypto.dart';
import 'package:koni_codecs/koni_codecs.dart' show LzmaEncoder;

/// What a 7z's folders are packed with.
enum SevenZMethod { copy, deflate, lzma2 }

/// One thing to put in an archive: a folder, or a file on disk.
class ArchiveItem {
  const ArchiveItem.folder(this.name, this.modified)
      : path = null,
        size = 0;

  const ArchiveItem.file(this.name, this.path, this.size, this.modified);

  /// Its path in the archive, with forward slashes.
  final String name;

  /// The file on disk; null for a folder.
  final String? path;
  final int size;
  final DateTime modified;

  bool get isFolder => path == null;
}

/// Writes a 7z straight to [sink], never holding more than a block in
/// memory: the start header is filled in at the end.
///
/// Files are packed into solid folders of up to [solidSize] with [method]:
/// LZMA2 a block of [blockSize] at a time (each block with a dictionary of
/// its own, so memory stays bounded), or Deflate through the system's zlib.
/// Files that are compressed already (videos, photos, archives) go into
/// Copy folders of their own, as compressing them again only costs time.
/// With a [password], every folder is encrypted with AES-256 (7-Zip's
/// SHA-256 key and a fresh IV per folder), and with [encryptNames] the
/// header too, which hides the names until the password is given, as
/// 7-Zip's -mhe does. 7-Zip, WinRAR, PeaZip, p7zip and Windows 11 (through
/// libarchive, without passwords) read what it writes.
class SevenZWriter {
  SevenZWriter(
    this.sink, {
    this.method = SevenZMethod.lzma2,
    this.blockSize = 4 << 20,
    this.deflateLevel = 6,
    this.password,
    this.encryptNames = false,
    this.solidSize = 64 << 20,
  }) {
    if (encryptNames && password == null) throw ArgumentError('encryptNames needs a password');
  }

  final ArchiveSink sink;
  final SevenZMethod method;
  final int blockSize;
  final int deflateLevel;
  final String? password;
  final bool encryptNames;
  final int solidSize;

  static const _signature = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04];
  static const _copyId = [0x00];
  static const _deflateId = [0x04, 0x01, 0x08];
  static const _lzmaId = [0x03, 0x01, 0x01];
  static const _lzma2Id = [0x21];
  static const _aesId = [0x06, 0xF1, 0x07, 0x01];

  /// 7-Zip's cost for the key: 2^19 rounds of SHA-256.
  static const _aesCycles = 19;
  static final _random = math.Random.secure();

  final _folders = <_Folder>[];
  final _records = <_Record>[];
  Uint8List? _key;
  var _packStart = 0;

  /// Writes all of [items]: folders and empty files first, then the files to
  /// compress, then those stored as they are (a 7z lists files in the order
  /// of its packed streams). A file that can't be opened is left out and
  /// told to [onSkip].
  void write(
    List<ArchiveItem> items, {
    ReadProgress? onRead,
    ShouldStop? stop,
    void Function(ArchiveItem item, Object error)? onSkip,
  }) {
    sink.add(Uint8List(32)); // The start header, filled in by close.
    _packStart = sink.position;
    final squeeze = <ArchiveItem>[];
    final keep = <ArchiveItem>[];
    for (final item in items) {
      if (item.isFolder || item.size == 0) {
        _records.add(_Record(item, hasStream: false));
      } else if (method == SevenZMethod.copy || isCompressedAlready(item.name)) {
        keep.add(item);
      } else {
        squeeze.add(item);
      }
    }
    _FolderWriter? open;
    for (final item in squeeze) {
      if (open != null && open.unpacked >= solidSize) {
        _folders.add(open.finish());
        open = null;
      }
      final RandomAccessFile input;
      try {
        input = openInput(item.path!);
      } on FileSystemException catch (error) {
        onSkip?.call(item, error);
        continue;
      }
      open ??= _FolderWriter(this, method);
      open.addFile(item, input, onRead: onRead, stop: stop);
      _records.add(_Record(item, hasStream: true));
    }
    if (open != null) _folders.add(open.finish());
    for (final item in keep) {
      final RandomAccessFile input;
      try {
        input = openInput(item.path!);
      } on FileSystemException catch (error) {
        onSkip?.call(item, error);
        continue;
      }
      final folder = _FolderWriter(this, SevenZMethod.copy)..addFile(item, input, onRead: onRead, stop: stop);
      _folders.add(folder.finish());
      _records.add(_Record(item, hasStream: true));
    }
  }

  /// The key every folder is encrypted with (7-Zip's KDF, without a salt).
  Uint8List get _aesKey => _key ??= sevenZipKey(password!, cycles: _aesCycles);

  /// 7-Zip's key: SHA-256 over the password (UTF-16LE) and a counter, 2^[cycles]
  /// times.
  static Uint8List sevenZipKey(String password, {int cycles = _aesCycles}) {
    final pw = Uint8List(password.length * 2);
    for (var i = 0; i < password.length; i++) {
      pw[i * 2] = password.codeUnitAt(i) & 0xFF;
      pw[i * 2 + 1] = password.codeUnitAt(i) >> 8;
    }
    final sha = Sha256();
    final round = Uint8List(pw.length + 8)..setRange(0, pw.length, pw);
    for (var i = 0; i < 1 << cycles; i++) {
      // The counter, little-endian, after the password.
      var n = i;
      for (var j = 0; j < 8; j++) {
        round[pw.length + j] = n & 0xFF;
        n >>= 8;
      }
      sha.add(round);
    }
    return sha.finish();
  }

  Uint8List _iv() => Uint8List.fromList([for (var i = 0; i < 16; i++) _random.nextInt(256)]);

  /// The AES coder's properties: the cost, no salt, and [iv].
  static Uint8List _aesProps(Uint8List iv) => Uint8List.fromList([_aesCycles | 0x40, 0x0F, ...iv]);

  /// The header, then the start header that points at it.
  void close() {
    final header = _header();
    final headerCrc = getCrc32(header);
    final packedEnd = sink.position;
    var trailing = header;
    final lzma = LzmaEncoder(dictSize: math.max(1 << 16, math.min(header.length, 1 << 24)));
    final packed = lzma.encode(header);
    if (encryptNames) {
      final iv = _iv();
      final padded = _pad16(packed);
      AesCbcEncryptor(Aes(_aesKey), iv).encryptInPlace(padded);
      sink.add(padded);
      trailing = (_Buffer()
            ..number(0x17) // kEncodedHeader
            ..number(0x06)
            ..number(packedEnd - _packStart)
            ..number(1)
            ..number(0x09)
            ..number(padded.length)
            ..number(0x00)
            ..number(0x07)
            ..number(0x0B)
            ..number(1)
            ..byte(0)
            // AES first, as 7-Zip lists them: the packed stream goes into
            // AES, and LZMA's input is AES's output.
            ..number(2)
            ..byte(_aesId.length | 0x20)
            ..bytes(_aesId)
            ..number(18)
            ..bytes(_aesProps(iv))
            ..byte(_lzmaId.length | 0x20)
            ..bytes(_lzmaId)
            ..number(5)
            ..bytes(lzma.sevenZipProps())
            ..number(1) // LZMA's input…
            ..number(0) // …is AES's output
            ..number(0x0C)
            ..number(packed.length)
            ..number(header.length)
            ..number(0x0A)
            ..byte(1)
            ..u32(headerCrc)
            ..number(0x00)
            ..number(0x00))
          .take();
    } else if (packed.length + 40 < header.length) {
      sink.add(packed);
      trailing = (_Buffer()
            ..number(0x17)
            ..number(0x06)
            ..number(packedEnd - _packStart)
            ..number(1)
            ..number(0x09)
            ..number(packed.length)
            ..number(0x00)
            ..number(0x07)
            ..number(0x0B)
            ..number(1)
            ..byte(0)
            ..number(1)
            ..byte(_lzmaId.length | 0x20)
            ..bytes(_lzmaId)
            ..number(5)
            ..bytes(lzma.sevenZipProps())
            ..number(0x0C)
            ..number(header.length)
            ..number(0x0A)
            ..byte(1)
            ..u32(headerCrc)
            ..number(0x00)
            ..number(0x00))
          .take();
    }
    final headerAt = sink.position;
    sink.add(trailing);
    final start = (_Buffer()
          ..u64(headerAt - _packStart)
          ..u64(trailing.length)
          ..u32(getCrc32(trailing)))
        .take();
    sink.patch(0, (_Buffer()
          ..bytes(_signature)
          ..u32(getCrc32(start))
          ..bytes(start))
        .take());
  }

  static Uint8List _pad16(Uint8List data) {
    final rest = data.length % 16;
    if (rest == 0) return Uint8List.fromList(data);
    return Uint8List(data.length + 16 - rest)..setRange(0, data.length, data);
  }

  Uint8List _header() {
    final h = _Buffer()..number(0x01); // kHeader
    if (_folders.isNotEmpty) {
      h
        ..number(0x04) // kMainStreamsInfo
        ..number(0x06) // kPackInfo
        ..number(0)
        ..number(_folders.length)
        ..number(0x09);
      for (final folder in _folders) {
        h.number(folder.packSize);
      }
      h
        ..number(0x00)
        ..number(0x07) // kUnpackInfo
        ..number(0x0B)
        ..number(_folders.length)
        ..byte(0);
      for (final folder in _folders) {
        final id = folder.coderId;
        final props = folder.props;
        final aes = folder.aesProps;
        h.number(aes == null ? 1 : 2);
        // Encrypted: AES first, as 7-Zip lists them (py7zr reads them only
        // so): the packed stream goes into AES, the compressor's input is
        // AES's output.
        if (aes != null) {
          h
            ..byte(_aesId.length | 0x20)
            ..bytes(_aesId)
            ..number(aes.length)
            ..bytes(aes);
        }
        h
          ..byte(id.length | (props == null ? 0 : 0x20))
          ..bytes(id);
        if (props != null) {
          h
            ..number(props.length)
            ..bytes(props);
        }
        if (aes != null) {
          h
            ..number(1)
            ..number(0);
        }
      }
      h.number(0x0C); // kCodersUnpackSize, by coder
      for (final folder in _folders) {
        if (folder.aesProps != null) h.number(folder.coderOut);
        h.number(folder.unpackSize);
      }
      h
        ..number(0x00)
        ..number(0x08); // kSubStreamsInfo
      if (_folders.any((f) => f.sizes.length != 1)) {
        h.number(0x0D);
        for (final folder in _folders) {
          h.number(folder.sizes.length);
        }
      }
      if (_folders.any((f) => f.sizes.length > 1)) {
        h.number(0x09);
        for (final folder in _folders) {
          for (var i = 0; i < folder.sizes.length - 1; i++) {
            h.number(folder.sizes[i]);
          }
        }
      }
      h
        ..number(0x0A) // kCRC: every file's
        ..byte(1);
      for (final folder in _folders) {
        for (final crc in folder.crcs) {
          h.u32(crc);
        }
      }
      h
        ..number(0x00)
        ..number(0x00);
    }
    if (_records.isNotEmpty) {
      h
        ..number(0x05) // kFilesInfo
        ..number(_records.length);
      final empty = [for (final r in _records) !r.hasStream];
      if (empty.any((e) => e)) {
        h.property(0x0E, _Buffer()..bits(empty));
        final emptyFiles = [
          for (final r in _records)
            if (!r.hasStream) !r.item.isFolder,
        ];
        if (emptyFiles.any((e) => e)) h.property(0x0F, _Buffer()..bits(emptyFiles));
      }
      final names = _Buffer()..byte(0);
      for (final r in _records) {
        for (final unit in r.item.name.codeUnits) {
          names.u16(unit);
        }
        names.u16(0);
      }
      h.property(0x11, names);
      final times = _Buffer()
        ..byte(1)
        ..byte(0);
      for (final r in _records) {
        times.fileTime(r.item.modified);
      }
      h.property(0x14, times);
      final attributes = _Buffer()
        ..byte(1)
        ..byte(0);
      for (final r in _records) {
        attributes.u32(r.item.isFolder ? 0x10 : 0x20);
      }
      h
        ..property(0x15, attributes)
        ..number(0x00);
    }
    h.number(0x00);
    return h.take();
  }
}

class _Record {
  _Record(this.item, {required this.hasStream});

  final ArchiveItem item;
  final bool hasStream;
}

/// A finished folder: how it's coded and what's in it.
class _Folder {
  _Folder({
    required this.coderId,
    required this.props,
    required this.aesProps,
    required this.packSize,
    required this.coderOut,
    required this.sizes,
    required this.crcs,
  });

  final List<int> coderId;
  final Uint8List? props;
  final Uint8List? aesProps;
  final int packSize;

  /// What the compressor wrote, before AES's padding.
  final int coderOut;
  final List<int> sizes;
  final List<int> crcs;

  int get unpackSize => sizes.fold(0, (a, b) => a + b);
}

/// Packs one folder: files through the compressor, and through AES when
/// encrypting, into the sink.
class _FolderWriter {
  _FolderWriter(this.writer, this.method) {
    final password = writer.password;
    if (password != null) {
      _iv = writer._iv();
      _cbc = AesCbcEncryptor(Aes(writer._aesKey), _iv!);
    }
    _encoder = switch (method) {
      SevenZMethod.copy => PlainEncoder(_coded),
      SevenZMethod.deflate => ZlibEncoder(_coded, level: writer.deflateLevel),
      SevenZMethod.lzma2 => _lzma2 = Lzma2BlockEncoder(_coded, blockSize: writer.blockSize),
    };
  }

  final SevenZWriter writer;
  final SevenZMethod method;
  late final ByteEncoder _encoder;
  Lzma2BlockEncoder? _lzma2;
  Uint8List? _iv;
  AesCbcEncryptor? _cbc;
  final _pending = Uint8List(16);
  var _pendingLength = 0;
  var _coderOut = 0;
  var _packSize = 0;
  final _sizes = <int>[];
  final _crcs = <int>[];
  var unpacked = 0;

  /// The compressor's output: to the sink, through AES a block at a time.
  void _coded(List<int> bytes) {
    _coderOut += bytes.length;
    final cbc = _cbc;
    if (cbc == null) {
      writer.sink.add(bytes);
      _packSize += bytes.length;
      return;
    }
    var at = 0;
    if (_pendingLength > 0) {
      final take = math.min(16 - _pendingLength, bytes.length);
      _pending.setRange(_pendingLength, _pendingLength + take, bytes);
      _pendingLength += take;
      at = take;
      if (_pendingLength < 16) return;
      cbc.encryptInPlace(_pending);
      writer.sink.add(_pending);
      _packSize += 16;
      _pendingLength = 0;
    }
    final whole = (bytes.length - at) ~/ 16 * 16;
    if (whole > 0) {
      final chunk = Uint8List.fromList(bytes.sublist(at, at + whole));
      cbc.encryptInPlace(chunk);
      writer.sink.add(chunk);
      _packSize += whole;
      at += whole;
    }
    final rest = bytes.length - at;
    if (rest > 0) {
      _pending.setRange(0, rest, bytes, at);
      _pendingLength = rest;
    }
  }

  void addFile(ArchiveItem item, RandomAccessFile input, {ReadProgress? onRead, ShouldStop? stop}) {
    var crc = 0;
    var read = 0;
    readChunks(input, (chunk, length) {
      final take = math.min(length, item.size - read);
      if (take > 0) {
        final view = Uint8List.sublistView(chunk, 0, take);
        crc = getCrc32(view, crc);
        _encoder.add(view);
        read += take;
      }
      onRead?.call(length);
    }, stop: stop);
    // A file that shrank meanwhile: zeros up to its listed size, so the
    // header's size stays true.
    if (read < item.size) {
      final zeros = Uint8List(item.size - read);
      crc = getCrc32(zeros, crc);
      _encoder.add(zeros);
    }
    _sizes.add(item.size);
    _crcs.add(crc);
    unpacked += item.size;
  }

  _Folder finish() {
    _encoder.close();
    final coderOut = _coderOut;
    final cbc = _cbc;
    if (cbc != null && _pendingLength > 0) {
      _pending.fillRange(_pendingLength, 16, 0);
      cbc.encryptInPlace(_pending);
      writer.sink.add(_pending);
      _packSize += 16;
      _pendingLength = 0;
    }
    final lzma2 = _lzma2;
    return _Folder(
      coderId: switch (method) {
        SevenZMethod.copy => SevenZWriter._copyId,
        SevenZMethod.deflate => SevenZWriter._deflateId,
        SevenZMethod.lzma2 => SevenZWriter._lzma2Id,
      },
      props: lzma2 == null ? null : Uint8List.fromList([lzma2.dictProp]),
      aesProps: _iv == null ? null : SevenZWriter._aesProps(_iv!),
      packSize: _packSize,
      coderOut: coderOut,
      sizes: _sizes,
      crcs: _crcs,
    );
  }
}

/// Bytes for 7z's header structures.
class _Buffer {
  final _b = BytesBuilder();

  void byte(int b) => _b.addByte(b);
  void bytes(List<int> data) => _b.add(data);
  Uint8List take() => _b.takeBytes();
  int get length => _b.length;

  void u16(int v) => _b
    ..addByte(v & 0xFF)
    ..addByte((v >> 8) & 0xFF);

  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      _b.addByte((v >> (8 * i)) & 0xFF);
    }
  }

  void u64(int v) {
    for (var i = 0; i < 8; i++) {
      _b.addByte((v >> (8 * i)) & 0xFF);
    }
  }

  /// 7z's number: as many leading 1 bits in the first byte as bytes follow.
  void number(int value) {
    var first = 0;
    var mask = 0x80;
    final extra = <int>[];
    var v = value;
    for (var i = 0; i < 8; i++) {
      if (v < (1 << (7 - i))) {
        _b.addByte(first | v);
        _b.add(extra);
        return;
      }
      first |= mask;
      mask >>= 1;
      extra.add(v & 0xFF);
      v >>= 8;
    }
    _b
      ..addByte(0xFF)
      ..add(extra);
  }

  /// A bit vector, the first bit the highest.
  void bits(List<bool> values) {
    var b = 0;
    var mask = 0x80;
    for (final value in values) {
      if (value) b |= mask;
      mask >>= 1;
      if (mask == 0) {
        _b.addByte(b);
        b = 0;
        mask = 0x80;
      }
    }
    if (mask != 0x80) _b.addByte(b);
  }

  /// Windows' FILETIME: 100 ns steps since 1601, UTC.
  void fileTime(DateTime when) => u64((when.millisecondsSinceEpoch + 11644473600000) * 10000);

  void property(int id, _Buffer payload) {
    final data = payload.take();
    number(id);
    number(data.length);
    _b.add(data);
  }
}
