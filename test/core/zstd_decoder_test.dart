import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:folder/core/formats/zstd_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

/// Vectors produced by CPython 3.14's `compression.zstd` (libzstd 1.5.7):
/// each `*.zst` file plus the size and SHA-256 of its original content in
/// `manifest.json`.
const _fixtures = 'test/fixtures/zstd';

typedef _Vector = ({String file, int size, String sha256, String note});

List<_Vector> _loadManifest() {
  final raw =
      jsonDecode(File('$_fixtures/manifest.json').readAsStringSync()) as List;
  return [
    for (final e in raw.cast<Map<String, dynamic>>())
      (
        file: e['file'] as String,
        size: e['size'] as int,
        sha256: e['sha256'] as String,
        note: e['note'] as String,
      ),
  ];
}

Uint8List _read(String file) => File('$_fixtures/$file').readAsBytesSync();

String _sha256(Uint8List data) => SHA256Digest()
    .process(data)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

const _magic = [0x28, 0xB5, 0x2F, 0xFD];

/// Decodes [input] and returns null, or the output when it decodes; any
/// exception other than [FormatException] fails the test.
Uint8List? _decodeOrFormatError(Uint8List input) {
  try {
    return zstdDecompress(input);
  } on FormatException {
    return null;
  }
}

void main() {
  final vectors = _loadManifest();

  group('isZstd', () {
    test('recognizes the frame magic', () {
      expect(isZstd(const [0x28, 0xB5, 0x2F, 0xFD, 0x00]), isTrue);
      expect(isZstd(const [0x28, 0xB5, 0x2F]), isFalse);
      expect(isZstd(const [0x50, 0x2A, 0x4D, 0x18]), isFalse);
      expect(isZstd(const <int>[]), isFalse);
      expect(isZstd(_read('text_l3.zst')), isTrue);
    });
  });

  group('reference vectors', () {
    for (final v in vectors) {
      test('${v.file} (${v.note})', () {
        final input = _read(v.file);
        final out = zstdDecompress(input);
        expect(out.length, v.size);
        expect(_sha256(out), v.sha256);
      });
    }
  });

  group('hand-made frames', () {
    test('empty input and skippable-only input decode to nothing', () {
      expect(zstdDecompress(Uint8List(0)), isEmpty);
      final skippable = _bytes([0x5E, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 1, 2, 3]);
      expect(zstdDecompress(skippable), isEmpty);
    });

    test('input may be a view at a non-zero offset', () {
      final file = _read('text32_l19_checksum.zst');
      final padded = Uint8List(file.length + 5)
        ..setRange(3, file.length + 3, file);
      final view = Uint8List.sublistView(padded, 3, file.length + 3);
      expect(zstdDecompress(view), zstdDecompress(file));
    });

    test('RLE block in a windowed frame without content size', () {
      // FHD 0x00, window 1 KiB, last RLE block of 1024 'x'.
      final frame = _bytes([..._magic, 0x00, 0x00, 0x03, 0x20, 0x00, 0x78]);
      expect(zstdDecompress(frame), Uint8List(1024)..fillRange(0, 1024, 0x78));
    });

    test('block larger than the window is rejected', () {
      // RLE block of 1025 bytes with a 1 KiB window.
      final frame = _bytes([..._magic, 0x00, 0x00, 0x0B, 0x20, 0x00, 0x78]);
      expect(() => zstdDecompress(frame), throwsFormatException);
    });

    test('dictionary ID 0 is accepted, a real dictionary is not', () {
      // FHD 0x21: single segment, 1-byte dictionary ID; FCS 1; raw 'A'.
      final noDict = _bytes([..._magic, 0x21, 0x00, 0x01, 0x09, 0, 0, 0x41]);
      expect(zstdDecompress(noDict), [0x41]);
      final dict = _bytes([..._magic, 0x21, 0x05, 0x01, 0x09, 0, 0, 0x41]);
      expect(
        () => zstdDecompress(dict),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('dictionar'),
          ),
        ),
      );
    });

    test('reserved block type, bad magic and trailing bytes are rejected', () {
      final reserved = _bytes([..._magic, 0x20, 0x01, 0x07, 0, 0, 0x41]);
      expect(() => zstdDecompress(reserved), throwsFormatException);
      expect(
        () => zstdDecompress(_bytes([1, 2, 3, 4, 5, 6, 7, 8])),
        throwsFormatException,
      );
      final valid = _read('one_byte.zst');
      expect(
        () => zstdDecompress(_bytes([...valid, 0x28, 0xB5])),
        throwsFormatException,
      );
    });

    test('content size mismatch is rejected', () {
      // Claims 2 bytes, holds 1.
      final frame = _bytes([..._magic, 0x20, 0x02, 0x09, 0, 0, 0x41]);
      expect(() => zstdDecompress(frame), throwsFormatException);
    });
  });

  group('limits and corruption', () {
    test('maxOutput guards against bombs', () {
      final zeros = _read('zeros_300k.zst');
      expect(zstdDecompress(zeros, maxOutput: 300000), hasLength(300000));
      expect(
        () => zstdDecompress(zeros, maxOutput: 299999),
        throwsFormatException,
      );
      // No content size in the header: the limit trips while decoding.
      final streamed = _read('mixed_stream_l9.zst');
      expect(
        () => zstdDecompress(streamed, maxOutput: 1 << 20),
        throwsFormatException,
      );
    });

    test('checksum mismatch is detected', () {
      final input = _read('text32_l19_checksum.zst');
      input[input.length - 2] ^= 0x01;
      expect(
        () => zstdDecompress(input),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('checksum'),
          ),
        ),
      );
    });

    test('every truncation of a frame throws FormatException', () {
      for (final file in [
        'text32_l19_checksum.zst',
        'text32_flushblock.zst',
        'floats_l3.zst',
        'random_8k_w10.zst',
        'one_byte_checksum.zst',
      ]) {
        final input = _read(file);
        final step = max(1, input.length ~/ 400);
        for (var n = 1; n < input.length; n += step) {
          expect(
            () => zstdDecompress(Uint8List.sublistView(input, 0, n)),
            throwsFormatException,
            reason: '$file truncated to $n bytes',
          );
        }
      }
    });

    test('flipped bytes in checksummed frames never decode wrongly', () {
      final rng = Random(8878);
      for (final file in [
        'text32_l19_checksum.zst',
        'text32_flushblock.zst',
        'floats_l19.zst',
        'random_8k_w10.zst',
      ]) {
        final original = _read(file);
        final expected = zstdDecompress(original);
        for (var i = 0; i < 400; i++) {
          final input = Uint8List.fromList(original);
          final flips = 1 + rng.nextInt(3);
          for (var k = 0; k < flips; k++) {
            input[rng.nextInt(input.length)] ^= 1 + rng.nextInt(255);
          }
          final out = _decodeOrFormatError(input);
          if (out != null) {
            expect(out, expected, reason: '$file mutation $i decoded wrongly');
          }
        }
      }
    });

    test('corrupted frames without checksum fail cleanly', () {
      final rng = Random(1);
      for (final file in [
        'text_l3.zst',
        'text_l22.zst',
        'small_alphabet.zst',
        'rle_literals.zst',
        'multi_frame.zst',
      ]) {
        final original = _read(file);
        for (var i = 0; i < 400; i++) {
          final input = Uint8List.fromList(original);
          if (i.isEven) {
            input[rng.nextInt(input.length)] ^= 1 << rng.nextInt(8);
          } else {
            // Garbage run somewhere in the body.
            final at = rng.nextInt(input.length);
            final len = min(1 + rng.nextInt(16), input.length - at);
            for (var k = 0; k < len; k++) {
              input[at + k] = rng.nextInt(256);
            }
          }
          // Must either decode or throw FormatException (never RangeError,
          // StateError, ... and never hang).
          _decodeOrFormatError(input);
        }
      }
    });
  });
}
