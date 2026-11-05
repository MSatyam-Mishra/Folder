import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:folder/core/formats/zstd_decoder.dart';

/// A Blender .blend file: its data blocks and SDNA (the struct definitions
/// written into every file), read without Blender.
///
/// Handles every Blender version's layout: 4- and 8-byte pointers, either
/// byte order, the large block headers of Blender 5, and gzip (Blender 2.x)
/// or zstd (3.0+) compression.
class BlendFile {
  BlendFile._(
    this.bytes,
    this.pointerSize,
    this.littleEndian,
    this.version,
    this.blocks,
    this.dna,
  ) : _view = ByteData.sublistView(bytes) {
    for (final block in blocks) {
      if (block.address != 0) _byAddress[block.address] = block;
    }
  }

  /// Uncompressed file contents.
  final Uint8List bytes;
  final ByteData _view;
  final int pointerSize;
  final bool littleEndian;

  /// Blender version that saved the file, e.g. 402 for 4.2.
  final int version;
  final List<BlendBlock> blocks;
  final Sdna dna;
  final Map<int, BlendBlock> _byAddress = {};

  Endian get _endian => littleEndian ? Endian.little : Endian.big;

  String get versionLabel => '${version ~/ 100}.${version % 100}';

  /// Whether [bytes] looks like a .blend file (possibly compressed).
  static bool looksLikeBlend(Uint8List bytes) =>
      _startsWith(bytes, 'BLENDER') ||
      (bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) ||
      isZstd(bytes);

  static bool _startsWith(Uint8List bytes, String text) {
    if (bytes.length < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (bytes[i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static BlendFile parse(Uint8List input) {
    var bytes = input;
    if (bytes.length > 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
      bytes = Uint8List.fromList(gzip.decode(bytes));
    } else if (isZstd(bytes)) {
      bytes = zstdDecompress(bytes);
    }
    if (!_startsWith(bytes, 'BLENDER') || bytes.length < 12) {
      throw const FormatException('Not a Blender file');
    }

    // "BLENDER-v402" (12 bytes) or, from Blender 5, "BLENDER17-01v0500".
    final int headerSize, pointerSize, formatVersion, version;
    final bool little;
    final c7 = bytes[7];
    if (c7 == 0x5F || c7 == 0x2D) {
      headerSize = 12;
      pointerSize = c7 == 0x5F ? 4 : 8;
      little = bytes[8] == 0x76; // 'v'
      version = int.parse(ascii.decode(bytes.sublist(9, 12)));
      formatVersion = 0;
    } else {
      headerSize = int.parse(ascii.decode(bytes.sublist(7, 9)));
      pointerSize = bytes[9] == 0x5F ? 4 : 8;
      formatVersion = int.parse(ascii.decode(bytes.sublist(10, 12)));
      little = bytes[12] == 0x76;
      version = int.parse(ascii.decode(bytes.sublist(13, headerSize)));
    }
    final view = ByteData.sublistView(bytes);
    final endian = little ? Endian.little : Endian.big;

    final blocks = <BlendBlock>[];
    var pos = headerSize;
    while (pos + 16 <= bytes.length) {
      final code = _code(bytes, pos);
      int length, address, sdna, count, headerLength;
      if (formatVersion >= 1) {
        // LargeBHead8: code, SDNAnr, old address, len (64-bit), nr (64-bit).
        sdna = view.getInt32(pos + 4, endian);
        address = view.getUint64(pos + 8, endian);
        length = view.getInt64(pos + 16, endian);
        count = view.getInt64(pos + 24, endian);
        headerLength = 32;
      } else if (pointerSize == 8) {
        length = view.getInt32(pos + 4, endian);
        address = view.getUint64(pos + 8, endian);
        sdna = view.getInt32(pos + 16, endian);
        count = view.getInt32(pos + 20, endian);
        headerLength = 24;
      } else {
        length = view.getInt32(pos + 4, endian);
        address = view.getUint32(pos + 8, endian);
        sdna = view.getInt32(pos + 12, endian);
        count = view.getInt32(pos + 16, endian);
        headerLength = 20;
      }
      if (code == 'ENDB') break;
      final start = pos + headerLength;
      if (length < 0 || start + length > bytes.length) {
        throw const FormatException('Damaged Blender file');
      }
      blocks.add(BlendBlock(code, start, length, address, sdna, count));
      pos = start + length;
    }

    final dnaBlock = blocks.where((b) => b.code == 'DNA1').firstOrNull;
    if (dnaBlock == null) throw const FormatException('No SDNA in file');
    final dna = Sdna._parse(bytes, dnaBlock, endian, pointerSize);
    return BlendFile._(bytes, pointerSize, little, version, blocks, dna);
  }

  static String _code(Uint8List bytes, int pos) {
    final chars = <int>[];
    for (var i = 0; i < 4; i++) {
      final c = bytes[pos + i];
      if (c == 0) break;
      chars.add(c);
    }
    return String.fromCharCodes(chars);
  }

  /// The block a pointer (saved memory address) points into, if any.
  BlendBlock? blockAt(int address) => address == 0 ? null : _byAddress[address];

  /// The struct stored at the start of [block], typed by its SDNA index.
  BlendStruct? structOf(BlendBlock block, [int index = 0]) {
    if (block.sdna < 0 || block.sdna >= dna.structs.length) return null;
    final type = dna.structs[block.sdna];
    final offset = block.offset + index * type.size;
    if (offset + type.size > block.offset + block.length) return null;
    return BlendStruct(this, type, offset);
  }

  /// [block] read as a struct of [typeName] (when its SDNA index says
  /// something generic, like "Link").
  BlendStruct? structAs(BlendBlock block, String typeName, [int index = 0]) {
    final type = dna.byName[typeName];
    if (type == null) return null;
    final offset = block.offset + index * type.size;
    if (offset + type.size > block.offset + block.length) return null;
    return BlendStruct(this, type, offset);
  }

  int readPointer(int offset) => pointerSize == 8
      ? _view.getUint64(offset, _endian)
      : _view.getUint32(offset, _endian);

  int readInt32(int offset) => _view.getInt32(offset, _endian);
  int readUint32(int offset) => _view.getUint32(offset, _endian);
  int readInt16(int offset) => _view.getInt16(offset, _endian);
  double readFloat(int offset) => _view.getFloat32(offset, _endian);
  double readDouble(int offset) => _view.getFloat64(offset, _endian);

  /// Floats of a data block (e.g. a vertex position array).
  Float32List floats(BlendBlock block) {
    final n = block.length ~/ 4;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = readFloat(block.offset + i * 4);
    }
    return out;
  }

  Int32List ints(BlendBlock block) {
    final n = block.length ~/ 4;
    final out = Int32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = readInt32(block.offset + i * 4);
    }
    return out;
  }

  /// The preview image Blender saves into the file (RGBA, top row first),
  /// or null when there is none.
  ({int width, int height, Uint8List rgba})? thumbnail() {
    final block = blocks.where((b) => b.code == 'TEST').firstOrNull;
    if (block == null || block.length < 8) return null;
    final width = readInt32(block.offset);
    final height = readInt32(block.offset + 4);
    if (width <= 0 || height <= 0 || 8 + width * height * 4 > block.length) {
      return null;
    }
    // Stored bottom row first, like Blender's image buffers.
    final rgba = Uint8List(width * height * 4);
    final stride = width * 4;
    for (var y = 0; y < height; y++) {
      final from = block.offset + 8 + (height - 1 - y) * stride;
      rgba.setRange(y * stride, (y + 1) * stride, bytes, from);
    }
    return (width: width, height: height, rgba: rgba);
  }
}

/// One file block: a struct (or array) Blender wrote, with the memory
/// address it had, which pointers elsewhere in the file refer to.
class BlendBlock {
  const BlendBlock(
    this.code,
    this.offset,
    this.length,
    this.address,
    this.sdna,
    this.count,
  );

  /// "OB", "ME", "MA", "DATA", …
  final String code;
  final int offset;
  final int length;
  final int address;

  /// Index of the block's struct in [Sdna.structs].
  final int sdna;

  /// Number of structs in the block.
  final int count;
}

/// The struct definitions of a file.
class Sdna {
  Sdna._(this.structs) : byName = {for (final s in structs) s.name: s};

  final List<StructType> structs;
  final Map<String, StructType> byName;

  static Sdna _parse(
    Uint8List bytes,
    BlendBlock block,
    Endian endian,
    int pointerSize,
  ) {
    final view = ByteData.sublistView(bytes);
    var pos = block.offset;
    final end = block.offset + block.length;

    String tag() {
      final t = ascii.decode(bytes.sublist(pos, pos + 4));
      pos += 4;
      return t;
    }

    void align() => pos = block.offset + ((pos - block.offset + 3) & ~3);

    List<String> strings(int n) {
      final out = <String>[];
      for (var i = 0; i < n; i++) {
        final start = pos;
        while (pos < end && bytes[pos] != 0) {
          pos++;
        }
        out.add(latin1.decode(bytes.sublist(start, pos)));
        pos++;
      }
      return out;
    }

    if (tag() != 'SDNA' || tag() != 'NAME') {
      throw const FormatException('Bad SDNA');
    }
    final names = strings(view.getInt32(pos, endian).also((_) => pos += 4));
    align();
    if (tag() != 'TYPE') throw const FormatException('Bad SDNA types');
    final types = strings(view.getInt32(pos, endian).also((_) => pos += 4));
    align();
    if (tag() != 'TLEN') throw const FormatException('Bad SDNA lengths');
    final lengths = [
      for (var i = 0; i < types.length; i++) view.getInt16(pos + i * 2, endian),
    ];
    pos += types.length * 2;
    align();
    if (tag() != 'STRC') throw const FormatException('Bad SDNA structs');
    final count = view.getInt32(pos, endian);
    pos += 4;
    final structs = <StructType>[];
    for (var s = 0; s < count; s++) {
      final type = view.getInt16(pos, endian);
      final fieldCount = view.getInt16(pos + 2, endian);
      pos += 4;
      final fields = <String, Field>{};
      var offset = 0;
      for (var f = 0; f < fieldCount; f++) {
        final fieldType = view.getInt16(pos, endian);
        final name = names[view.getInt16(pos + 2, endian)];
        pos += 4;
        final field = Field.parse(
          types[fieldType],
          name,
          offset,
          lengths[fieldType],
          pointerSize,
        );
        fields.putIfAbsent(field.name, () => field);
        offset += field.size;
      }
      structs.add(StructType(types[type], lengths[type], fields));
    }
    return Sdna._(structs);
  }
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

class StructType {
  const StructType(this.name, this.size, this.fields);
  final String name;
  final int size;
  final Map<String, Field> fields;
}

class Field {
  const Field(
    this.type,
    this.name,
    this.offset,
    this.size,
    this.isPointer,
    this.dims,
  );

  /// "*next" → name "next", pointer; "co[3]" → name "co", dims [3].
  factory Field.parse(
    String type,
    String raw,
    int offset,
    int typeSize,
    int pointerSize,
  ) {
    final isPointer = raw.contains('*');
    final base = raw
        .replaceAll(RegExp(r'[*()]'), '')
        .replaceAll(RegExp(r'\[.*$'), '');
    final dims = [
      for (final m in RegExp(r'\[(\d+)\]').allMatches(raw)) int.parse(m[1]!),
    ];
    final count = dims.fold(1, (a, b) => a * b);
    // Function pointers "(*func)()" are a single pointer.
    final size = (isPointer ? pointerSize : typeSize) * count;
    return Field(type, base, offset, size, isPointer, dims);
  }

  final String type;
  final String name;
  final int offset;
  final int size;
  final bool isPointer;
  final List<int> dims;
}

/// A struct instance in the file.
class BlendStruct {
  const BlendStruct(this.file, this.type, this.offset);

  final BlendFile file;
  final StructType type;
  final int offset;

  bool has(String field) => type.fields.containsKey(field);

  Field? _field(String name) => type.fields[name];

  /// The first of [names] the struct has (fields renamed between versions).
  String? pick(List<String> names) {
    for (final n in names) {
      if (has(n)) return n;
    }
    return null;
  }

  int pointer(String name) {
    final f = _field(name);
    if (f == null || !f.isPointer) return 0;
    return file.readPointer(offset + f.offset);
  }

  /// An integer field of any width; 0 when missing.
  int integer(String name, [int index = 0]) {
    final f = _field(name);
    if (f == null || f.isPointer) return 0;
    final at = offset + f.offset;
    return switch (f.type) {
      'char' ||
      'uchar' ||
      'int8_t' ||
      'uint8_t' ||
      'bool' => file.bytes[at + index],
      'short' || 'int16_t' => file.readInt16(at + index * 2),
      'ushort' || 'uint16_t' => file.readInt16(at + index * 2) & 0xFFFF,
      'int' || 'int32_t' => file.readInt32(at + index * 4),
      'uint' || 'uint32_t' => file.readUint32(at + index * 4),
      _ => 0,
    };
  }

  double float(String name, [int index = 0]) {
    final f = _field(name);
    if (f == null) return 0;
    final at = offset + f.offset;
    return switch (f.type) {
      'float' => file.readFloat(at + index * 4),
      'double' => file.readDouble(at + index * 8),
      _ => integer(name, index).toDouble(),
    };
  }

  /// All floats of an array field (e.g. "co[3]", "obmat[4][4]").
  List<double>? floats(String name) {
    final f = _field(name);
    if (f == null || f.type != 'float') return null;
    final n = f.size ~/ 4;
    return [
      for (var i = 0; i < n; i++) file.readFloat(offset + f.offset + i * 4),
    ];
  }

  String string(String name) {
    final f = _field(name);
    if (f == null) return '';
    final start = offset + f.offset;
    var end = start;
    while (end < start + f.size && file.bytes[end] != 0) {
      end++;
    }
    return utf8.decode(file.bytes.sublist(start, end), allowMalformed: true);
  }

  /// An embedded struct field (e.g. "id", "vdata").
  BlendStruct? embedded(String name) {
    final f = _field(name);
    final type = f == null ? null : file.dna.byName[f.type];
    if (f == null || type == null || f.isPointer) return null;
    return BlendStruct(file, type, offset + f.offset);
  }

  /// The struct a pointer field points at, typed by its block (or as
  /// [asType] when given).
  BlendStruct? follow(String name, {String? asType}) {
    final block = file.blockAt(pointer(name));
    if (block == null) return null;
    return asType == null ? file.structOf(block) : file.structAs(block, asType);
  }
}
