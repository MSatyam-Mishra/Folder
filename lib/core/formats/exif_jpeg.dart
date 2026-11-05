import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/exif_bytes.dart';

/// What the header of a JPEG stream says, without decoding it.
class JpegInfo {
  const JpegInfo({
    required this.sof,
    required this.width,
    required this.height,
    required this.components,
    this.exifOffset,
    this.exifLength,
    this.scanOffset,
  });

  /// Start-of-frame marker (0xC0 baseline, 0xC2 progressive, 0xC3 lossless…).
  final int sof;
  final int width;
  final int height;
  final int components;

  /// Absolute offset/length of the TIFF structure inside an APP1 "Exif"
  /// segment, if any.
  final int? exifOffset;
  final int? exifLength;

  /// Absolute offset of the first scan's data (after the SOS header).
  final int? scanOffset;

  /// Huffman baseline/extended/progressive: what image decoders (Skia,
  /// the `image` package) handle. Lossless (SOF3) is raw sensor data in
  /// CR2/DNG/NEF files and must not be mistaken for a preview.
  bool get isDisplayable =>
      (sof == 0xC0 || sof == 0xC1 || sof == 0xC2) &&
      width > 0 &&
      height > 0 &&
      (components == 1 || components == 3 || components == 4);
}

abstract final class JpegUtil {
  static const soi = [0xFF, 0xD8];

  /// Parses the marker segments of the JPEG at [offset] up to the first
  /// scan. Returns null when there is no JPEG there.
  ///
  /// With [damagedSoi], the first byte isn't checked (the Epson R-D1 writes
  /// 0xEE there).
  static JpegInfo? parseHeader(
    RandomBytes src,
    int offset, {
    bool damagedSoi = false,
  }) {
    if (damagedSoi
        ? !src.matches(offset + 1, const [0xD8, 0xFF])
        : !src.matches(offset, const [0xFF, 0xD8, 0xFF])) {
      return null;
    }
    var pos = offset + 2;
    int? sof, width, height, components, exifOffset, exifLength;
    for (var guard = 0; guard < 256; guard++) {
      final head = src.read(pos, 4);
      if (head.length < 2 || head[0] != 0xFF) return null;
      var marker = head[1];
      if (marker == 0xFF) {
        // Fill byte.
        pos++;
        continue;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2;
        continue;
      }
      if (head.length < 4) return null;
      final len = head[2] << 8 | head[3];
      if (len < 2) return null;
      if (marker == 0xDA) {
        if (sof == null) return null;
        return JpegInfo(
          sof: sof,
          width: width!,
          height: height!,
          components: components!,
          exifOffset: exifOffset,
          exifLength: exifLength,
          scanOffset: pos + 2 + len,
        );
      }
      if (marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC) {
        final f = src.read(pos + 4, 6);
        if (f.length < 6) return null;
        sof ??= marker;
        height ??= f[1] << 8 | f[2];
        width ??= f[3] << 8 | f[4];
        components ??= f[5];
      } else if (marker == 0xE1 && exifOffset == null && len > 14) {
        if (src.matches(pos + 4, const [0x45, 0x78, 0x69, 0x66, 0, 0])) {
          exifOffset = pos + 10;
          exifLength = len - 8;
        }
      } else if (marker == 0xD9) {
        return null;
      }
      pos += 2 + len;
    }
    return null;
  }

  /// Offset just past the EOI marker of the JPEG whose scan data starts at
  /// [scanOffset], scanning at most [maxLength] bytes; -1 if not found.
  static int findEnd(RandomBytes src, int scanOffset, int maxLength) {
    const chunk = 1 << 20;
    final stop = math.min(src.length, scanOffset + maxLength);
    var pos = scanOffset;
    while (pos < stop) {
      final b = src.read(pos, math.min(chunk + 1, stop - pos));
      if (b.length < 2) return -1;
      for (var i = 0; i < b.length - 1; i++) {
        if (b[i] == 0xFF && b[i + 1] == 0xD9) return pos + i + 2;
      }
      pos += chunk;
    }
    return -1;
  }

  /// True when an EOI marker sits near the end of [offset, offset+length)
  /// (cameras often pad after it). Returns the trimmed length, or null.
  static int? trimmedLength(RandomBytes src, int offset, int length) {
    final tail = math.min(length, 4096);
    final b = src.read(offset + length - tail, tail);
    final i = lastIndexOfBytes(b, const [0xFF, 0xD9]);
    if (i < 0) return null;
    return length - tail + i + 2;
  }

  /// [jpeg] with any EXIF segment removed and a minimal one carrying
  /// [orientation] inserted, so image decoders that honour EXIF (Flutter's
  /// does) show it upright.
  static Uint8List withOrientation(Uint8List jpeg, int orientation) {
    if (jpeg.length < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;
    final out = BytesBuilder(copy: false);
    out.add(const [0xFF, 0xD8]);
    out.add(_exifSegment(orientation));
    var pos = 2;
    // Copy the header segments, dropping APP1 "Exif".
    while (pos + 4 <= jpeg.length) {
      if (jpeg[pos] != 0xFF) break;
      final marker = jpeg[pos + 1];
      if (marker == 0xFF) {
        pos++;
        continue;
      }
      if (marker == 0xDA ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD9)) {
        break;
      }
      final len = jpeg[pos + 2] << 8 | jpeg[pos + 3];
      final end = pos + 2 + len;
      if (len < 2 || end > jpeg.length) break;
      final isExif = marker == 0xE1 &&
          len >= 8 &&
          jpeg[pos + 4] == 0x45 &&
          jpeg[pos + 5] == 0x78 &&
          jpeg[pos + 6] == 0x69 &&
          jpeg[pos + 7] == 0x66;
      if (!isExif) out.add(Uint8List.sublistView(jpeg, pos, end));
      pos = end;
    }
    out.add(Uint8List.sublistView(jpeg, pos));
    return out.takeBytes();
  }

  static Uint8List _exifSegment(int orientation) {
    final o = orientation.clamp(1, 8);
    return Uint8List.fromList([
      0xFF, 0xE1, 0x00, 0x22, // APP1, length 34
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
      0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // big-endian TIFF
      0x00, 0x01, // one entry
      0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // Orientation SHORT[1]
      0x00, o, 0x00, 0x00, // value
      0x00, 0x00, 0x00, 0x00, // no next IFD
    ]);
  }

  /// (width, height) after applying EXIF [orientation].
  static (int, int) orientedSize(int width, int height, int orientation) =>
      orientation >= 5 ? (height, width) : (width, height);
}
