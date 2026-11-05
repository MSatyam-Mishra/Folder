import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:folder/core/files/file_types.dart';
import 'package:folder/core/formats/raw_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Thrown when a camera raw file carries no preview image we can show.
class RawPreviewUnavailable implements Exception {
  const RawPreviewUnavailable();

  @override
  String toString() =>
      "This raw photo has no embedded preview that can be shown here.";
}

/// Camera raw files in the image viewer: they're shown, zoomed and edited
/// through the JPEG preview the camera embedded, never by decoding the raw
/// sensor data.
abstract final class RawImages {
  static bool isRaw(String path) =>
      FileTypes.kindOf(path) == FileKind.cameraRaw;

  /// The preview of [file], encoded so it displays upright. Extracted in a
  /// background isolate that reads only the bytes it needs.
  static Future<Uint8List> previewBytes(File file, {int minLongSide = 0}) async {
    final path = file.path;
    final bytes = await Isolate.run(
      () => RawPreview.previewImage(path, minLongSide: minLongSide),
    );
    if (bytes == null) throw const RawPreviewUnavailable();
    return bytes;
  }

  /// Format, raw size, preview size and camera EXIF for the info panel.
  static Future<Map<String, String>> details(File file) {
    final path = file.path;
    return Isolate.run(() {
      try {
        return RawPreview.describe(RawPreview.inspect(path));
      } catch (_) {
        return const <String, String>{};
      }
    });
  }
}

/// [ImageProvider] for the embedded preview of a camera raw file. The
/// engine decodes the JPEG (and applies its orientation), so wrapping it in
/// a [ResizeImage] decodes at screen size.
@immutable
class RawPreviewImage extends ImageProvider<RawPreviewImage> {
  const RawPreviewImage(this.file);

  final File file;

  @override
  Future<RawPreviewImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    RawPreviewImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: file.path,
      informationCollector: () => [
        DiagnosticsProperty<ImageProvider>('Image provider', this),
      ],
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await RawImages.previewBytes(file);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is RawPreviewImage && other.file.path == file.path;

  @override
  int get hashCode => file.path.hashCode;

  @override
  String toString() => 'RawPreviewImage("${file.path}")';
}
