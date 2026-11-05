import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/exif_bytes.dart';
import 'package:folder/core/formats/exif_jpeg.dart';
import 'package:folder/core/formats/exif_tiff.dart';

/// A JPEG image embedded in a camera raw file.
class RawJpeg {
  const RawJpeg({
    required this.offset,
    required this.length,
    required this.source,
    required this.info,
    required this.endVerified,
    this.damagedSoi = false,
  });

  final int offset;
  final int length;

  /// Where it was found, e.g. "IFD0", "SubIFD 1", "CR3 PRVW".
  final String source;
  final JpegInfo info;

  /// An EOI marker was found where the container said the JPEG ends.
  final bool endVerified;

  /// The first byte must be rewritten to 0xFF (Epson R-D1 quirk).
  final bool damagedSoi;

  int get width => info.width;
  int get height => info.height;
  int get pixels => info.width * info.height;
  int get longSide => math.max(info.width, info.height);

  @override
  String toString() =>
      '$source ${info.width}x${info.height} @$offset+$length'
      '${endVerified ? '' : ' (no EOI)'}';
}

/// An uncompressed 8-bit RGB thumbnail (older and medium-format raws that
/// carry no JPEG at all, e.g. Hasselblad 3FR, Phase One IIQ, Epson ERF).
class RawRgbThumbnail {
  const RawRgbThumbnail(this.offset, this.width, this.height, this.source);

  final int offset;
  final int width;
  final int height;
  final String source;

  @override
  String toString() => '$source RGB ${width}x$height @$offset';
}

/// What [RawPreview.inspect] learned about a camera raw file.
class RawPreviewResult {
  RawPreviewResult({
    required this.format,
    required this.candidates,
    required this.orientation,
    required this.details,
    this.rgbThumbnail,
    this.rawWidth,
    this.rawHeight,
    this.bytesRead = 0,
  });

  /// Human-readable container name, e.g. "Canon CR3".
  final String format;

  /// Displayable embedded JPEGs, best (largest) first.
  final List<RawJpeg> candidates;

  /// Used only when there is no JPEG.
  final RawRgbThumbnail? rgbThumbnail;

  /// EXIF orientation (1–8) to apply to the previews.
  final int orientation;

  /// Camera metadata: label → value.
  final Map<String, String> details;

  /// Size of the full-resolution image the raw holds, when known.
  final int? rawWidth, rawHeight;

  /// Bytes read from disk while inspecting (diagnostics).
  final int bytesRead;

  RawJpeg? get best => candidates.isEmpty ? null : candidates.first;

  /// The smallest preview whose long side is at least [minLongSide], else
  /// the largest one. Useful for thumbnails.
  RawJpeg? pick({int minLongSide = 0}) {
    if (candidates.isEmpty) return null;
    if (minLongSide <= 0) return candidates.first;
    RawJpeg? choice;
    for (final c in candidates) {
      if (c.longSide >= minLongSide &&
          (choice == null || c.pixels < choice.pixels)) {
        choice = c;
      }
    }
    return choice ?? candidates.first;
  }

  bool get hasPreview => candidates.isNotEmpty || rgbThumbnail != null;

  /// Preview size as displayed (after orientation).
  (int, int)? get previewSize {
    final b = best;
    if (b != null) {
      return JpegUtil.orientedSize(b.width, b.height, orientation);
    }
    final t = rgbThumbnail;
    if (t != null) return JpegUtil.orientedSize(t.width, t.height, orientation);
    return null;
  }
}

/// Extracts the JPEG previews cameras embed in raw files, and their EXIF
/// details, reading only the structures and byte ranges it needs. The raw
/// sensor data is never decoded.
///
/// All methods are synchronous; run them in a background isolate.
abstract final class RawPreview {
  /// Inspects the raw file at [path].
  static RawPreviewResult inspect(String path) {
    final src = FileRandomBytes.open(path);
    try {
      return inspectSource(src, extension: _extension(path));
    } finally {
      src.close();
    }
  }

  static RawPreviewResult inspectSource(RandomBytes src, {String? extension}) {
    final scanner = _RawScanner(src, (extension ?? '').toLowerCase());
    scanner.run();
    return scanner.result();
  }

  /// The best embedded preview of [path], encoded so that it displays
  /// upright: a JPEG whose EXIF orientation is set from the raw file, or (for
  /// raws with only an uncompressed thumbnail) an already-rotated BMP. With
  /// [minLongSide], the smallest JPEG at least that big (for thumbnails).
  /// Null when the file has no usable preview.
  static Uint8List? previewImage(String path, {int minLongSide = 0}) {
    final src = FileRandomBytes.open(path);
    try {
      final result =
          RawPreview.inspectSource(src, extension: _extension(path));
      return previewFrom(src, result, minLongSide: minLongSide);
    } finally {
      src.close();
    }
  }

  /// [previewImage] for an already inspected [src].
  static Uint8List? previewFrom(
    RandomBytes src,
    RawPreviewResult result, {
    int minLongSide = 0,
  }) {
    final jpeg = result.pick(minLongSide: minLongSide);
    if (jpeg != null) {
      final bytes = Uint8List.fromList(src.read(jpeg.offset, jpeg.length));
      if (bytes.length < 4) return null;
      if (jpeg.damagedSoi) bytes[0] = 0xFF;
      return JpegUtil.withOrientation(bytes, result.orientation);
    }
    final t = result.rgbThumbnail;
    if (t == null) return null;
    final rgb = src.read(t.offset, t.width * t.height * 3);
    if (rgb.length < t.width * t.height * 3) return null;
    return _rgbToBmp(rgb, t.width, t.height, result.orientation);
  }

  /// 24-bit BMP of packed RGB [rgb], with EXIF [orientation] applied (BMP
  /// has no orientation tag).
  static Uint8List _rgbToBmp(Uint8List rgb, int w, int h, int orientation) {
    final swap = orientation >= 5;
    final ow = swap ? h : w, oh = swap ? w : h;
    final stride = (ow * 3 + 3) & ~3;
    final size = 54 + stride * oh;
    final out = Uint8List(size);
    final bd = ByteData.sublistView(out);
    out[0] = 0x42;
    out[1] = 0x4D;
    bd.setUint32(2, size, Endian.little);
    bd.setUint32(10, 54, Endian.little);
    bd.setUint32(14, 40, Endian.little);
    bd.setInt32(18, ow, Endian.little);
    bd.setInt32(22, -oh, Endian.little); // top-down rows
    bd.setUint16(26, 1, Endian.little);
    bd.setUint16(28, 24, Endian.little);
    bd.setUint32(34, stride * oh, Endian.little);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final (ox, oy) = switch (orientation) {
          2 => (w - 1 - x, y),
          3 => (w - 1 - x, h - 1 - y),
          4 => (x, h - 1 - y),
          5 => (y, x),
          6 => (h - 1 - y, x),
          7 => (h - 1 - y, w - 1 - x),
          8 => (y, w - 1 - x),
          _ => (x, y),
        };
        final s = (y * w + x) * 3;
        final d = 54 + oy * stride + ox * 3;
        out[d] = rgb[s + 2];
        out[d + 1] = rgb[s + 1];
        out[d + 2] = rgb[s];
      }
    }
    return out;
  }

  /// [RawPreviewResult.details] plus the format, raw size and a note that
  /// the viewer shows the embedded preview.
  static Map<String, String> describe(RawPreviewResult r) {
    final out = <String, String>{'Format': '${r.format} (camera raw)'};
    if (r.rawWidth != null && r.rawHeight != null) {
      final (w, h) =
          JpegUtil.orientedSize(r.rawWidth!, r.rawHeight!, r.orientation);
      out['Raw size'] = '$w × $h (${(w * h / 1e6).toStringAsFixed(1)} MP)';
    }
    final size = r.previewSize;
    out['Preview'] = size == null
        ? 'No embedded preview'
        : 'Showing embedded preview ${size.$1} × ${size.$2}. '
            'Full raw resolution needs a raw editor.';
    out.addAll(r.details);
    return out;
  }

  static String _extension(String path) {
    final slash = math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    final dot = path.lastIndexOf('.');
    return dot > slash ? path.substring(dot + 1).toLowerCase() : '';
  }
}

class _RawScanner {
  _RawScanner(this.src, this.extension);

  final RandomBytes src;
  final String extension;
  final List<RawJpeg> _found = [];
  RawRgbThumbnail? _rgb;
  final Set<int> _seenJpegs = {};
  final Set<int> _visitedIfds = {};
  final ExifSummary _exif = ExifSummary();
  String _format = 'Camera raw';
  int? _orientation;
  int? _rawW, _rawH;
  int? _cropW, _cropH;
  int _rawArea = 0;

  static const _minJpegBytes = 512;

  void run() {
    final head = src.read(0, 64);
    try {
      if (_startsWith(head, 'FUJIFILMCCD-RAW')) {
        _format = 'Fujifilm RAF';
        _raf();
      } else if (head.length >= 12 &&
          _ascii(head, 4, 4) == 'ftyp' &&
          _ascii(head, 8, 4) == 'crx ') {
        _format = 'Canon CR3';
        _cr3();
      } else if (head.length >= 14 &&
          head[0] == 0x49 &&
          head[1] == 0x49 &&
          _ascii(head, 6, 8) == 'HEAPCCDR') {
        _format = 'Canon CRW';
        _crw();
      } else if (_startsWith(head, 'FOVb')) {
        _format = 'Sigma X3F';
        _x3f();
      } else {
        final tiff = TiffReader.at(src, 0);
        if (tiff != null) {
          _format = _tiffFormatName(head);
          _walkTiff(tiff);
        }
      }
    } catch (_) {
      // Damaged structures: fall through to the scan below.
    }
    // Nothing usable from the structure (unknown layout, generic .raw,
    // damaged file): look for JPEG streams directly.
    // Embedded JPEGs sit near the start in the layouts seen so far, so the
    // scan is bounded; less so when an uncompressed thumbnail was found.
    if (!_found.any((j) => j.longSide >= 640 && j.endVerified)) {
      _scanForJpegs(limit: _rgb == null ? 48 << 20 : 8 << 20);
    }
    // The previews' own EXIF fills gaps (RAF, RW2 and X3F keep camera
    // settings there).
    for (final j in _sorted()) {
      _exifFromJpeg(j.info);
    }
  }

  List<RawJpeg> _sorted() {
    final list = [..._found];
    list.sort((a, b) {
      if (a.endVerified != b.endVerified) return a.endVerified ? -1 : 1;
      final byPixels = b.pixels.compareTo(a.pixels);
      return byPixels != 0 ? byPixels : b.length.compareTo(a.length);
    });
    return list;
  }

  RawPreviewResult result() {
    final candidates = _sorted();
    var orientation = _orientation ?? _exif.orientation ?? 1;
    if (orientation < 1 || orientation > 8) orientation = 1;
    // DNG's crop is exact. The EXIF pixel size is what the camera renders,
    // unless it merely describes a preview (Sony SR2 says 640x424); then
    // the raw image data's own size is better.
    int? w = _cropW, h = _cropH;
    final ew = _exif.pixelWidth, eh = _exif.pixelHeight;
    final largest = candidates.isEmpty ? 0 : candidates.first.pixels;
    if (w == null &&
        ew != null &&
        eh != null &&
        ew * eh >= largest &&
        ew * eh * 2 >= _rawArea) {
      w = ew;
      h = eh;
    }
    if (w == null && _rawW != null && _rawArea >= largest) {
      w = _rawW;
      h = _rawH;
    }
    if (w == null || h == null || w <= 0 || h <= 0) {
      w = h = null;
    }
    return RawPreviewResult(
      format: _format,
      candidates: candidates,
      rgbThumbnail: candidates.isEmpty ? _rgb : null,
      orientation: orientation,
      details: Map.of(_exif.values),
      rawWidth: w,
      rawHeight: h,
      bytesRead: src is FileRandomBytes ? (src as FileRandomBytes).bytesRead : 0,
    );
  }

  // ---------------------------------------------------------------- JPEGs

  void _addJpeg(
    int offset,
    int length,
    String source, {
    bool damagedSoi = false,
  }) {
    if (offset <= 0 || offset >= src.length || length < _minJpegBytes) return;
    if (!_seenJpegs.add(offset)) return;
    length = math.min(length, src.length - offset);
    final info = JpegUtil.parseHeader(src, offset, damagedSoi: damagedSoi);
    if (info == null) return;
    if (!info.isDisplayable) {
      _noteRawJpeg(info);
      return;
    }
    final trimmed = JpegUtil.trimmedLength(src, offset, length);
    _found.add(RawJpeg(
      offset: offset,
      length: trimmed ?? length,
      source: source,
      info: info,
      endVerified: trimmed != null,
      damagedSoi: damagedSoi,
    ));
  }

  /// A lossless JPEG is the raw data itself (CR2, some DNG/NEF): its frame
  /// size is the raw size, times the components for Canon's interleaving.
  void _noteRawJpeg(JpegInfo info) {
    if (info.sof != 0xC3) return;
    _noteRawSize(info.width * info.components, info.height);
  }

  void _noteRawSize(int w, int h) {
    if (w <= 0 || h <= 0 || w > 100000 || h > 100000) return;
    if (w * h > _rawArea) {
      _rawArea = w * h;
      _rawW = w;
      _rawH = h;
    }
  }

  void _exifFromJpeg(JpegInfo info) {
    final at = info.exifOffset;
    if (at == null) return;
    final r = TiffReader.at(src, at);
    if (r == null) return;
    final before = _exif.orientation;
    final (pw, ph) = (_exif.pixelWidth, _exif.pixelHeight);
    _exif.addTiff(r);
    // The raw's own orientation wins; the preview's only fills a gap
    // (RAF and X3F have no other). Its pixel size is the preview's own.
    if (before != null) _exif.orientation = before;
    _exif
      ..pixelWidth = pw
      ..pixelHeight = ph;
  }

  /// Last resort: finds displayable JPEG streams by their markers.
  void _scanForJpegs({required int limit}) {
    const chunk = 1 << 20;
    limit = math.min(src.length, limit);
    var pos = 0;
    var found = 0;
    while (pos < limit && found < 16) {
      final b = src.read(pos, math.min(chunk + 2, limit - pos));
      if (b.length < 3) break;
      var next = pos + chunk;
      for (var i = 0; i + 2 < b.length && i < chunk; i++) {
        if (b[i] != 0xFF || b[i + 1] != 0xD8 || b[i + 2] != 0xFF) continue;
        final at = pos + i;
        if (_seenJpegs.contains(at)) continue;
        final info = JpegUtil.parseHeader(src, at);
        if (info == null || !info.isDisplayable || info.scanOffset == null) {
          continue;
        }
        final end = JpegUtil.findEnd(src, info.scanOffset!, 96 << 20);
        if (end < 0) continue;
        _seenJpegs.add(at);
        if (end - at >= _minJpegBytes) {
          _found.add(RawJpeg(
            offset: at,
            length: end - at,
            source: 'scan',
            info: info,
            endVerified: true,
          ));
          found++;
        }
        next = end;
        break;
      }
      pos = math.max(next, pos + 1);
    }
  }

  // ----------------------------------------------------------------- TIFF

  String _tiffFormatName(Uint8List head) {
    if (head.length >= 10 && head[8] == 0x43 && head[9] == 0x52) {
      return 'Canon CR2';
    }
    if (head.length >= 4 && head[2] == 0x52 && head[3] == 0x4F) {
      return 'Olympus ORF';
    }
    if (head.length >= 4 && head[2] == 0x55) {
      return extension == 'rwl' ? 'Leica RWL' : 'Panasonic RW2';
    }
    return switch (extension) {
      'dng' => 'DNG',
      'cr2' => 'Canon CR2',
      'nef' => 'Nikon NEF',
      'nrw' => 'Nikon NRW',
      'arw' => 'Sony ARW',
      'srf' => 'Sony SRF',
      'sr2' => 'Sony SR2',
      'orf' => 'Olympus ORF',
      'pef' => 'Pentax PEF',
      'srw' => 'Samsung SRW',
      '3fr' => 'Hasselblad 3FR',
      'iiq' => 'Phase One IIQ',
      'erf' => 'Epson ERF',
      'mef' => 'Mamiya MEF',
      'mos' => 'Leaf MOS',
      'dcr' => 'Kodak DCR',
      'kdc' => 'Kodak KDC',
      'rw2' => 'Panasonic RW2',
      'rwl' => 'Leica RWL',
      _ => 'TIFF-based raw',
    };
  }

  void _walkTiff(TiffReader r) {
    var off = r.firstIfdOffset;
    TiffIfd? ifd0;
    for (var index = 0; off > 0 && index < 16; index++) {
      if (!_visitedIfds.add(r.base + off)) break;
      final ifd = r.readIfd(off);
      if (ifd == null) break;
      ifd0 ??= ifd;
      _walkIfd(r, ifd, 'IFD$index', 0);
      off = ifd.next;
    }
    if (ifd0 != null) {
      _exif.addImageIfd(r, ifd0);
      if (_format.startsWith('Panasonic') || _format.startsWith('Leica')) {
        // Panasonic keeps the sensor area as borders in IFD0.
        final top = r.intOf(ifd0, 0x0004), left = r.intOf(ifd0, 0x0005);
        final bottom = r.intOf(ifd0, 0x0006), right = r.intOf(ifd0, 0x0007);
        if (top != null && left != null && bottom != null && right != null) {
          _noteRawSize(right - left, bottom - top);
        }
      }
      if (r.stringOf(ifd0, TiffTag.dngVersion) != null ||
          ifd0.has(TiffTag.dngVersion)) {
        _format = 'DNG';
      }
    }
  }

  /// Collects the JPEGs [ifd] points to. In a [makerNote] tags only mean
  /// what the vendor says, so only validated JPEGs are taken from it.
  void _walkIfd(
    TiffReader r,
    TiffIfd ifd,
    String name,
    int depth, {
    bool makerNote = false,
  }) {
    if (depth > 5) return;
    final compression = r.intOf(ifd, TiffTag.compression);
    var holdsPreview = false;

    // Classic thumbnail/preview pointers.
    final jo = r.intOf(ifd, TiffTag.jpegOffset);
    final jl = r.intOf(ifd, TiffTag.jpegLength);
    if (jo != null && jl != null && jo > 0 && jl > 0) {
      final before = _found.length;
      _addJpeg(r.base + jo, jl, name);
      holdsPreview = _found.length > before;
    }

    // Strip-based JPEG (CR2 IFD0, DNG previews, NEF JpgFromRaw...).
    if ((compression == 6 || compression == 7 || compression == 99) &&
        ifd.has(TiffTag.stripOffsets)) {
      final offsets = r.ints(ifd[TiffTag.stripOffsets]!, max: 64);
      final counts = ifd.has(TiffTag.stripByteCounts)
          ? r.ints(ifd[TiffTag.stripByteCounts]!, max: 64)
          : const <int>[];
      if (offsets.isNotEmpty && counts.length == offsets.length) {
        // Usable only as one contiguous stream.
        var contiguous = true;
        for (var i = 1; i < offsets.length; i++) {
          if (offsets[i] != offsets[i - 1] + counts[i - 1]) contiguous = false;
        }
        if (contiguous) {
          final total = counts.fold<int>(0, (a, b) => a + b);
          final before = _found.length;
          _addJpeg(r.base + offsets.first, total, name);
          holdsPreview = holdsPreview || _found.length > before;
        }
      }
    }

    // Uncompressed 8-bit RGB thumbnail: a fallback for raws without JPEGs.
    if (!makerNote &&
        compression == 1 &&
        r.intOf(ifd, TiffTag.photometric) == 2 &&
        r.intOf(ifd, 0x0115) == 3 &&
        (r.intOf(ifd, 0x011C) ?? 1) == 1) {
      final bits = ifd[0x0102] == null ? const <int>[] : r.ints(ifd[0x0102]!);
      final tw = r.intOf(ifd, TiffTag.imageWidth) ?? 0;
      final th = r.intOf(ifd, TiffTag.imageHeight) ?? 0;
      final offsets = ifd.has(TiffTag.stripOffsets)
          ? r.ints(ifd[TiffTag.stripOffsets]!, max: 1024)
          : const <int>[];
      final counts = ifd.has(TiffTag.stripByteCounts)
          ? r.ints(ifd[TiffTag.stripByteCounts]!, max: 1024)
          : const <int>[];
      var contiguous = offsets.isNotEmpty && counts.length == offsets.length;
      for (var i = 1; contiguous && i < offsets.length; i++) {
        contiguous = offsets[i] == offsets[i - 1] + counts[i - 1];
      }
      final total = counts.fold<int>(0, (a, b) => a + b);
      final current = _rgb;
      if (bits.length == 3 &&
          bits.every((b) => b == 8) &&
          tw > 0 &&
          th > 0 &&
          tw * th <= 4 * 1024 * 1024 &&
          contiguous &&
          total >= tw * th * 3 &&
          r.base + offsets.first + tw * th * 3 <= src.length &&
          (current == null || tw * th > current.width * current.height)) {
        _rgb = RawRgbThumbnail(r.base + offsets.first, tw, th, name);
        holdsPreview = true;
      }
    }

    // Sizes of the raw image data (anything that isn't a preview).
    final w = r.intOf(ifd, TiffTag.imageWidth);
    final h = r.intOf(ifd, TiffTag.imageHeight);
    final subfile = r.intOf(ifd, TiffTag.newSubfileType);
    if (w != null && h != null && !holdsPreview && !makerNote) {
      if (subfile == 0 || subfile == null) _noteRawSize(w, h);
      if (subfile == 0) {
        final crop = ifd[TiffTag.defaultCropSize];
        if (crop != null) {
          final v = r.doubles(crop, max: 2);
          if (v.length == 2 && v[0] > 0 && v[1] > 0) {
            _cropW ??= v[0].round();
            _cropH ??= v[1].round();
          }
        }
      }
    }

    // Large opaque values that are JPEGs: Panasonic JpgFromRaw (0x002E),
    // Sony PreviewImage (0x2001), Olympus/Kodak/Leaf preview blobs...
    for (final e in ifd.entries.values) {
      if ((e.type != 7 && e.type != 1) ||
          e.count < 2048 ||
          e.tag == TiffTag.makerNote) {
        continue;
      }
      final label = '$name tag 0x${e.tag.toRadixString(16).padLeft(4, '0')}';
      if (src.matches(e.valueOffset, const [0xFF, 0xD8, 0xFF])) {
        _addJpeg(e.valueOffset, e.count, label);
      } else if (makerNote &&
          e.tag == 0x0280 &&
          src.matches(e.valueOffset + 1, const [0xD8, 0xFF])) {
        // Epson R-D1 PreviewImage: its first byte is stored as 0xEE.
        _addJpeg(e.valueOffset, e.count, label, damagedSoi: true);
      }
    }

    if (makerNote) return;

    // Child IFDs.
    var i = 0;
    for (final p in r.pointers(ifd, TiffTag.subIfds)) {
      if (!_visitedIfds.add(r.base + p)) continue;
      final sub = r.readIfd(p);
      if (sub != null) _walkIfd(r, sub, '$name/SubIFD${i++}', depth + 1);
    }
    for (final p in r.pointers(ifd, TiffTag.exifIfd).take(1)) {
      if (!_visitedIfds.add(r.base + p)) continue;
      final exif = r.readIfd(p);
      if (exif == null) continue;
      _exif.addExifIfd(r, exif);
      _walkIfd(r, exif, 'EXIF', depth + 1);
      final note = exif[TiffTag.makerNote];
      if (note != null) _makerNote(r, note);
    }
    for (final p in r.pointers(ifd, TiffTag.gpsIfd).take(1)) {
      _exif.addGpsIfd(r, r.readIfd(p));
    }
    // A maker note can also sit in IFD0 (some Kodak/Leaf files).
    final note = depth == 0 ? ifd[TiffTag.makerNote] : null;
    if (note != null) _makerNote(r, note);
  }

  void _makerNote(TiffReader r, TiffEntry note) {
    final start = note.valueOffset;
    final head = src.read(start, 18);
    if (head.length < 12) return;

    // Nikon type 3: "Nikon\0" + version, then a TIFF header of its own.
    if (_startsWith(head, 'Nikon\u0000')) {
      final mr = TiffReader.at(src, start + 10);
      if (mr == null) return;
      final ifd = mr.readIfd(mr.firstIfdOffset);
      if (ifd == null) return;
      for (final p in mr.pointers(ifd, 0x0011).take(1)) {
        final preview = mr.readIfd(p);
        if (preview != null) {
          _walkIfd(mr, preview, 'Nikon preview', 3, makerNote: true);
        }
      }
      return;
    }

    // Olympus / OM System.
    if (_startsWith(head, 'OLYMPUS\u0000') || _startsWith(head, 'OM SYSTEM')) {
      final ifdAt = _startsWith(head, 'OM SYSTEM') ? 16 : 12;
      final le = head[ifdAt - 4] == 0x49;
      final mr = TiffReader(src, base: start, littleEndian: le);
      _olympus(mr, mr.readIfd(ifdAt));
      return;
    }
    if (_startsWith(head, 'OLYMP\u0000') || _startsWith(head, 'EPSON\u0000')) {
      final mr = TiffReader(src, base: r.base, littleEndian: r.littleEndian);
      _olympus(mr, mr.readIfd(start + 8 - r.base));
      return;
    }

    // Pentax: "AOC\0" + byte order, or "PENTAX \0" + byte order.
    if (_startsWith(head, 'AOC\u0000') || _startsWith(head, 'PENTAX ')) {
      final pentax = _startsWith(head, 'PENTAX ');
      final orderAt = pentax ? 8 : 4;
      final le = head[orderAt] == 0x49;
      final ifdAt = orderAt + 2;
      // Offsets are relative to the maker note in newer files and to the
      // TIFF header in older ones: try both, the JPEG check decides.
      for (final base in [start, r.base]) {
        final mr = TiffReader(src, base: base, littleEndian: le);
        final ifd = mr.readIfd(start + ifdAt - base);
        if (ifd == null) continue;
        final len = mr.intOf(ifd, 0x0003);
        final off = mr.intOf(ifd, 0x0004);
        if (len != null && off != null) {
          final before = _found.length;
          _addJpeg(base + off, len, 'Pentax preview');
          if (_found.length > before) break;
          _seenJpegs.remove(base + off);
        }
      }
      return;
    }

    // Sony / Panasonic / others with a plain IFD after a short header, or
    // a bare IFD (Canon, Samsung): look for embedded JPEG blobs.
    final int ifdAt;
    if (_startsWith(head, 'SONY ') || _startsWith(head, 'Panasonic')) {
      ifdAt = 12;
    } else {
      ifdAt = 0;
    }
    final mr = TiffReader(src, base: r.base, littleEndian: r.littleEndian);
    final ifd = mr.readIfd(start + ifdAt - r.base, maxEntries: 400);
    if (ifd != null) _walkIfd(mr, ifd, 'MakerNote', 4, makerNote: true);
  }

  void _olympus(TiffReader mr, TiffIfd? ifd) {
    if (ifd == null) return;
    // Old style: PreviewImageStart/Length in the main maker note IFD.
    final oldStart = mr.intOf(ifd, 0x0088), oldLen = mr.intOf(ifd, 0x0089);
    if (oldStart != null && oldLen != null) {
      _addJpeg(mr.base + oldStart, oldLen, 'Olympus preview');
    }
    // New style: CameraSettings sub-IFD 0x2020 → 0x0101/0x0102.
    for (final p in mr.pointers(ifd, 0x2020).take(1)) {
      final settings = mr.readIfd(p);
      if (settings == null) continue;
      final valid = mr.intOf(settings, 0x0100);
      final start = mr.intOf(settings, 0x0101);
      final len = mr.intOf(settings, 0x0102);
      if (valid != 0 && start != null && len != null) {
        _addJpeg(mr.base + start, len, 'Olympus preview');
      }
    }
    _walkIfd(mr, ifd, 'Olympus maker note', 4, makerNote: true);
  }

  // ------------------------------------------------------------------ RAF

  void _raf() {
    _exif.values['Camera model'] = asciiz(src.read(28, 32));
    final jpegOffset = src.u32(84, littleEndian: false);
    final jpegLength = src.u32(88, littleEndian: false);
    _addJpeg(jpegOffset, jpegLength, 'RAF preview');
    // Raw dimensions from the CFA header records.
    final hdr = src.u32(92, littleEndian: false);
    final hdrLen = src.u32(96, littleEndian: false);
    if (hdr > 0 && hdrLen > 4 && hdr + hdrLen <= src.length) {
      final count = src.u32(hdr, littleEndian: false);
      var pos = hdr + 4;
      int? fullW, fullH, cropW, cropH;
      for (var i = 0; i < count && i < 256 && pos + 4 <= hdr + hdrLen; i++) {
        final tag = src.u16(pos, littleEndian: false);
        final size = src.u16(pos + 2, littleEndian: false);
        if (size >= 4 && (tag == 0x100 || tag == 0x111)) {
          final h = src.u16(pos + 4, littleEndian: false);
          final w = src.u16(pos + 6, littleEndian: false);
          if (tag == 0x100) {
            fullW = w;
            fullH = h;
          } else {
            cropW = w;
            cropH = h;
          }
        }
        pos += 4 + size;
      }
      final w = cropW ?? fullW, h = cropH ?? fullH;
      if (w != null && h != null) _noteRawSize(w, h);
    }
  }

  // ------------------------------------------------------------------ CR3

  static const _canonUuid = '85c0b687820f11e08111f4ce462b6a48';
  static const _previewUuid = 'eaf42b5e1c984b88b9fbb7dc406e4d16';

  void _cr3() {
    for (final box in _boxes(0, src.length)) {
      if (box.type == 'moov') {
        var track = 0;
        for (final child in _boxes(box.payload, box.end)) {
          if (child.type == 'uuid' && _uuid(child.payload) == _canonUuid) {
            _cr3Canon(child.payload + 16, child.end);
          } else if (child.type == 'trak') {
            _cr3Track(child, ++track);
          }
        }
      } else if (box.type == 'uuid' && _uuid(box.payload) == _previewUuid) {
        // 16-byte uuid, 8 bytes of version info, then the PRVW box.
        final at = src.indexOf(ascii.encode('PRVW'),
            start: box.payload + 16, end: math.min(box.end, box.payload + 64));
        if (at >= 4) {
          final size = src.u32(at - 4, littleEndian: false);
          _jpegInBox(at - 4, math.min(box.end, at - 4 + size), 'CR3 PRVW');
        }
      }
    }
    _format = 'Canon CR3';
  }

  void _cr3Canon(int start, int end) {
    for (final box in _boxes(start, end)) {
      switch (box.type) {
        case 'CMT1':
          final r = TiffReader.at(src, box.payload);
          if (r != null) {
            final ifd = r.readIfd(r.firstIfdOffset);
            _exif.addImageIfd(r, ifd);
            final w = r.intOf(ifd, TiffTag.imageWidth);
            final h = r.intOf(ifd, TiffTag.imageHeight);
            if (w != null && h != null) _noteRawSize(w, h);
          }
        case 'CMT2':
          final r = TiffReader.at(src, box.payload);
          if (r != null) _exif.addExifIfd(r, r.readIfd(r.firstIfdOffset));
        case 'CMT4':
          final r = TiffReader.at(src, box.payload);
          if (r != null) _exif.addGpsIfd(r, r.readIfd(r.firstIfdOffset));
        case 'THMB':
          _jpegInBox(box.start, box.end, 'CR3 THMB');
      }
    }
  }

  /// Track 1 of a CR3 holds the full-size JPEG the camera rendered.
  void _cr3Track(_Box trak, int index) {
    final stbl = _find(trak, const ['mdia', 'minf', 'stbl']);
    if (stbl == null) return;
    int? offset, size, width, height;
    for (final box in _boxes(stbl.payload, stbl.end)) {
      switch (box.type) {
        case 'stsd':
          final entry = box.payload + 8;
          width = src.u16(entry + 32, littleEndian: false);
          height = src.u16(entry + 34, littleEndian: false);
        case 'co64':
          if (src.u32(box.payload + 4, littleEndian: false) > 0) {
            final hi = src.u32(box.payload + 8, littleEndian: false);
            final lo = src.u32(box.payload + 12, littleEndian: false);
            offset = hi * 0x100000000 + lo;
          }
        case 'stco':
          if (src.u32(box.payload + 4, littleEndian: false) > 0) {
            offset = src.u32(box.payload + 8, littleEndian: false);
          }
        case 'stsz':
          final fixed = src.u32(box.payload + 4, littleEndian: false);
          size = fixed > 0
              ? fixed
              : src.u32(box.payload + 12, littleEndian: false);
      }
    }
    if (offset == null || size == null || size <= 0) return;
    if (src.matches(offset, const [0xFF, 0xD8, 0xFF])) {
      _addJpeg(offset, size, 'CR3 track $index');
    } else if (width != null && height != null && width > 0) {
      _noteRawSize(width, height);
    }
  }

  /// A JPEG inside a box with a small header whose last field is the
  /// JPEG's length (CR3 THMB/PRVW).
  void _jpegInBox(int start, int end, String label) {
    final head = src.read(start, 64);
    final i = indexOfBytes(head, const [0xFF, 0xD8, 0xFF]);
    if (i < 0) return;
    final at = start + i;
    var length = end - at;
    if (i >= 4) {
      final declared = src.u32(at - 4, littleEndian: false);
      if (declared > 0 && declared <= length) length = declared;
    }
    _addJpeg(at, length, label);
  }

  Iterable<_Box> _boxes(int start, int end) sync* {
    var pos = start;
    for (var guard = 0; pos + 8 <= end && guard < 4096; guard++) {
      var size = src.u32(pos, littleEndian: false);
      final type = _ascii(src.read(pos + 4, 4), 0, 4);
      var header = 8;
      if (size == 1) {
        final hi = src.u32(pos + 8, littleEndian: false);
        final lo = src.u32(pos + 12, littleEndian: false);
        size = hi * 0x100000000 + lo;
        header = 16;
      } else if (size == 0) {
        size = end - pos;
      }
      if (size < header || pos + size > end) return;
      yield _Box(type, pos, pos + header, pos + size);
      pos += size;
    }
  }

  _Box? _find(_Box parent, List<String> path) {
    var current = parent;
    for (final name in path) {
      _Box? next;
      for (final b in _boxes(current.payload, current.end)) {
        if (b.type == name) {
          next = b;
          break;
        }
      }
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  String _uuid(int at) {
    final b = src.read(at, 16);
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  // ------------------------------------------------------------------ CRW

  void _crw() {
    final headerLength = src.u32(2, littleEndian: true);
    if (headerLength <= 0 || headerLength >= src.length) return;
    _ciffHeap(headerLength, src.length, 0);
  }

  void _ciffHeap(int start, int end, int depth) {
    if (depth > 6 || end - start < 6) return;
    final dirOffset = src.u32(end - 4, littleEndian: true);
    final dir = start + dirOffset;
    if (dirOffset <= 0 || dir + 2 > end) return;
    final count = src.u16(dir, littleEndian: true);
    if (count <= 0 || count > 1024) return;
    final entries = src.read(dir + 2, count * 10);
    final data = ByteData.sublistView(entries);
    for (var i = 0; i < count && (i + 1) * 10 <= entries.length; i++) {
      final tag = data.getUint16(i * 10, Endian.little);
      final size = data.getUint32(i * 10 + 2, Endian.little);
      final offset = data.getUint32(i * 10 + 6, Endian.little);
      final inRecord = tag & 0xC000 == 0x4000;
      final type = tag & 0x3800;
      final id = tag & 0x3FFF;
      final at = inRecord ? dir + 2 + i * 10 + 2 : start + offset;
      final len = inRecord ? 8 : size;
      if (!inRecord && (at < start || at + len > end)) continue;
      if (type == 0x2800 || type == 0x3000) {
        _ciffHeap(at, at + len, depth + 1);
        continue;
      }
      switch (id) {
        case 0x2007:
          _addJpeg(at, len, 'CRW JpgFromRaw');
        case 0x080A:
          final parts = latin1
              .decode(src.read(at, math.min(len, 256)))
              .split('\u0000')
              .where((s) => s.trim().isNotEmpty)
              .toList();
          if (parts.isNotEmpty) _exif.values['Camera make'] = parts[0].trim();
          if (parts.length > 1) _exif.values['Camera model'] = parts[1].trim();
        case 0x1810:
          final w = src.u32(at, littleEndian: true);
          final h = src.u32(at + 4, littleEndian: true);
          _noteRawSize(w, h);
          final rotation = src.read(at + 12, 4);
          if (rotation.length == 4) {
            final deg = ByteData.sublistView(rotation).getInt32(0, Endian.little);
            _orientation = _orientationForDegrees(deg);
          }
        case 0x180E:
          final t = src.u32(at, littleEndian: true);
          if (t > 0) {
            final d = DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true);
            _exif.values['Taken'] = _formatDate(d);
          }
        case 0x080B:
          final fw = asciiz(src.read(at, math.min(len, 64)));
          if (fw.isNotEmpty) _exif.values['Firmware'] = fw;
      }
    }
  }

  // ------------------------------------------------------------------ X3F

  void _x3f() {
    final cols = src.u32(28, littleEndian: true);
    final rows = src.u32(32, littleEndian: true);
    final rotation = src.u32(36, littleEndian: true);
    if (cols > 0 && rows > 0 && cols < 100000 && rows < 100000) {
      _noteRawSize(cols, rows);
    }
    _orientation = _orientationForDegrees(rotation);
    final dir = src.u32(src.length - 4, littleEndian: true);
    if (dir <= 0 || dir + 12 > src.length || !_matchesAscii(dir, 'SECd')) {
      return;
    }
    final count = src.u32(dir + 8, littleEndian: true);
    for (var i = 0; i < count && i < 64; i++) {
      final e = dir + 12 + i * 12;
      final offset = src.u32(e, littleEndian: true);
      final length = src.u32(e + 4, littleEndian: true);
      final type = _ascii(src.read(e + 8, 4), 0, 4);
      if ((type == 'IMAG' || type == 'IMA2') && _matchesAscii(offset, 'SECi')) {
        final format = src.u32(offset + 12, littleEndian: true);
        if (format == 18) _addJpeg(offset + 28, length - 28, 'X3F preview');
      } else if (type == 'PROP' && _matchesAscii(offset, 'SECp')) {
        _x3fProperties(offset, length);
      }
    }
  }

  void _x3fProperties(int offset, int length) {
    final count = src.u32(offset + 8, littleEndian: true);
    final format = src.u32(offset + 12, littleEndian: true);
    if (format != 0 || count <= 0 || count > 512) return;
    final table = offset + 24;
    final chars = table + count * 8;
    final data = src.read(chars, math.min(length - (chars - offset), 256 * 1024));
    String at(int index) {
      final start = index * 2;
      if (start < 0 || start >= data.length) return '';
      final codes = <int>[];
      for (var i = start; i + 1 < data.length; i += 2) {
        final c = data[i] | data[i + 1] << 8;
        if (c == 0) break;
        codes.add(c);
      }
      return String.fromCharCodes(codes);
    }

    final props = <String, String>{};
    for (var i = 0; i < count; i++) {
      final name = src.u32(table + i * 8, littleEndian: true);
      final value = src.u32(table + i * 8 + 4, littleEndian: true);
      props[at(name)] = at(value);
    }
    void put(String label, String? v) {
      if (v != null && v.trim().isNotEmpty) _exif.values[label] = v.trim();
    }

    put('Camera make', props['CAMMANUF']);
    put('Camera model', props['CAMMODEL']);
    final time = int.tryParse(props['TIME'] ?? '');
    if (time != null && time > 0) {
      put('Taken',
          _formatDate(DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true)));
    }
    final shutter = props['SH_DESC'] ?? props['SHUTTER'];
    if (shutter != null) put('Exposure', '$shutter s');
    final aperture = props['AP_DESC'] ?? props['APERTURE'];
    if (aperture != null) put('Aperture', 'f/$aperture');
    put('ISO', props['ISO']);
    final focal = props['FLENGTH'];
    if (focal != null) put('Focal length', '$focal mm');
    put('Lens', props['LENSMODEL']);
    put('Firmware', props['FIRMVERS']);
  }

  // -------------------------------------------------------------- helpers

  static int _orientationForDegrees(int degrees) =>
      switch (((degrees % 360) + 360) % 360) {
        90 => 6,
        180 => 3,
        270 => 8,
        _ => 1,
      };

  static String _formatDate(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  bool _matchesAscii(int offset, String text) =>
      src.matches(offset, ascii.encode(text));

  static bool _startsWith(Uint8List b, String text) {
    if (b.length < text.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static String _ascii(Uint8List b, int start, int length) {
    if (b.length < start + length) return '';
    return String.fromCharCodes(b.sublist(start, start + length));
  }
}

class _Box {
  const _Box(this.type, this.start, this.payload, this.end);

  final String type;
  final int start;
  final int payload;
  final int end;
}
