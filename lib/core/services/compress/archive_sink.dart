import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Where an archive is written: one file, or parts of [volumeSize] bytes
/// named `name.001`, `name.002`… as 7-Zip splits them (it joins them again
/// from the first). Bytes already written can be [patch]ed, wherever they
/// landed, so no format has to keep the whole archive in memory to fill in a
/// size or a checksum at the start.
///
/// Synchronous: it runs in the background isolate that writes the archive.
class ArchiveSink {
  ArchiveSink(this.path, {this.volumeSize}) {
    if (volumeSize != null && volumeSize! < minVolume) {
      throw ArgumentError.value(volumeSize, 'volumeSize', 'at least $minVolume bytes');
    }
  }

  /// The archive's name; parts add `.001`, `.002`… to it.
  final String path;
  final int? volumeSize;

  /// Parts no smaller than this; a split into thousands of tiny files helps
  /// no one.
  static const minVolume = 64 * 1024;

  final _parts = <String>[];
  RandomAccessFile? _file;
  var _fileStart = 0;
  var _written = 0;
  final _buffer = Uint8List(1 << 20);
  var _buffered = 0;
  var _closed = false;

  /// The files written so far, the first first.
  List<String> get parts => List.unmodifiable(_parts);

  /// Bytes written so far, in all.
  int get position => _written + _buffered;

  static String partName(String path, int number) => '$path.${number.toString().padLeft(3, '0')}';

  void add(List<int> bytes, [int start = 0, int? end]) {
    final stop = end ?? bytes.length;
    var at = start;
    while (at < stop) {
      if (_buffered == _buffer.length) _flush();
      final take = math.min(stop - at, _buffer.length - _buffered);
      _buffer.setRange(_buffered, _buffered + take, bytes, at);
      _buffered += take;
      at += take;
    }
  }

  void addByte(int byte) {
    if (_buffered == _buffer.length) _flush();
    _buffer[_buffered++] = byte;
  }

  /// Writes the buffer out, across parts as they fill.
  void _flush() {
    var at = 0;
    while (at < _buffered) {
      final file = _fileFor(_written);
      final room = volumeSize == null ? _buffered - at : _fileStart + volumeSize! - _written;
      final take = math.min(room, _buffered - at);
      file.writeFromSync(_buffer, at, at + take);
      at += take;
      _written += take;
    }
    _buffered = 0;
  }

  /// The open part [offset] goes into, starting the next one when the
  /// current one is full.
  RandomAccessFile _fileFor(int offset) {
    final size = volumeSize;
    final index = size == null ? 0 : offset ~/ size;
    if (_file == null || index >= _parts.length) {
      _file?.closeSync();
      final name = size == null ? path : partName(path, index + 1);
      _parts.add(name);
      _file = File(name).openSync(mode: FileMode.write);
      _fileStart = size == null ? 0 : index * size;
    }
    return _file!;
  }

  /// Writes [bytes] over what's at [offset], which must be written already.
  void patch(int offset, List<int> bytes) {
    if (offset + bytes.length > position) throw RangeError('patch past the end');
    // Still in the buffer: change it there.
    var at = 0;
    while (at < bytes.length) {
      final global = offset + at;
      if (global >= _written) {
        final i = global - _written;
        _buffer.setRange(i, i + (bytes.length - at), bytes, at);
        return;
      }
      final size = volumeSize;
      final index = size == null ? 0 : global ~/ size;
      final partStart = size == null ? 0 : index * size;
      final partEnd = size == null ? _written : math.min(_written, partStart + size);
      final take = math.min(bytes.length - at, math.min(partEnd, _written) - global);
      final current = index == _parts.length - 1 ? _file : null;
      final file = current ?? File(_parts[index]).openSync(mode: FileMode.append);
      final back = file.positionSync();
      file
        ..setPositionSync(global - partStart)
        ..writeFromSync(bytes, at, at + take)
        ..setPositionSync(back);
      if (current == null) file.closeSync();
      at += take;
    }
  }

  /// Finishes the last part. A split that came to one part keeps the
  /// archive's own name.
  List<String> close() {
    if (_closed) return parts;
    _closed = true;
    if (_buffered > 0 || _parts.isEmpty) {
      if (_buffered > 0) {
        _flush();
      } else {
        _fileFor(0);
      }
    }
    _file?.closeSync();
    _file = null;
    if (volumeSize != null && _parts.length == 1) {
      final single = File(_parts.single).renameSync(path);
      _parts[0] = single.path;
    }
    return parts;
  }

  /// Stops and removes every part, as when the user cancels.
  void discard() {
    _closed = true;
    try {
      _file?.closeSync();
    } on FileSystemException {
      // Removed below anyway.
    }
    _file = null;
    for (final part in _parts) {
      try {
        File(part).deleteSync();
      } on FileSystemException {
        // Gone already, or held open by something else.
      }
    }
  }
}
