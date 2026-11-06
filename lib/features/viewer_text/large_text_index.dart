/// Pure-Dart building blocks of the large-file text viewer: splitting bytes
/// into display rows, a sparse row index, and whole-file search. Nothing
/// here touches Flutter, so it runs in background isolates (and in plain
/// `dart` benchmarks).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folders/features/viewer_text/text_document.dart';

/// Rows longer than this many bytes continue on extra rows, so no single row
/// ever needs a huge paragraph layout (minified JSON, one-line logs...).
const maxRowBytes = 2048;

/// Rows per index checkpoint, and per read from disk.
const rowsPerBlock = 64;

int codeUnitSize(TextEncoding e) =>
    e == TextEncoding.utf16le || e == TextEncoding.utf16be ? 2 : 1;

/// One display row.
class TextRow {
  const TextRow({
    required this.text,
    required this.line,
    required this.continuation,
    required this.start,
    required this.end,
  });

  final String text;

  /// 1-based line number.
  final int line;

  /// True for the second and later rows of a line longer than [maxRowBytes].
  final bool continuation;

  /// Byte range in the file (end excludes the '\n').
  final int start;
  final int end;
}

/// Sparse row index: one checkpoint per [rowsPerBlock] rows.
class TextIndex {
  TextIndex({
    required this.encoding,
    required this.blockStarts,
    required this.blockLines,
    required this.blockContinues,
    required this.rowCount,
    required this.lineCount,
    required this.endOffset,
    required this.complete,
    required this.maxRowLength,
  });

  final TextEncoding encoding;

  /// Byte offset of each block's first row.
  final Int64List blockStarts;

  /// 1-based line number of each block's first row.
  final Int32List blockLines;

  /// 1 when a block's first row continues the previous (long) line.
  final Uint8List blockContinues;
  final int rowCount;
  final int lineCount;

  /// End of the indexed region: the file length when [complete], otherwise
  /// the start of the first row not yet known to be whole.
  final int endOffset;
  final bool complete;

  /// Longest row in bytes.
  final int maxRowLength;

  int get blockCount => blockStarts.length;
  int get unit => codeUnitSize(encoding);

  /// Byte range `[start, end)` of [block] and whether it's the last block.
  (int, int, bool) blockRange(int block) {
    final isLast = block + 1 >= blockCount;
    return (
      blockStarts[block],
      isLast ? endOffset : blockStarts[block + 1],
      isLast,
    );
  }

  /// Decodes the rows of [block] from its bytes (read from [blockRange]).
  List<TextRow> splitBlock(int block, Uint8List bytes) {
    final (start, end, isLast) = blockRange(block);
    final rows = <TextRow>[];
    final unit = this.unit;
    final scanner = TextRowScanner(
      encoding,
      start,
      blockContinues[block] == 1,
      blockLines[block],
      (s, e, continuation, line) {
        if (rows.length >= rowsPerBlock) return;
        if (s < end || (isLast && complete && s == end)) {
          var stop = e;
          // Hide the '\r' of CRLF line endings.
          if (stop - s >= unit && _isCr(bytes, stop - start - unit)) {
            stop -= unit;
          }
          rows.add(TextRow(
            text: TextDocument.decodeSlice(
              Uint8List.sublistView(bytes, s - start, stop - start),
              encoding,
            ),
            line: line,
            continuation: continuation,
            start: s,
            end: e,
          ));
        }
      },
    )..feed(bytes, start, 0, bytes.length);
    scanner.finish(end);
    return rows;
  }

  bool _isCr(Uint8List b, int i) => switch (encoding) {
        TextEncoding.utf16le => b[i] == 0x0D && b[i + 1] == 0,
        TextEncoding.utf16be => b[i] == 0 && b[i + 1] == 0x0D,
        _ => b[i] == 0x0D,
      };

  /// Index of the last block whose first row is at or before the first row
  /// of [line].
  int blockForLine(int line) {
    final key = line * 2;
    var lo = 0, hi = blockCount - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (blockLines[mid] * 2 + blockContinues[mid] <= key) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Index of the block containing byte [offset].
  int blockForOffset(int offset) {
    var lo = 0, hi = blockCount - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (blockStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}

/// Splits encoded text into display rows. A row ends at '\n' (excluded) or,
/// for very long lines, once it reaches [maxRowBytes] bytes at a character
/// boundary; the rest of the line continues on the next row. The result
/// depends only on the bytes and the starting row, so an index built in the
/// background and rows read later always agree.
class TextRowScanner {
  TextRowScanner(
    TextEncoding encoding,
    int start,
    bool continuation,
    int line,
    this.onRow,
  )   : _unit = codeUnitSize(encoding),
        _bigEndian = encoding == TextEncoding.utf16be,
        _utf8 = encoding == TextEncoding.utf8 || encoding == TextEncoding.utf8Bom,
        rowStart = start,
        _continuation = continuation,
        _line = line;

  final int _unit;
  final bool _bigEndian;
  final bool _utf8;
  final void Function(int start, int end, bool continuation, int line) onRow;

  int rowStart;
  bool _continuation;
  int _line;
  int maxRowLength = 0;

  /// Scans `chunk[from..to)`, where `chunk[0]` is at file offset [offset].
  void feed(Uint8List chunk, int offset, int from, int to) {
    if (_unit == 1) {
      final utf8 = _utf8;
      for (var i = from; i < to; i++) {
        final b = chunk[i];
        if (b == 0x0A) {
          final pos = offset + i;
          _emit(pos, pos + 1, false);
        } else if (offset + i - rowStart >= maxRowBytes &&
            b != 0x0D &&
            (!utf8 || (b & 0xC0) != 0x80)) {
          final pos = offset + i;
          _emit(pos, pos, true);
        }
      }
    } else {
      for (var i = from; i + 1 < to; i += 2) {
        final u = _bigEndian
            ? (chunk[i] << 8) | chunk[i + 1]
            : chunk[i] | (chunk[i + 1] << 8);
        if (u == 0x0A) {
          final pos = offset + i;
          _emit(pos, pos + 2, false);
        } else if (offset + i - rowStart >= maxRowBytes &&
            u != 0x0D &&
            (u < 0xDC00 || u > 0xDFFF)) {
          final pos = offset + i;
          _emit(pos, pos, true);
        }
      }
    }
  }

  void _emit(int rowEnd, int nextStart, bool nextContinues) {
    final length = rowEnd - rowStart;
    if (length > maxRowLength) maxRowLength = length;
    onRow(rowStart, rowEnd, _continuation, _line);
    if (!nextContinues) _line++;
    rowStart = nextStart;
    _continuation = nextContinues;
  }

  /// Emits the final row, which runs to [end].
  void finish(int end) {
    final length = end - rowStart;
    if (length > maxRowLength) maxRowLength = length;
    onRow(rowStart, end, _continuation, _line);
  }
}

/// Builds a [TextIndex] from bytes fed in order.
class TextIndexBuilder {
  TextIndexBuilder(this.encoding, int start) {
    _scanner = TextRowScanner(encoding, start, false, 1, _onRow);
  }

  final TextEncoding encoding;
  late final TextRowScanner _scanner;
  final _starts = <int>[];
  final _lines = <int>[];
  final _continues = <int>[];
  int _rows = 0;
  int _lastLine = 1;

  void _onRow(int start, int end, bool continuation, int line) {
    if (_rows % rowsPerBlock == 0) {
      _starts.add(start);
      _lines.add(line);
      _continues.add(continuation ? 1 : 0);
    }
    _rows++;
    _lastLine = line;
  }

  void feed(Uint8List chunk, int offset, int from, int to) =>
      _scanner.feed(chunk, offset, from, to);

  /// [length] is the number of bytes fed so far (the file length when
  /// [complete]). An incomplete index leaves out the last, possibly
  /// unfinished row.
  TextIndex build({required bool complete, required int length}) {
    if (complete) _scanner.finish(length);
    return TextIndex(
      encoding: encoding,
      blockStarts: Int64List.fromList(_starts),
      blockLines: Int32List.fromList(_lines),
      blockContinues: Uint8List.fromList(_continues),
      rowCount: _rows,
      lineCount: _lastLine,
      endOffset: complete ? length : _scanner.rowStart,
      complete: complete,
      maxRowLength: _scanner.maxRowLength,
    );
  }
}

/// Indexes the whole file at [path] in 1 MB reads (blocking: run it in a
/// background isolate).
TextIndex indexTextFile(String path, TextEncoding encoding) {
  final raf = File(path).openSync();
  try {
    final start = TextDocument.bomLength(encoding);
    final builder = TextIndexBuilder(encoding, start);
    final buffer = Uint8List(1 << 20);
    raf.setPositionSync(start);
    var pos = start;
    while (true) {
      final n = raf.readIntoSync(buffer);
      if (n <= 0) break;
      builder.feed(buffer, pos, 0, n);
      pos += n;
    }
    return builder.build(complete: true, length: pos);
  } finally {
    raf.closeSync();
  }
}

/// [query] encoded the way the file stores text, or null when it can't be.
Uint8List? encodeSearchNeedle(String query, TextEncoding encoding) {
  switch (encoding) {
    case TextEncoding.utf8:
    case TextEncoding.utf8Bom:
    case TextEncoding.windows1252:
      try {
        return TextDocument(
          text: query,
          encoding: encoding == TextEncoding.utf8Bom ? TextEncoding.utf8 : encoding,
          lineEnding: LineEnding.lf,
          endsWithNewline: false,
        ).encode(query);
      } on UnencodableTextException {
        return null;
      }
    case TextEncoding.utf16le:
    case TextEncoding.utf16be:
      final le = encoding == TextEncoding.utf16le;
      final out = Uint8List(query.length * 2);
      for (var i = 0; i < query.length; i++) {
        final u = query.codeUnitAt(i);
        out[i * 2] = le ? u & 0xFF : u >> 8;
        out[i * 2 + 1] = le ? u >> 8 : u & 0xFF;
      }
      return out;
  }
}

/// Byte offsets of non-overlapping matches of [needle] in the file at
/// [path], scanning from [start] (after any BOM), up to [maxHits]. Unless
/// [caseSensitive], ASCII letters match either case. Blocking: run it in a
/// background isolate.
Int64List searchTextFile(
  String path,
  Uint8List needle,
  TextEncoding encoding, {
  required bool caseSensitive,
  int maxHits = 100000,
}) {
  final unit = codeUnitSize(encoding);
  final bigEndian = encoding == TextEncoding.utf16be;
  final start = TextDocument.bomLength(encoding);
  int fold(int u) => !caseSensitive && u >= 0x41 && u <= 0x5A ? u | 0x20 : u;
  int unitAt(Uint8List b, int o) => unit == 1
      ? b[o]
      : bigEndian
          ? (b[o] << 8) | b[o + 1]
          : b[o] | (b[o + 1] << 8);
  // The needle as folded code units (bytes for 8-bit encodings), so ASCII
  // folding never touches bytes of other UTF-16 characters.
  final count = needle.length ~/ unit;
  if (count == 0) return Int64List(0);
  final pattern = Int32List(count);
  for (var j = 0; j < count; j++) {
    pattern[j] = fold(unitAt(needle, j * unit));
  }
  final length = count * unit;
  final hits = <int>[];
  final raf = File(path).openSync();
  try {
    const chunkSize = 1 << 20;
    // Keep enough of each read's tail (a whole number of code units) for
    // matches that straddle two reads.
    final keep = unit == 2 ? length : length - 1;
    final buffer = Uint8List(chunkSize + keep);
    var carried = 0; // bytes kept from the previous read
    var base = start; // file offset of buffer[0]
    var nextAllowed = start; // matches don't overlap
    raf.setPositionSync(start);
    // 8-bit encodings: fold through a table in a tight loop.
    final table = Uint8List(256);
    for (var b = 0; b < 256; b++) {
      table[b] = fold(b);
    }
    final first = pattern[0];
    while (hits.length < maxHits) {
      final n = raf.readIntoSync(buffer, carried, carried + chunkSize);
      final available = carried + n;
      if (unit == 1) {
        for (var i = 0; i + length <= available; i++) {
          if (table[buffer[i]] != first) continue;
          var k = 1;
          while (k < count && table[buffer[i + k]] == pattern[k]) {
            k++;
          }
          if (k == count && base + i >= nextAllowed) {
            hits.add(base + i);
            nextAllowed = base + i + length;
            if (hits.length >= maxHits) break;
          }
        }
      } else {
        for (var i = 0; i + length <= available; i += 2) {
          var k = 0;
          while (k < count && fold(unitAt(buffer, i + k * 2)) == pattern[k]) {
            k++;
          }
          if (k == count && base + i >= nextAllowed) {
            hits.add(base + i);
            nextAllowed = base + i + length;
            if (hits.length >= maxHits) break;
          }
        }
      }
      if (n <= 0) break;
      final kept = math.min(keep, available);
      buffer.setRange(0, kept, buffer, available - kept);
      base += available - kept;
      carried = kept;
    }
  } finally {
    raf.closeSync();
  }
  return Int64List.fromList(hits);
}
