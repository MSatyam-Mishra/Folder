import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// The cover picture of a song: the one inside the file (MP3's ID3 tag,
/// FLAC's picture block, an M4A's `covr`), else a cover image beside it
/// (cover.jpg, folder.jpg...).
abstract final class AudioCover {
  /// Pictures bigger than this aren't read.
  static const _maxPicture = 16 << 20;

  static Future<Uint8List?> find(String path) async {
    try {
      final inside = await embedded(path);
      if (inside != null) return inside;
    } on FileSystemException {
      // Not readable: maybe there's an image beside it.
    } on RangeError {
      // A broken tag.
    }
    final beside = await besideIn(p.dirname(path));
    return beside?.readAsBytes();
  }

  /// The picture stored in the file, if any.
  static Future<Uint8List?> embedded(String path) async {
    final file = await File(path).open();
    try {
      final head = await file.read(12);
      if (head.length < 12) return null;
      // Awaited here: the file closes once they're done.
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) return await _id3(file, head);
      if (head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43) return await _flac(file);
      if (head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70) return await _mp4(file);
      return null;
    } finally {
      await file.close();
    }
  }

  static const _besideNames = {'cover', 'folder', 'front', 'albumart', 'album'};
  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};

  /// A cover image in [folder], as music folders often have.
  static Future<File?> besideIn(String folder) async {
    try {
      var seen = 0;
      await for (final entity in Directory(folder).list(followLinks: false)) {
        if (++seen > 2000) break;
        if (entity is! File) continue;
        final name = p.basenameWithoutExtension(entity.path).toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
        if (_imageExtensions.contains(p.extension(entity.path).toLowerCase()) &&
            (_besideNames.contains(name) || name.startsWith('albumart'))) {
          return entity;
        }
      }
    } on FileSystemException {
      // The folder can't be listed.
    }
    return null;
  }

  // ID3v2: a header, then frames; the picture is in APIC.
  static Future<Uint8List?> _id3(RandomAccessFile file, Uint8List head) async {
    final version = head[3];
    if (version < 3 || version > 4) return null; // v2.2's PIC is rare.
    final flags = head[5];
    if (flags & 0x80 != 0 && version == 3) return null; // whole-tag unsynchronisation
    final size = _syncsafe(head, 6);
    if (size <= 0 || size > _maxPicture * 2) return null;
    await file.setPosition(10);
    final tag = await file.read(size);
    var at = 0;
    if (flags & 0x40 != 0) {
      // An extended header.
      at = version == 4 ? _syncsafe(tag, 0) : _int32(tag, 0) + 4;
    }
    while (at + 10 <= tag.length) {
      final id = String.fromCharCodes(tag.sublist(at, at + 4));
      if (id.codeUnitAt(0) == 0) break; // padding
      final frameSize = version == 4 ? _syncsafe(tag, at + 4) : _int32(tag, at + 4);
      final body = at + 10;
      if (frameSize <= 0 || body + frameSize > tag.length) break;
      if (id == 'APIC') return _apic(Uint8List.sublistView(tag, body, body + frameSize));
      at = body + frameSize;
    }
    return null;
  }

  static Uint8List? _apic(Uint8List frame) {
    if (frame.isEmpty) return null;
    final encoding = frame[0];
    var at = 1;
    while (at < frame.length && frame[at] != 0) {
      at++; // MIME type
    }
    at += 2; // its end, and the picture type
    // The description, ended by one zero byte, or two in UTF-16.
    final wide = encoding == 1 || encoding == 2;
    while (at < frame.length) {
      if (wide) {
        if (at + 1 < frame.length && frame[at] == 0 && frame[at + 1] == 0) {
          at += 2;
          break;
        }
        at += 2;
      } else {
        if (frame[at] == 0) {
          at++;
          break;
        }
        at++;
      }
    }
    if (at >= frame.length) return null;
    return Uint8List.fromList(frame.sublist(at));
  }

  // FLAC: "fLaC", then metadata blocks; type 6 is a picture.
  static Future<Uint8List?> _flac(RandomAccessFile file) async {
    var position = 4;
    for (var i = 0; i < 64; i++) {
      await file.setPosition(position);
      final header = await file.read(4);
      if (header.length < 4) return null;
      final last = header[0] & 0x80 != 0;
      final type = header[0] & 0x7F;
      final length = (header[1] << 16) | (header[2] << 8) | header[3];
      if (type == 6 && length > 32 && length < _maxPicture) {
        final block = await file.read(length);
        var at = 4;
        final mime = _int32(block, at);
        at += 4 + mime;
        final description = _int32(block, at);
        at += 4 + description + 16; // width, height, depth, colours
        final size = _int32(block, at);
        at += 4;
        if (size <= 0 || at + size > block.length) return null;
        return Uint8List.fromList(block.sublist(at, at + size));
      }
      if (last) return null;
      position += 4 + length;
    }
    return null;
  }

  // MP4/M4A: moov › udta › meta › ilst › covr › data.
  static Future<Uint8List?> _mp4(RandomAccessFile file) async {
    final end = await file.length();
    final moov = await _atom(file, 0, end, 'moov');
    if (moov == null) return null;
    final udta = await _atom(file, moov.$1, moov.$2, 'udta');
    if (udta == null) return null;
    final meta = await _atom(file, udta.$1, udta.$2, 'meta');
    if (meta == null) return null;
    // meta has a version and flags before its children.
    final ilst = await _atom(file, meta.$1 + 4, meta.$2, 'ilst');
    if (ilst == null) return null;
    final covr = await _atom(file, ilst.$1, ilst.$2, 'covr');
    if (covr == null) return null;
    final data = await _atom(file, covr.$1, covr.$2, 'data');
    if (data == null) return null;
    final start = data.$1 + 8; // type and locale
    final length = data.$2 - start;
    if (length <= 0 || length > _maxPicture) return null;
    await file.setPosition(start);
    return file.read(length);
  }

  /// The content (start, end) of the first [name] box between [from] and [to].
  static Future<(int, int)?> _atom(RandomAccessFile file, int from, int to, String name) async {
    var at = from;
    while (at + 8 <= to) {
      await file.setPosition(at);
      final header = await file.read(16);
      if (header.length < 8) return null;
      var size = _int32(header, 0);
      final type = String.fromCharCodes(header.sublist(4, 8));
      var headerSize = 8;
      if (size == 1 && header.length >= 16) {
        size = (_int32(header, 8) << 32) | _int32(header, 12);
        headerSize = 16;
      } else if (size == 0) {
        size = to - at;
      }
      if (size < headerSize || at + size > to) return null;
      if (type == name) return (at + headerSize, at + size);
      at += size;
    }
    return null;
  }

  static int _syncsafe(List<int> b, int at) =>
      ((b[at] & 0x7F) << 21) | ((b[at + 1] & 0x7F) << 14) | ((b[at + 2] & 0x7F) << 7) | (b[at + 3] & 0x7F);

  static int _int32(List<int> b, int at) => (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
}
