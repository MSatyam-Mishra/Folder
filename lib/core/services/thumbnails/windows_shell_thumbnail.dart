import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart';

/// The thumbnail File Explorer shows for [path], [size] pixels on its long
/// side, as JPEG (PNG when it has transparency); null when Windows has
/// none (it doesn't make pictures of a type's icon here). Blocking: run it
/// in a background isolate.
Uint8List? windowsShellThumbnail(String path, int size) {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  try {
    return using((arena) {
      final item = arena<Pointer>();
      final hr = SHCreateItemFromParsingName(
        path.toNativeUtf16(allocator: arena),
        nullptr,
        GUIDFromString(IID_IShellItemImageFactory, allocator: arena),
        item.cast(),
      );
      if (FAILED(hr)) return null;
      final factory = IShellItemImageFactory(item.cast());
      final bitmap = arena<IntPtr>();
      final want = arena<SIZE>()
        ..ref.cx = size
        ..ref.cy = size;
      // Only a real thumbnail; a bigger one is fine (it's scaled anyway).
      final result = factory.getImage(want.ref, SIIGBF_THUMBNAILONLY | SIIGBF_BIGGERSIZEOK, bitmap);
      factory.release();
      if (FAILED(result) || bitmap.value == 0) return null;
      try {
        return _encode(bitmap.value, arena);
      } finally {
        DeleteObject(bitmap.value);
      }
    });
  } catch (_) {
    return null;
  } finally {
    CoUninitialize();
  }
}

/// The bitmap's pixels (top-down BGRA) as JPEG, or PNG with transparency.
Uint8List? _encode(int bitmap, Arena arena) {
  final info = arena<BITMAP>();
  if (GetObject(bitmap, sizeOf<BITMAP>(), info.cast()) == 0) return null;
  final width = info.ref.bmWidth;
  final height = info.ref.bmHeight.abs();
  if (width <= 0 || height <= 0) return null;
  final header = arena<BITMAPINFO>();
  header.ref.bmiHeader
    ..biSize = sizeOf<BITMAPINFOHEADER>()
    ..biWidth = width
    ..biHeight = -height // top-down rows
    ..biPlanes = 1
    ..biBitCount = 32
    ..biCompression = BI_RGB;
  final pixels = arena<Uint8>(width * height * 4);
  final dc = GetDC(NULL);
  final rows = GetDIBits(dc, bitmap, 0, height, pixels.cast(), header, DIB_RGB_COLORS);
  ReleaseDC(NULL, dc);
  if (rows == 0) return null;
  final bytes = Uint8List.fromList(pixels.asTypedList(width * height * 4));
  // Photos and video frames come with no alpha at all (all zero), pictures
  // with transparency with some.
  var anyAlpha = false;
  var allOpaque = true;
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] != 0) anyAlpha = true;
    if (bytes[i] != 255) allOpaque = false;
  }
  final opaque = !anyAlpha || allOpaque;
  if (opaque) {
    for (var i = 3; i < bytes.length; i += 4) {
      bytes[i] = 255;
    }
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: bytes.buffer,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  return opaque ? img.encodeJpg(image, quality: 85) : img.encodePng(image, level: 1);
}
