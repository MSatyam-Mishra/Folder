import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show BZip2Encoder, getCrc32;
import 'package:koni_codecs/koni_codecs.dart';

/// Takes bytes in and hands compressed bytes to its output as they come.
abstract class ByteEncoder {
  void add(Uint8List bytes, [int start = 0, int? end]);

  /// Whatever is still held, and the stream's end.
  void close();
}

/// No compression: bytes straight through.
class PlainEncoder implements ByteEncoder {
  PlainEncoder(this.output);

  final void Function(List<int> bytes) output;

  @override
  void add(Uint8List bytes, [int start = 0, int? end]) =>
      output(Uint8List.sublistView(bytes, start, end ?? bytes.length));

  @override
  void close() {}
}

/// Gzip or raw Deflate through the system's zlib.
class ZlibEncoder implements ByteEncoder {
  ZlibEncoder(this.output, {required int level, bool gzip = false})
      : _filter = RawZLibFilter.deflateFilter(level: level, raw: !gzip, gzip: gzip);

  final void Function(List<int> bytes) output;
  final RawZLibFilter _filter;

  @override
  void add(Uint8List bytes, [int start = 0, int? end]) {
    _filter.process(bytes, start, end ?? bytes.length);
    for (List<int>? out; (out = _filter.processed(flush: false)) != null;) {
      output(out!);
    }
  }

  @override
  void close() {
    _filter.process(const [], 0, 0);
    for (List<int>? out; (out = _filter.processed(end: true)) != null;) {
      output(out!);
    }
  }
}

/// Collects bytes into blocks of [blockSize] and hands each whole block on.
abstract class BlockEncoder implements ByteEncoder {
  BlockEncoder(this.blockSize) : _block = Uint8List(blockSize);

  final int blockSize;
  final Uint8List _block;
  var _filled = 0;

  @override
  void add(Uint8List bytes, [int start = 0, int? end]) {
    final stop = end ?? bytes.length;
    var at = start;
    while (at < stop) {
      final take = math.min(stop - at, blockSize - _filled);
      _block.setRange(_filled, _filled + take, bytes, at);
      _filled += take;
      at += take;
      if (_filled == blockSize) {
        encodeBlock(_block);
        _filled = 0;
      }
    }
  }

  /// Encodes a whole block; [block] is reused once this returns.
  void encodeBlock(Uint8List block);

  /// Ends the stream after the last block.
  void finish();

  @override
  void close() {
    if (_filled > 0) encodeBlock(Uint8List.sublistView(_block, 0, _filled));
    _filled = 0;
    finish();
  }
}

/// LZMA2 a block at a time: each block is its own LZMA2 run, starting with a
/// fresh dictionary, so memory stays bounded however much goes in, and the
/// runs join into one valid stream (the 0x00 that ends each is dropped, and
/// one ends the whole). A block that a quick look finds incompressible (a
/// video, say) is written as LZMA2's uncompressed chunks instead of being
/// searched for matches that aren't there, which in Dart is slow.
class Lzma2BlockEncoder extends BlockEncoder {
  Lzma2BlockEncoder(this.output, {required int blockSize}) : super(blockSize);

  final void Function(List<int> bytes) output;

  /// The dictionary decoders are told about: the block, as nothing reaches
  /// further back than its start.
  int get dictSize => math.max(blockSize, 1 << 12);

  /// The 7z and xz property byte for [dictSize].
  int get dictProp => Lzma2Encoder(dictSize: dictSize, chunkSize: math.min(dictSize, (1 << 21) - 273)).dictSizeProp;

  @override
  void encodeBlock(Uint8List block) {
    if (looksIncompressible(block)) {
      writeStored(block, output);
      return;
    }
    final encoded = Lzma2Encoder(dictSize: dictSize).encode(block);
    output(Uint8List.sublistView(encoded, 0, encoded.length - 1));
  }

  @override
  void finish() => output(const [0]);

  /// LZMA2's uncompressed chunks for [block], the first resetting the
  /// dictionary.
  static void writeStored(Uint8List block, void Function(List<int> bytes) output) {
    var at = 0;
    var control = 1;
    while (at < block.length) {
      final take = math.min(block.length - at, 1 << 16);
      output([control, (take - 1) >> 8, (take - 1) & 0xFF]);
      output(Uint8List.sublistView(block, at, at + take));
      at += take;
      control = 2;
    }
  }

  /// Whether zlib's fastest level can't shrink a sample of [block] by 3%.
  static bool looksIncompressible(Uint8List block) {
    if (block.length < 4096) return false;
    const sample = 64 * 1024;
    final probes = block.length <= sample * 2
        ? [Uint8List.sublistView(block)]
        : [
            Uint8List.sublistView(block, 0, sample),
            Uint8List.sublistView(block, block.length ~/ 2, block.length ~/ 2 + sample),
          ];
    for (final probe in probes) {
      final packed = ZLibCodec(level: 1, raw: true).encode(probe).length;
      if (packed < probe.length * 0.97) return false;
    }
    return true;
  }
}

/// bzip2: each block of input becomes a bzip2 stream of its own, one after
/// another, which bzip2, Python, 7-Zip and this app's reader all read as one
/// (pbzip2 writes them so too).
/// Always bzip2's level 9 (900 KB blocks): the encoder has no other.
class Bzip2Encoder extends BlockEncoder {
  Bzip2Encoder(this.output) : super(8 << 20);

  final void Function(List<int> bytes) output;

  @override
  void encodeBlock(Uint8List block) => output(BZip2Encoder().encode(block));

  @override
  void finish() {}
}

/// xz: the stream header, blocks of LZMA2 each with its CRC-32, the index
/// and the footer, as xz-utils writes them.
class XzEncoder implements ByteEncoder {
  XzEncoder(this.output, {required int blockSize}) : _blocks = _XzBlocks(blockSize) {
    _blocks.onBlock = _writeBlock;
    output(_streamHeader);
  }

  final void Function(List<int> bytes) output;
  final _XzBlocks _blocks;
  final _records = <(int, int)>[];

  /// Stream flags: CRC-32 checks.
  static const _flags = [0x00, 0x01];

  static final _streamHeader = Uint8List.fromList([
    0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, ..._flags, ..._le32(getCrc32(_flags)),
  ]);

  static List<int> _le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  void _writeBlock(Uint8List block) {
    final packed = BytesBuilder(copy: false);
    final encoder = Lzma2BlockEncoder(packed.add, blockSize: _blocks.blockSize);
    encoder.encodeBlock(block);
    encoder.finish();
    final data = packed.takeBytes();
    // Block header: its size, flags (one filter, no sizes), LZMA2 with its
    // dictionary, padding, CRC-32.
    final header = <int>[0, 0x00, 0x21, 0x01, encoder.dictProp];
    while ((header.length + 4) % 4 != 0) {
      header.add(0);
    }
    header[0] = (header.length + 4) ~/ 4 - 1;
    final headerBytes = Uint8List.fromList(header);
    output(headerBytes);
    output(_le32(getCrc32(headerBytes)));
    output(data);
    final padding = (4 - data.length % 4) % 4;
    if (padding > 0) output(Uint8List(padding));
    output(_le32(getCrc32(block)));
    _records.add((headerBytes.length + 4 + data.length + 4, block.length));
  }

  @override
  void add(Uint8List bytes, [int start = 0, int? end]) => _blocks.add(bytes, start, end);

  @override
  void close() {
    _blocks.close();
    final index = <int>[0x00, ..._varint(_records.length)];
    for (final (unpadded, size) in _records) {
      index
        ..addAll(_varint(unpadded))
        ..addAll(_varint(size));
    }
    while (index.length % 4 != 0) {
      index.add(0);
    }
    final indexBytes = Uint8List.fromList(index);
    output(indexBytes);
    output(_le32(getCrc32(indexBytes)));
    final backward = (indexBytes.length + 4) ~/ 4 - 1;
    final footer = Uint8List.fromList([..._le32(backward), ..._flags]);
    output(_le32(getCrc32(footer)));
    output(footer);
    output(const [0x59, 0x5A]);
  }
}

class _XzBlocks extends BlockEncoder {
  _XzBlocks(super.blockSize);

  late void Function(Uint8List block) onBlock;

  @override
  void encodeBlock(Uint8List block) => onBlock(block);

  @override
  void finish() {}
}
