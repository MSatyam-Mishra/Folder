import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:folder/core/files/file_types.dart';
import 'package:folder/features/viewer_image/raw_image.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

/// Decoding/encoding helpers for formats Flutter can't display natively and
/// for applying edits.
abstract final class ImageCodec {
  /// Extensions the editor can save back in place: the encoder must write
  /// exactly that format. Everything else is saved as a PNG copy. (The
  /// `image` package has no PNM/PPM/PGM/PBM/PAM writer, its CUR writer
  /// drops the hotspot, and WebP/HEIC/AVIF/PSD/EXR can't be written.)
  static const writable = {
    'jpg', 'jpeg', 'jfif', 'png', 'gif', 'bmp', 'tif', 'tiff', 'tga', 'ico',
  };

  static bool canWrite(String extension) => writable.contains(extension);

  static bool needsDartDecoder(String path) =>
      FileTypes.kindOf(path) == FileKind.rasterImage;

  /// An [ImageProvider] for any supported image file. Camera raws show
  /// their embedded preview.
  static ImageProvider providerFor(File file) {
    if (RawImages.isRaw(file.path)) return RawPreviewImage(file);
    return needsDartDecoder(file.path)
        ? _DartDecodedImage(file)
        : FileImage(file);
  }

  /// [providerFor], decoded no larger than [maxSide] pixels on its long
  /// side. Phone cameras now take 50–200 MP photos; decoding those at full
  /// size costs hundreds of MB and seconds, for a screen a fraction of that.
  static ImageProvider displayProviderFor(File file, int maxSide) =>
      ResizeImage(
        providerFor(file),
        width: maxSide,
        height: maxSide,
        policy: ResizeImagePolicy.fit,
        allowUpscaling: false,
      );

  /// Decodes [file] with the Dart decoder in a background isolate (which
  /// also reads the file, so the bytes aren't copied between isolates) and
  /// hands it to the engine as an uncompressed BMP. Compressing a PNG only to
  /// decompress it a moment later used to be most of the cost: for a 12 MP
  /// TIFF on a desktop CPU the hand-off went from ~910 ms (PNG) to ~290 ms.
  static Future<Uint8List> toEngineImage(File file) {
    final path = file.path;
    return Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      var decoded = img.decodeNamedImage(path, bytes) ?? img.decodeImage(bytes);
      if (decoded == null) throw const FormatException('Unsupported image data');
      // BMP holds 8-bit RGB(A); expand palettes, grey and 16-bit/float data.
      final alpha =
          decoded.hasAlpha || (decoded.palette?.numChannels ?? 0) == 4;
      if (decoded.format != img.Format.uint8 ||
          decoded.hasPalette ||
          decoded.numChannels != (alpha ? 4 : 3)) {
        decoded = decoded.convert(
          format: img.Format.uint8,
          numChannels: alpha ? 4 : 3,
        );
      }
      return img.encodeBmp(decoded);
    });
  }

  /// Decodes [file] into editable pixels. Falls back to the platform codec
  /// for formats the Dart decoder lacks (e.g. HEIC/AVIF where supported).
  /// Camera raws are edited through their (upright) embedded preview.
  static Future<img.Image> decodeForEditing(File file) async {
    if (RawImages.isRaw(file.path)) {
      return _decodeWithPlatform(await RawImages.previewBytes(file));
    }
    final path = file.path;
    final decoded = await Isolate.run(() {
      try {
        final bytes = File(path).readAsBytesSync();
        final image = img.decodeNamedImage(path, bytes);
        if (image == null) return null;
        // Match what Flutter displays: apply the EXIF orientation flag.
        return img
            .bakeOrientation(image)
            .convert(format: img.Format.uint8, numChannels: 4);
      } catch (_) {
        return null;
      }
    });
    if (decoded != null) return decoded;
    return _decodeWithPlatform(await file.readAsBytes());
  }

  /// Decodes with the engine's codecs, which apply EXIF orientation.
  static Future<img.Image> _decodeWithPlatform(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = frame.image.width, height = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (data == null) throw const FormatException('Unsupported image data');
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: data.buffer,
      numChannels: 4,
    );
  }

  /// Applies [edits] to [source] and encodes as [extension], which must be
  /// one of [writable]. Throws [UnsupportedError] otherwise — never writes
  /// bytes of a different format under that extension.
  static Future<Uint8List> applyAndEncode(
    img.Image source,
    ImageEdits edits,
    String extension,
  ) {
    final matrix = edits.colorMatrix();
    return Isolate.run(() {
      var out = source;
      if (edits.quarterTurns % 4 != 0) {
        out = img.copyRotate(out, angle: 90 * (edits.quarterTurns % 4));
      }
      if (edits.flipHorizontal) out = img.flipHorizontal(out);
      if (edits.flipVertical) out = img.flipVertical(out);
      final crop = edits.crop;
      if (crop != null) {
        final x = (crop.left * out.width).round().clamp(0, out.width - 1);
        final y = (crop.top * out.height).round().clamp(0, out.height - 1);
        final w = (crop.width * out.width).round().clamp(1, out.width - x);
        final h = (crop.height * out.height).round().clamp(1, out.height - y);
        out = img.copyCrop(out, x: x, y: y, width: w, height: h);
      }
      if (matrix != null) {
        if (identical(out, source)) out = source.clone();
        for (final p in out) {
          final r = p.r.toDouble(), g = p.g.toDouble(), b = p.b.toDouble();
          final a = p.a.toDouble();
          p
            ..r = (matrix[0] * r + matrix[1] * g + matrix[2] * b + matrix[3] * a + matrix[4]).clamp(0, 255)
            ..g = (matrix[5] * r + matrix[6] * g + matrix[7] * b + matrix[8] * a + matrix[9]).clamp(0, 255)
            ..b = (matrix[10] * r + matrix[11] * g + matrix[12] * b + matrix[13] * a + matrix[14]).clamp(0, 255);
        }
      }
      if (!writable.contains(extension)) {
        throw UnsupportedError("Can't write .$extension images");
      }
      return switch (extension) {
        'jpg' || 'jpeg' || 'jfif' => img.encodeJpg(out, quality: 92),
        'png' => img.encodePng(out),
        _ => img.encodeNamedImage('x.$extension', out) ??
            (throw UnsupportedError("Can't write .$extension images")),
      };
    });
  }

  /// Basic EXIF tags as label → value, for JPEG/TIFF files; for camera raws
  /// also the raw format, raw size and the size of the preview shown.
  static Future<Map<String, String>> readExif(File file) async {
    if (RawImages.isRaw(file.path)) return RawImages.details(file);
    final ext = FileTypes.extensionOf(file.path);
    if (!const {'jpg', 'jpeg', 'jfif', 'tif', 'tiff'}.contains(ext)) return {};
    final path = file.path;
    return Isolate.run(() {
      final result = <String, String>{};
      try {
        final bytes = File(path).readAsBytesSync();
        final exif = ext.startsWith('t')
            ? img.decodeTiff(bytes)?.exif
            : img.decodeJpgExif(bytes);
        if (exif == null) return result;
        void put(String label, img.IfdDirectory dir, String tag) {
          final v = dir[tag]?.toString().trim();
          if (v != null && v.isNotEmpty) result[label] = v;
        }

        final ifd0 = exif.imageIfd;
        final ex = exif.exifIfd;
        put('Camera make', ifd0, 'Make');
        put('Camera model', ifd0, 'Model');
        put('Taken', ex, 'DateTimeOriginal');
        put('Exposure', ex, 'ExposureTime');
        put('Aperture', ex, 'FNumber');
        put('ISO', ex, 'ISOSpeedRatings');
        put('Focal length', ex, 'FocalLength');
        put('Lens', ex, 'LensModel');
        put('Software', ifd0, 'Software');
        final gps = exif.gpsIfd;
        final lat = gps['GPSLatitude'], lon = gps['GPSLongitude'];
        if (lat != null && lon != null) {
          double dms(img.IfdValue v) =>
              v.toRational(0).toDouble() +
              v.toRational(1).toDouble() / 60 +
              v.toRational(2).toDouble() / 3600;
          final latSign = gps['GPSLatitudeRef']?.toString() == 'S' ? -1 : 1;
          final lonSign = gps['GPSLongitudeRef']?.toString() == 'W' ? -1 : 1;
          result['Location'] =
              '${(dms(lat) * latSign).toStringAsFixed(5)}, '
              '${(dms(lon) * lonSign).toStringAsFixed(5)}';
        }
      } catch (_) {
        // Corrupt EXIF just means no extra details.
      }
      return result;
    });
  }
}

enum ImageFilterPreset { none, grayscale, sepia, invert, warm, cool, vivid }

/// Non-destructive edit state shared by the editor preview and the encoder.
class ImageEdits {
  int quarterTurns = 0;
  bool flipHorizontal = false;
  bool flipVertical = false;

  /// Normalised crop rectangle in the rotated/flipped image space.
  Rect? crop;

  /// -100..100
  double brightness = 0;
  double contrast = 0;
  double saturation = 0;
  ImageFilterPreset filter = ImageFilterPreset.none;

  bool get isIdentity =>
      quarterTurns % 4 == 0 &&
      !flipHorizontal &&
      !flipVertical &&
      crop == null &&
      colorMatrix() == null;

  /// Combined 4x5 colour matrix (as used by [ColorFilter.matrix]), or null
  /// when colours are unchanged.
  List<double>? colorMatrix() {
    var m = _identity;
    var changed = false;
    if (brightness != 0) {
      final o = brightness * 2.55;
      m = _multiply([1, 0, 0, 0, o, 0, 1, 0, 0, o, 0, 0, 1, 0, o, 0, 0, 0, 1, 0], m);
      changed = true;
    }
    if (contrast != 0) {
      final f = (100 + contrast) / 100;
      final t = 128 * (1 - f);
      m = _multiply([f, 0, 0, 0, t, 0, f, 0, 0, t, 0, 0, f, 0, t, 0, 0, 0, 1, 0], m);
      changed = true;
    }
    if (saturation != 0) {
      m = _multiply(_saturation(1 + saturation / 100), m);
      changed = true;
    }
    final preset = switch (filter) {
      ImageFilterPreset.none => null,
      ImageFilterPreset.grayscale => _saturation(0),
      ImageFilterPreset.sepia => const <double>[
          0.393, 0.769, 0.189, 0, 0, //
          0.349, 0.686, 0.168, 0, 0,
          0.272, 0.534, 0.131, 0, 0,
          0, 0, 0, 1, 0,
        ],
      ImageFilterPreset.invert => const <double>[
          -1, 0, 0, 0, 255, //
          0, -1, 0, 0, 255,
          0, 0, -1, 0, 255,
          0, 0, 0, 1, 0,
        ],
      ImageFilterPreset.warm => const <double>[
          1.1, 0, 0, 0, 10, //
          0, 1.0, 0, 0, 0,
          0, 0, 0.85, 0, -10,
          0, 0, 0, 1, 0,
        ],
      ImageFilterPreset.cool => const <double>[
          0.9, 0, 0, 0, -10, //
          0, 1.0, 0, 0, 0,
          0, 0, 1.15, 0, 10,
          0, 0, 0, 1, 0,
        ],
      ImageFilterPreset.vivid => _saturation(1.5),
    };
    if (preset != null) {
      m = _multiply(preset, m);
      changed = true;
    }
    return changed ? m : null;
  }

  static const List<double> _identity = [
    1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, //
  ];

  static List<double> _saturation(double x) {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    return [
      lr * (1 - x) + x, lg * (1 - x), lb * (1 - x), 0, 0, //
      lr * (1 - x), lg * (1 - x) + x, lb * (1 - x), 0, 0,
      lr * (1 - x), lg * (1 - x), lb * (1 - x) + x, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// Returns a·b (apply b first, then a).
  static List<double> _multiply(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        var sum = col == 4 ? a[row * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }
}

/// Image provider that decodes with the pure-Dart `image` package.
class _DartDecodedImage extends ImageProvider<_DartDecodedImage> {
  const _DartDecodedImage(this.file);

  final File file;

  @override
  Future<_DartDecodedImage> obtainKey(ImageConfiguration configuration) =>
      Future.value(this);

  @override
  ImageStreamCompleter loadImage(
    _DartDecodedImage key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_load(decode));
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final encoded = await ImageCodec.toEngineImage(file);
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) =>
      other is _DartDecodedImage && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;
}
