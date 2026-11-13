import 'dart:convert';
import 'dart:typed_data';

import 'package:folders/core/services/compress/stream_codecs.dart';
import 'package:folders/core/services/compress/zip_writer.dart' show ReadProgress, ShouldStop, openInput, readChunks;

/// Writes a tar (POSIX ustar) into [out], a compressor or the file itself:
/// folders and files with their modified times and plain permissions, and a
/// PAX record for what ustar can't hold (a long or non-ASCII name, a size
/// past 8 GB, the time to the millisecond), as GNU tar and bsdtar read.
class TarWriter {
  TarWriter(this.out);

  final ByteEncoder out;

  static const _block = 512;

  void addFolder(String name, DateTime modified) =>
      _header(name.endsWith('/') ? name : '$name/', 0, modified, type: 0x35, mode: 0x1ED); // 0755

  void addFile(String name, String file, int size, DateTime modified, {ReadProgress? onRead, ShouldStop? stop}) {
    final input = openInput(file);
    _header(name, size, modified, type: 0x30, mode: 0x1A4); // 0644
    var read = 0;
    readChunks(input, (chunk, length) {
      // A file that grew meanwhile: only what the header says.
      final take = length < size - read ? length : size - read;
      if (take > 0) out.add(chunk, 0, take);
      read += take;
      onRead?.call(length);
    }, stop: stop);
    // A file that shrank meanwhile: filled up to the size given.
    if (read < size) out.add(Uint8List(size - read));
    final padding = (_block - size % _block) % _block;
    if (padding > 0) out.add(Uint8List(padding));
  }

  /// Two empty blocks end a tar.
  void close() {
    out
      ..add(Uint8List(_block * 2))
      ..close();
  }

  void _header(String name, int size, DateTime modified, {required int type, required int mode}) {
    final nameBytes = utf8.encode(name);
    final seconds = modified.millisecondsSinceEpoch ~/ 1000;
    final plain = nameBytes.length == name.length;
    final split = plain ? _splitName(name) : null;
    final bigSize = size > 0x1FFFFFFFF; // 11 octal digits
    final pax = <String, String>{
      if (split == null) 'path': name,
      if (bigSize) 'size': '$size',
      if (modified.millisecond != 0 || seconds < 0) 'mtime': (modified.millisecondsSinceEpoch / 1000).toStringAsFixed(3),
    };
    if (pax.isNotEmpty) {
      final records = BytesBuilder();
      pax.forEach((key, value) => records.add(_paxRecord(key, value)));
      final body = records.toBytes();
      out.add(_block512(
        _shortName('PaxHeaders/$name'),
        '',
        body.length,
        seconds,
        type: 0x78, // 'x'
        mode: 0x1A4,
      ));
      out.add(body);
      final padding = (_block - body.length % _block) % _block;
      if (padding > 0) out.add(Uint8List(padding));
    }
    final (prefix, rest) = split ?? ('', _shortName(name));
    out.add(_block512(rest, prefix, bigSize ? 0 : size, seconds < 0 ? 0 : seconds, type: type, mode: mode));
  }

  /// "len key=value\n", where len counts itself.
  static Uint8List _paxRecord(String key, String value) {
    final body = utf8.encode(' $key=$value\n');
    var length = body.length + 1;
    while ('$length'.length + body.length != length) {
      length = '$length'.length + body.length;
    }
    return Uint8List.fromList([...ascii.encode('$length'), ...body]);
  }

  /// ustar's name (100 bytes) and prefix (155): [name] split at a slash, or
  /// null when it doesn't fit.
  static (String, String)? _splitName(String name) {
    if (name.length <= 100) return ('', name);
    for (var i = name.length - 101; i < name.length && i <= 155; i++) {
      if (i > 0 && name.codeUnitAt(i) == 0x2F && name.length - i - 1 <= 100) {
        return (name.substring(0, i), name.substring(i + 1));
      }
    }
    return null;
  }

  /// A stand-in for a name only PAX can hold: ASCII, as long as fits.
  static String _shortName(String name) {
    final safe = String.fromCharCodes(name.codeUnits.map((c) => c < 0x20 || c > 0x7E ? 0x5F : c));
    return safe.length <= 100 ? safe : safe.substring(safe.length - 100);
  }

  static Uint8List _block512(String name, String prefix, int size, int seconds, {required int type, required int mode}) {
    final block = Uint8List(_block);
    void text(int at, int length, String value) {
      final bytes = ascii.encode(value);
      block.setRange(at, at + (bytes.length < length ? bytes.length : length), bytes);
    }

    void octal(int at, int length, int value) => text(at, length - 1, value.toRadixString(8).padLeft(length - 1, '0'));

    text(0, 100, name);
    octal(100, 8, mode);
    octal(108, 8, 0);
    octal(116, 8, 0);
    octal(124, 12, size);
    octal(136, 12, seconds);
    block.fillRange(148, 156, 0x20); // The checksum counts as spaces.
    block[156] = type;
    text(257, 6, 'ustar');
    text(263, 2, '00');
    text(345, 155, prefix);
    var sum = 0;
    for (final byte in block) {
      sum += byte;
    }
    text(148, 7, sum.toRadixString(8).padLeft(6, '0'));
    block[154] = 0;
    block[155] = 0x20;
    return block;
  }
}
