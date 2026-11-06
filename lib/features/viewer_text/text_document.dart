import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:folders/core/formats/cfb_reader.dart';

enum TextEncoding { utf8, utf8Bom, utf16le, utf16be, windows1252 }

enum LineEnding {
  lf('\n', 'LF'),
  crlf('\r\n', 'CRLF'),
  cr('\r', 'CR');

  const LineEnding(this.sequence, this.label);
  final String sequence;
  final String label;
}

/// Thrown by [TextDocument.encode] when the text contains characters the
/// document's encoding can't store. Nothing is written in that case.
class UnencodableTextException implements Exception {
  UnencodableTextException(this.encodingLabel, this.characters);

  final String encodingLabel;

  /// A few of the offending characters, for the message.
  final List<String> characters;

  @override
  String toString() =>
      '$encodingLabel can\'t store ${characters.map((c) => '"$c"').join(', ')}';
}

/// A text file decoded for editing, remembering how to write it back
/// byte-for-byte compatible (encoding, BOM, line endings).
class TextDocument {
  TextDocument({
    required this.text,
    required this.encoding,
    required this.lineEnding,
    required this.endsWithNewline,
    this.malformedCount = 0,
  });

  /// Content with line endings normalised to `\n`.
  final String text;
  final TextEncoding encoding;
  final LineEnding lineEnding;
  final bool endsWithNewline;

  /// Byte sequences that weren't valid in [encoding] and were shown as
  /// U+FFFD. Saving would write U+FFFD in their place, so such documents
  /// open read-only until the user explicitly accepts that.
  final int malformedCount;

  bool get isLossless => malformedCount == 0;

  /// Files up to this size open straight into the editor. A single
  /// multi-line TextField re-lays out the whole text on every keystroke
  /// (measured on a desktop CPU: ~0.15 s per keystroke at 256 KB, ~0.6 s at
  /// 1 MB, ~3 s at 3 MB), so larger files open in the virtualised read-only
  /// viewer first, which shows any size instantly.
  static const editableLimit = 256 * 1024;

  /// Largest file the user may still load into the editor ("Edit anyway").
  /// Above this only the read-only viewer (or the hex viewer) is offered.
  static const editAnywayLimit = 8 * 1024 * 1024;

  /// Decoding below this size is cheaper than spawning an isolate.
  static const _isolateThreshold = 64 * 1024;

  /// Reads and decodes [file]; anything but small files is read and decoded
  /// in a background isolate so the UI keeps animating.
  static Future<TextDocument> load(File file) async {
    final length = await file.length();
    if (length <= _isolateThreshold) return decode(await file.readAsBytes());
    final path = file.path;
    return Isolate.run(() => decode(File(path).readAsBytesSync()));
  }

  static TextDocument decode(Uint8List bytes) {
    final (raw, encoding, malformed) = _decodeBytes(bytes);
    // One pass to count line endings (no Match objects, no substrings).
    var crlf = 0, lf = 0, cr = 0;
    for (var i = 0; i < raw.length; i++) {
      final c = raw.codeUnitAt(i);
      if (c == 0x0A) {
        lf++;
      } else if (c == 0x0D) {
        if (i + 1 < raw.length && raw.codeUnitAt(i + 1) == 0x0A) {
          crlf++;
          i++;
        } else {
          cr++;
        }
      }
    }
    final ending = crlf > lf && crlf >= cr
        ? LineEnding.crlf
        : (cr > lf ? LineEnding.cr : LineEnding.lf);
    final text = crlf + cr == 0
        ? raw
        : raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return TextDocument(
      text: text,
      encoding: encoding,
      lineEnding: ending,
      endsWithNewline: text.endsWith('\n'),
      malformedCount: malformed,
    );
  }

  /// Decodes once (no throwaway trial decode) and reports how many byte
  /// sequences were replaced with U+FFFD.
  static (String, TextEncoding, int) _decodeBytes(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      final body = Uint8List.sublistView(bytes, 3);
      try {
        return (utf8.decode(body), TextEncoding.utf8Bom, 0);
      } on FormatException {
        return (
          utf8.decode(body, allowMalformed: true),
          TextEncoding.utf8Bom,
          utf8Stats(body).$2,
        );
      }
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
            (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      final le = bytes[0] == 0xFF;
      // Code units (even lone surrogates) round-trip exactly; only a dangling
      // odd byte at the end is lost.
      return (
        decodeUtf16(bytes, 2, bigEndian: !le),
        le ? TextEncoding.utf16le : TextEncoding.utf16be,
        bytes.length.isOdd ? 1 : 0,
      );
    }
    try {
      return (utf8.decode(bytes), TextEncoding.utf8, 0);
    } on FormatException {
      final (valid, invalid) = utf8Stats(bytes);
      if (looksLikeUtf8(valid, invalid)) {
        // Mostly UTF-8 with a few stray/truncated bytes: show it correctly and
        // flag it as lossy instead of turning every character into mojibake.
        return (utf8.decode(bytes, allowMalformed: true), TextEncoding.utf8, invalid);
      }
      // Windows-1252 maps every byte to a character and back, so this is
      // lossless whatever the bytes really are.
      return (decodeCp1252(bytes), TextEncoding.windows1252, 0);
    }
  }

  /// Valid multi-byte UTF-8 sequences vs. invalid bytes in [b] (a heuristic,
  /// it doesn't reject overlong forms).
  static (int, int) utf8Stats(Uint8List b, [int start = 0, int? end]) {
    final stop = end ?? b.length;
    var valid = 0, invalid = 0, i = start;
    while (i < stop) {
      final c = b[i];
      if (c < 0x80) {
        i++;
        continue;
      }
      final need = c >= 0xC2 && c <= 0xDF
          ? 1
          : c >= 0xE0 && c <= 0xEF
              ? 2
              : c >= 0xF0 && c <= 0xF4
                  ? 3
                  : 0;
      var ok = need > 0 && i + need < stop;
      for (var k = 1; ok && k <= need; k++) {
        if ((b[i + k] & 0xC0) != 0x80) ok = false;
      }
      if (ok) {
        valid++;
        i += need + 1;
      } else {
        invalid++;
        i++;
      }
    }
    return (valid, invalid);
  }

  /// Windows-1252 text almost never contains valid multi-byte UTF-8
  /// sequences (an accented capital followed by a symbol byte), while real
  /// UTF-8 with a few bad bytes is dominated by them. A wrong guess here is
  /// safe: lossy UTF-8 opens read-only with a warning.
  static bool looksLikeUtf8(int valid, int invalid) =>
      valid > 0 && invalid <= valid;

  /// Guesses the encoding from the first bytes of a (possibly huge) file.
  /// [complete] says whether [head] is the whole file.
  static TextEncoding sniffEncoding(Uint8List head, {required bool complete}) {
    if (head.length >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) {
      return TextEncoding.utf8Bom;
    }
    if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xFE) {
      return TextEncoding.utf16le;
    }
    if (head.length >= 2 && head[0] == 0xFE && head[1] == 0xFF) {
      return TextEncoding.utf16be;
    }
    // Don't count a multi-byte character cut off by the end of the sample.
    var end = head.length;
    if (!complete) {
      var j = end - 1, k = 0;
      while (j >= 0 && k < 3 && (head[j] & 0xC0) == 0x80) {
        j--;
        k++;
      }
      if (j >= 0) {
        final lead = head[j];
        final size = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
        if (end - j < size) end = j;
      }
    }
    final (valid, invalid) = utf8Stats(head, 0, end);
    return invalid == 0 || looksLikeUtf8(valid, invalid)
        ? TextEncoding.utf8
        : TextEncoding.windows1252;
  }

  /// Byte length of the byte-order mark for [encoding].
  static int bomLength(TextEncoding encoding) => switch (encoding) {
        TextEncoding.utf8Bom => 3,
        TextEncoding.utf16le || TextEncoding.utf16be => 2,
        _ => 0,
      };

  /// Decodes a slice of a file stored in [encoding] (no BOM handling).
  static String decodeSlice(Uint8List bytes, TextEncoding encoding) =>
      switch (encoding) {
        TextEncoding.utf8 ||
        TextEncoding.utf8Bom =>
          utf8.decode(bytes, allowMalformed: true),
        TextEncoding.windows1252 => decodeCp1252(bytes),
        TextEncoding.utf16le => decodeUtf16(bytes, 0, bigEndian: false),
        TextEncoding.utf16be => decodeUtf16(bytes, 0, bigEndian: true),
      };

  static String decodeUtf16(Uint8List bytes, int start, {required bool bigEndian}) {
    final units = Uint16List((bytes.length - start) ~/ 2);
    for (var i = 0, o = start; i < units.length; i++, o += 2) {
      units[i] = bigEndian
          ? (bytes[o] << 8) | bytes[o + 1]
          : bytes[o] | (bytes[o + 1] << 8);
    }
    return String.fromCharCodes(units);
  }

  /// The same document stored as [encoding] (e.g. after the user agreed to
  /// convert a Windows-1252 file to UTF-8).
  TextDocument withEncoding(TextEncoding encoding) => TextDocument(
        text: text,
        encoding: encoding,
        lineEnding: lineEnding,
        endsWithNewline: endsWithNewline,
      );

  /// Encodes [content] (with `\n` line endings) the same way the file was
  /// originally stored. Unchanged text encodes back to the original bytes
  /// (except malformed sequences, see [malformedCount]).
  ///
  /// Throws [UnencodableTextException] rather than silently switching
  /// encodings when [content] has characters the encoding can't hold.
  Uint8List encode(String content) {
    final out = lineEnding == LineEnding.lf
        ? content
        : content.replaceAll('\n', lineEnding.sequence);
    switch (encoding) {
      case TextEncoding.utf8:
        return utf8.encode(out);
      case TextEncoding.utf8Bom:
        final body = utf8.encode(out);
        return Uint8List(body.length + 3)
          ..setRange(0, 3, const [0xEF, 0xBB, 0xBF])
          ..setRange(3, body.length + 3, body);
      case TextEncoding.utf16le:
      case TextEncoding.utf16be:
        final le = encoding == TextEncoding.utf16le;
        final bytes = Uint8List(2 + out.length * 2);
        bytes[0] = le ? 0xFF : 0xFE;
        bytes[1] = le ? 0xFE : 0xFF;
        for (var i = 0, o = 2; i < out.length; i++, o += 2) {
          final unit = out.codeUnitAt(i);
          bytes[o] = le ? unit & 0xFF : unit >> 8;
          bytes[o + 1] = le ? unit >> 8 : unit & 0xFF;
        }
        return bytes;
      case TextEncoding.windows1252:
        final bytes = encodeCp1252(out);
        if (bytes != null) return bytes;
        final bad = <String>{};
        for (final rune in out.runes) {
          if (rune > 0xFFFF || !isCp1252Encodable(rune)) {
            bad.add(String.fromCharCode(rune));
            if (bad.length == 5) break;
          }
        }
        throw UnencodableTextException(encodingLabel, bad.toList());
    }
  }

  String get encodingLabel => labelOf(encoding);

  static String labelOf(TextEncoding encoding) => switch (encoding) {
        TextEncoding.utf8 => 'UTF-8',
        TextEncoding.utf8Bom => 'UTF-8 BOM',
        TextEncoding.utf16le => 'UTF-16 LE',
        TextEncoding.utf16be => 'UTF-16 BE',
        TextEncoding.windows1252 => 'Windows-1252',
      };
}

/// Heuristic: does this look like human-readable text rather than binary?
bool looksLikeText(Uint8List sample) {
  if (sample.isEmpty) return true;
  if (sample.length >= 2 &&
      ((sample[0] == 0xFF && sample[1] == 0xFE) ||
          (sample[0] == 0xFE && sample[1] == 0xFF))) {
    return true;
  }
  var control = 0;
  for (final b in sample) {
    if (b == 0) return false;
    if (b < 0x09 || (b > 0x0D && b < 0x20)) control++;
  }
  return control / sample.length < 0.02;
}

/// Reads up to [length] bytes from the start of [file].
Future<Uint8List> readHead(File file, [int length = 8192]) async {
  final raf = await file.open();
  try {
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}
