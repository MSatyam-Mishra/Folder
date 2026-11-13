import 'dart:convert';
import 'dart:typed_data';

/// A tag as Finder keeps it: a name and one of its colours, 0 for none, then
/// 1 grey, 2 green, 3 purple, 4 blue, 5 yellow, 6 red, 7 orange.
class FinderTag {
  const FinderTag(this.name, [this.color = 0]);

  final String name;
  final int color;

  /// "Red\n6", as it's written in the list; no colour leaves the number out.
  String get encoded => color == 0 ? name : '$name\n$color';

  static FinderTag decode(String text) {
    final cut = text.lastIndexOf('\n');
    if (cut < 0) return FinderTag(text);
    final color = int.tryParse(text.substring(cut + 1));
    return color == null || color < 0 || color > 7 ? FinderTag(text.replaceAll('\n', ' ')) : FinderTag(text.substring(0, cut), color);
  }

  @override
  bool operator ==(Object other) => other is FinderTag && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(name, color);

  @override
  String toString() => 'FinderTag($name, $color)';
}

/// Finder's tags, as macOS stores them beside a file in the extended attribute
/// `com.apple.metadata:_kMDItemUserTags`: a binary property list ("bplist00")
/// holding an array of strings. Only that shape is written and read here,
/// laid out byte for byte as Python's plistlib writes it.
abstract final class FinderTagsPlist {
  static const attribute = 'com.apple.metadata:_kMDItemUserTags';

  static Uint8List encode(List<FinderTag> tags) => encodeStrings([for (final t in tags) t.encoded]);

  /// The tags in [bytes]; null when it isn't such a list.
  static List<FinderTag>? decode(List<int> bytes) {
    final strings = decodeStrings(bytes);
    return strings == null ? null : [for (final s in strings) FinderTag.decode(s)];
  }

  /// A binary plist of one array of [strings].
  static Uint8List encodeStrings(List<String> strings) {
    // Objects: the array, then each different string once.
    final unique = <String>[];
    final refOf = <String, int>{};
    for (final s in strings) {
      refOf.putIfAbsent(s, () {
        unique.add(s);
        return unique.length; // The array is object 0.
      });
    }
    final count = unique.length + 1;
    final refSize = _sizeFor(count);
    final out = BytesBuilder();
    out.add(ascii.encode('bplist00'));
    final offsets = <int>[];

    offsets.add(out.length);
    _writeSize(out, 0xA0, strings.length);
    for (final s in strings) {
      _writeInt(out, refOf[s]!, refSize);
    }
    for (final s in unique) {
      offsets.add(out.length);
      final isAscii = s.codeUnits.every((c) => c < 0x80);
      if (isAscii) {
        _writeSize(out, 0x50, s.length);
        out.add(s.codeUnits);
      } else {
        _writeSize(out, 0x60, s.length);
        for (final unit in s.codeUnits) {
          out.add([unit >> 8, unit & 0xFF]);
        }
      }
    }

    final tableAt = out.length;
    final offsetSize = _sizeFor(tableAt);
    for (final offset in offsets) {
      _writeInt(out, offset, offsetSize);
    }
    // Trailer: 5 unused bytes, sort version, offset size, ref size, then the
    // object count, the top object and where the offset table is.
    out.add(List.filled(5, 0));
    out.add([0, offsetSize, refSize]);
    _writeInt(out, count, 8);
    _writeInt(out, 0, 8);
    _writeInt(out, tableAt, 8);
    return out.toBytes();
  }

  /// The strings of a binary plist holding an array of strings; null for
  /// anything else, or for broken data.
  static List<String>? decodeStrings(List<int> data) {
    try {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      if (bytes.length < 8 + 32 || ascii.decode(bytes.sublist(0, 6), allowInvalid: true) != 'bplist') return null;
      final trailer = bytes.length - 32;
      final offsetSize = bytes[trailer + 6];
      final refSize = bytes[trailer + 7];
      final count = _readInt(bytes, trailer + 8, 8);
      final top = _readInt(bytes, trailer + 16, 8);
      final tableAt = _readInt(bytes, trailer + 24, 8);
      if (offsetSize < 1 || offsetSize > 8 || refSize < 1 || refSize > 8 || top >= count) return null;
      if (tableAt + count * offsetSize > trailer) return null;
      int offsetOf(int ref) {
        if (ref >= count) throw const FormatException('ref');
        final at = _readInt(bytes, tableAt + ref * offsetSize, offsetSize);
        if (at >= tableAt) throw const FormatException('offset');
        return at;
      }

      final arrayAt = offsetOf(top);
      final (kind, length, start) = _readHeader(bytes, arrayAt);
      if (kind != 0xA0) return null;
      final strings = <String>[];
      for (var i = 0; i < length; i++) {
        final at = offsetOf(_readInt(bytes, start + i * refSize, refSize));
        final (type, size, from) = _readHeader(bytes, at);
        switch (type) {
          case 0x50:
            strings.add(String.fromCharCodes(bytes.sublist(from, from + size)));
          case 0x60:
            strings.add(String.fromCharCodes([
              for (var j = 0; j < size; j++) bytes[from + 2 * j] << 8 | bytes[from + 2 * j + 1],
            ]));
          case 0x70:
            strings.add(utf8.decode(bytes.sublist(from, from + size)));
          default:
            return null;
        }
      }
      return strings;
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// An object's kind (its marker's high half), its length and where its
  /// content starts.
  static (int, int, int) _readHeader(Uint8List bytes, int at) {
    final marker = bytes[at];
    final kind = marker & 0xF0;
    var length = marker & 0x0F;
    var start = at + 1;
    if (length == 0x0F) {
      final intMarker = bytes[start];
      if (intMarker & 0xF0 != 0x10) throw const FormatException('length');
      final size = 1 << (intMarker & 0x0F);
      length = _readInt(bytes, start + 1, size);
      start += 1 + size;
    }
    return (kind, length, start);
  }

  static int _sizeFor(int value) => value < 1 << 8
      ? 1
      : value < 1 << 16
          ? 2
          : value < 1 << 32
              ? 4
              : 8;

  static void _writeSize(BytesBuilder out, int token, int size) {
    if (size < 15) {
      out.addByte(token | size);
      return;
    }
    out.addByte(token | 0x0F);
    final bytes = _sizeFor(size);
    out.addByte(0x10 | const {1: 0, 2: 1, 4: 2, 8: 3}[bytes]!);
    _writeInt(out, size, bytes);
  }

  static void _writeInt(BytesBuilder out, int value, int bytes) {
    for (var i = bytes - 1; i >= 0; i--) {
      out.addByte((value >> (8 * i)) & 0xFF);
    }
  }

  static int _readInt(Uint8List bytes, int at, int size) {
    var value = 0;
    for (var i = 0; i < size; i++) {
      value = value << 8 | bytes[at + i];
    }
    return value;
  }
}
