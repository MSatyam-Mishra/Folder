import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/exif_bytes.dart';

/// One IFD entry: where its value lives is resolved up front.
class TiffEntry {
  const TiffEntry(this.tag, this.type, this.count, this.valueOffset);

  final int tag;
  final int type;
  final int count;

  /// Absolute offset of the value data in the source.
  final int valueOffset;

  int get byteSize => count * TiffReader.typeSize(type);
}

class TiffIfd {
  TiffIfd(this.offset, this.entries, this.next);

  /// Offset relative to the reader's base.
  final int offset;
  final Map<int, TiffEntry> entries;

  /// Relative offset of the next IFD in the chain, 0 for none.
  final int next;

  TiffEntry? operator [](int tag) => entries[tag];
  bool has(int tag) => entries.containsKey(tag);
}

/// Reads TIFF structures (also EXIF blocks, TIFF-based camera raws and
/// maker notes) from [src]. Offsets inside the structure are relative to
/// [base].
class TiffReader {
  TiffReader(this.src, {required this.base, required this.littleEndian});

  final RandomBytes src;
  final int base;
  final bool littleEndian;

  /// Parses a TIFF header at [base]. Accepts the standard magic (42) and
  /// the camera variants: Olympus ORF ("IIRO", "IIRS", "MMOR") and
  /// Panasonic RW2 ("IIU\0").
  static TiffReader? at(RandomBytes src, int base) {
    final h = src.read(base, 8);
    if (h.length < 8) return null;
    final bool le;
    if (h[0] == 0x49 && h[1] == 0x49) {
      le = true;
    } else if (h[0] == 0x4D && h[1] == 0x4D) {
      le = false;
    } else {
      return null;
    }
    final magic = le ? h[2] | h[3] << 8 : h[2] << 8 | h[3];
    const known = {42, 0x4F52, 0x5352, 0x0055};
    if (!known.contains(magic)) return null;
    return TiffReader(src, base: base, littleEndian: le);
  }

  int get firstIfdOffset => src.u32(base + 4, littleEndian: littleEndian);

  static int typeSize(int type) => switch (type) {
        1 || 2 || 6 || 7 => 1,
        3 || 8 => 2,
        4 || 9 || 11 || 13 => 4,
        5 || 10 || 12 => 8,
        16 || 17 || 18 => 8,
        _ => 0,
      };

  int _u16(int abs) => src.u16(abs, littleEndian: littleEndian);

  /// Reads the IFD at [offset] (relative to [base]). Returns null for
  /// offsets that are out of range or obviously not an IFD.
  TiffIfd? readIfd(int offset, {int maxEntries = 1000}) {
    if (offset <= 0) return null;
    final abs = base + offset;
    if (abs + 2 > src.length) return null;
    final n = _u16(abs);
    if (n <= 0 || n > maxEntries) return null;
    final raw = src.read(abs + 2, n * 12 + 4);
    if (raw.length < n * 12) return null;
    final data = ByteData.sublistView(raw);
    final endian = littleEndian ? Endian.little : Endian.big;
    final entries = <int, TiffEntry>{};
    var bad = 0;
    for (var i = 0; i < n; i++) {
      final p = i * 12;
      final tag = data.getUint16(p, endian);
      final type = data.getUint16(p + 2, endian);
      final count = data.getUint32(p + 4, endian);
      final size = typeSize(type);
      if (size == 0) {
        bad++;
        continue;
      }
      final total = size * count;
      final valueOffset = total <= 4
          ? abs + 2 + p + 8
          : base + data.getUint32(p + 8, endian);
      if (total > 4 && (valueOffset >= src.length || valueOffset < 0)) {
        continue;
      }
      entries.putIfAbsent(tag, () => TiffEntry(tag, type, count, valueOffset));
    }
    // Lots of unknown types means this isn't really an IFD.
    if (bad > n ~/ 2 && bad > 2) return null;
    final next =
        raw.length >= n * 12 + 4 ? data.getUint32(n * 12, endian) : 0;
    return TiffIfd(offset, entries, next);
  }

  /// Integer values of [e] (BYTE/SHORT/LONG/IFD and their signed forms).
  List<int> ints(TiffEntry e, {int max = 4096}) {
    final n = math.min(e.count, max);
    final size = typeSize(e.type);
    final raw = src.read(e.valueOffset, n * size);
    final data = ByteData.sublistView(raw);
    final endian = littleEndian ? Endian.little : Endian.big;
    final out = <int>[];
    for (var i = 0; i < n && (i + 1) * size <= raw.length; i++) {
      out.add(switch (e.type) {
        1 || 7 || 2 => data.getUint8(i),
        6 => data.getInt8(i),
        3 => data.getUint16(i * 2, endian),
        8 => data.getInt16(i * 2, endian),
        4 || 13 => data.getUint32(i * 4, endian),
        9 => data.getInt32(i * 4, endian),
        5 || 10 => data.getUint32(i * 8, endian),
        16 || 18 => data.getUint64(i * 8, endian),
        17 => data.getInt64(i * 8, endian),
        _ => 0,
      });
    }
    return out;
  }

  int? intOf(TiffIfd? ifd, int tag) {
    final e = ifd?[tag];
    if (e == null || e.count == 0) return null;
    final v = ints(e, max: 1);
    return v.isEmpty ? null : v.first;
  }

  /// Rational (or integer/float) values of [e] as doubles.
  List<double> doubles(TiffEntry e, {int max = 64}) {
    final n = math.min(e.count, max);
    final size = typeSize(e.type);
    final raw = src.read(e.valueOffset, n * size);
    final data = ByteData.sublistView(raw);
    final endian = littleEndian ? Endian.little : Endian.big;
    final out = <double>[];
    for (var i = 0; i < n && (i + 1) * size <= raw.length; i++) {
      switch (e.type) {
        case 5:
          final num = data.getUint32(i * 8, endian);
          final den = data.getUint32(i * 8 + 4, endian);
          out.add(den == 0 ? double.nan : num / den);
        case 10:
          final num = data.getInt32(i * 8, endian);
          final den = data.getInt32(i * 8 + 4, endian);
          out.add(den == 0 ? double.nan : num / den);
        case 11:
          out.add(data.getFloat32(i * 4, endian));
        case 12:
          out.add(data.getFloat64(i * 8, endian));
        default:
          return ints(e, max: max).map((v) => v.toDouble()).toList();
      }
    }
    return out;
  }

  double? doubleOf(TiffIfd? ifd, int tag) {
    final e = ifd?[tag];
    if (e == null || e.count == 0) return null;
    final v = doubles(e, max: 1);
    return v.isEmpty || v.first.isNaN ? null : v.first;
  }

  /// Rational as (numerator, denominator), for exposure times.
  (int, int)? rationalOf(TiffIfd? ifd, int tag) {
    final e = ifd?[tag];
    if (e == null || e.count == 0 || (e.type != 5 && e.type != 10)) {
      return null;
    }
    final raw = src.read(e.valueOffset, 8);
    if (raw.length < 8) return null;
    final data = ByteData.sublistView(raw);
    final endian = littleEndian ? Endian.little : Endian.big;
    return e.type == 5
        ? (data.getUint32(0, endian), data.getUint32(4, endian))
        : (data.getInt32(0, endian), data.getInt32(4, endian));
  }

  String? stringOf(TiffIfd? ifd, int tag, {int max = 1024}) {
    final e = ifd?[tag];
    if (e == null || e.count == 0) return null;
    final raw = src.read(e.valueOffset, math.min(e.byteSize, max));
    var end = raw.indexOf(0);
    if (end < 0) end = raw.length;
    final text = utf8
        .decode(raw.sublist(0, end), allowMalformed: true)
        .replaceAll('�', '')
        .trim();
    return text.isEmpty ? null : text;
  }

  Uint8List bytesOf(TiffEntry e, {int max = 1 << 20}) =>
      src.read(e.valueOffset, math.min(e.byteSize, max));

  /// Offsets of child IFDs listed in [tag] (SubIFDs, EXIF pointer, ...),
  /// relative to [base].
  List<int> pointers(TiffIfd? ifd, int tag) {
    final e = ifd?[tag];
    if (e == null) return const [];
    if (e.type != 4 && e.type != 13 && e.type != 3 && e.type != 7) {
      return const [];
    }
    if (e.type == 7) {
      // Some cameras store a single pointer as UNDEFINED[4].
      final v = src.u32(e.valueOffset, littleEndian: littleEndian);
      return v > 0 ? [v] : const [];
    }
    return ints(e, max: 64).where((v) => v > 0).toList();
  }
}

/// TIFF/EXIF tag numbers used across the parsers.
abstract final class TiffTag {
  static const newSubfileType = 0x00FE;
  static const imageWidth = 0x0100;
  static const imageHeight = 0x0101;
  static const compression = 0x0103;
  static const photometric = 0x0106;
  static const make = 0x010F;
  static const model = 0x0110;
  static const stripOffsets = 0x0111;
  static const orientation = 0x0112;
  static const stripByteCounts = 0x0117;
  static const software = 0x0131;
  static const dateTime = 0x0132;
  static const artist = 0x013B;
  static const tileOffsets = 0x0144;
  static const subIfds = 0x014A;
  static const jpegOffset = 0x0201;
  static const jpegLength = 0x0202;
  static const copyright = 0x8298;
  static const exifIfd = 0x8769;
  static const gpsIfd = 0x8825;
  static const makerNote = 0x927C;
  static const dngVersion = 0xC612;
  static const uniqueCameraModel = 0xC614;
  static const defaultCropSize = 0xC620;

  // EXIF IFD
  static const exposureTime = 0x829A;
  static const fNumber = 0x829D;
  static const exposureProgram = 0x8822;
  static const iso = 0x8827;
  static const dateTimeOriginal = 0x9003;
  static const offsetTimeOriginal = 0x9011;
  static const exposureBias = 0x9204;
  static const meteringMode = 0x9207;
  static const flash = 0x9209;
  static const focalLength = 0x920A;
  static const pixelXDimension = 0xA002;
  static const pixelYDimension = 0xA003;
  static const focalLength35 = 0xA405;
  static const bodySerial = 0xA431;
  static const lensSpec = 0xA432;
  static const lensMake = 0xA433;
  static const lensModel = 0xA434;
}

/// Camera metadata gathered from IFD0, the EXIF IFD and the GPS IFD (which
/// may come from different TIFF structures, e.g. CR3 keeps each in its own
/// box). Produces the label → value map shown in the image info panel.
class ExifSummary {
  final Map<String, String> values = {};

  /// EXIF orientation (1–8) if one was found.
  int? orientation;

  /// Output size the camera recorded (EXIF PixelX/YDimension).
  int? pixelWidth, pixelHeight;

  void _put(String label, String? value, {bool overwrite = false}) {
    if (value == null) return;
    final v = value.trim();
    if (v.isEmpty) return;
    if (overwrite || !values.containsKey(label)) values[label] = v;
  }

  bool get isEmpty => values.isEmpty;

  /// Reads the usual "IFD0" tags.
  void addImageIfd(TiffReader r, TiffIfd? ifd) {
    if (ifd == null) return;
    final make = r.stringOf(ifd, TiffTag.make);
    final model = r.stringOf(ifd, TiffTag.model);
    _put('Camera make', make);
    if (model != null) {
      // "Canon EOS 6D" already names the make.
      _put('Camera model', model);
    }
    _put('Software', r.stringOf(ifd, TiffTag.software));
    _put('Artist', r.stringOf(ifd, TiffTag.artist));
    _put('Copyright', r.stringOf(ifd, TiffTag.copyright));
    final o = r.intOf(ifd, TiffTag.orientation);
    if (o != null && o >= 1 && o <= 8) orientation ??= o;
    final date = r.stringOf(ifd, TiffTag.dateTime);
    if (date != null) _put('Modified (camera)', formatExifDate(date));
  }

  void addExifIfd(TiffReader r, TiffIfd? ifd) {
    if (ifd == null) return;
    final taken = r.stringOf(ifd, TiffTag.dateTimeOriginal);
    if (taken != null) {
      var tz = r.stringOf(ifd, TiffTag.offsetTimeOriginal);
      if (tz != null && !RegExp(r'^[+-]\d{2}:\d{2}$').hasMatch(tz)) tz = null;
      _put('Taken', '${formatExifDate(taken)}${tz == null ? '' : ' $tz'}');
    }
    final exposure = r.rationalOf(ifd, TiffTag.exposureTime);
    if (exposure != null) _put('Exposure', formatExposure(exposure.$1, exposure.$2));
    final f = r.doubleOf(ifd, TiffTag.fNumber);
    if (f != null && f > 0) _put('Aperture', 'f/${_trim(f, 1)}');
    final iso = r.intOf(ifd, TiffTag.iso);
    if (iso != null && iso > 0) _put('ISO', '$iso');
    final focal = r.doubleOf(ifd, TiffTag.focalLength);
    final focal35 = r.intOf(ifd, TiffTag.focalLength35);
    if (focal != null && focal > 0) {
      _put(
        'Focal length',
        '${_trim(focal, 1)} mm'
            '${focal35 != null && focal35 > 0 && (focal35 - focal).abs() >= 1 ? ' ($focal35 mm in 35 mm)' : ''}',
      );
    }
    final bias = r.doubleOf(ifd, TiffTag.exposureBias);
    if (bias != null && bias.abs() > 0.001) {
      _put('Exposure bias', '${bias > 0 ? '+' : ''}${_trim(bias, 2)} EV');
    }
    final flash = r.intOf(ifd, TiffTag.flash);
    if (flash != null) _put('Flash', flash & 1 == 1 ? 'Fired' : 'Did not fire');
    final program = r.intOf(ifd, TiffTag.exposureProgram);
    const programs = {
      1: 'Manual',
      2: 'Program',
      3: 'Aperture priority',
      4: 'Shutter priority',
      5: 'Creative',
      6: 'Action',
      7: 'Portrait',
      8: 'Landscape',
    };
    _put('Exposure program', programs[program]);
    const metering = {
      1: 'Average',
      2: 'Center-weighted',
      3: 'Spot',
      4: 'Multi-spot',
      5: 'Matrix / evaluative',
      6: 'Partial',
    };
    _put('Metering', metering[r.intOf(ifd, TiffTag.meteringMode)]);
    var lens = r.stringOf(ifd, TiffTag.lensModel);
    final lensMake = r.stringOf(ifd, TiffTag.lensMake);
    if (lens != null && lensMake != null && !lens.startsWith(lensMake)) {
      lens = '$lensMake $lens';
    }
    if (lens == null) {
      final spec = ifd[TiffTag.lensSpec];
      if (spec != null && spec.count >= 4) {
        final v = r.doubles(spec, max: 4);
        if (v.length == 4 && v[0] > 0 && !v[0].isNaN) {
          final focal = v[0] == v[1] || v[1].isNaN
              ? '${_trim(v[0], 0)} mm'
              : '${_trim(v[0], 0)}–${_trim(v[1], 0)} mm';
          final ap = v[2].isNaN || v[2] <= 0
              ? ''
              : v[2] == v[3] || v[3].isNaN
                  ? ' f/${_trim(v[2], 1)}'
                  : ' f/${_trim(v[2], 1)}–${_trim(v[3], 1)}';
          lens = '$focal$ap';
        }
      }
    }
    _put('Lens', lens);
    _put('Serial number', r.stringOf(ifd, TiffTag.bodySerial));
    final w = r.intOf(ifd, TiffTag.pixelXDimension);
    final h = r.intOf(ifd, TiffTag.pixelYDimension);
    if (w != null && h != null && w > 0 && h > 0) {
      pixelWidth ??= w;
      pixelHeight ??= h;
    }
  }

  void addGpsIfd(TiffReader r, TiffIfd? ifd) {
    if (ifd == null || values.containsKey('Location')) return;
    final lat = ifd[2], lon = ifd[4];
    if (lat == null || lon == null) return;
    double dms(TiffEntry e) {
      final v = r.doubles(e, max: 3);
      if (v.length < 3 || v.any((x) => x.isNaN)) return double.nan;
      return v[0] + v[1] / 60 + v[2] / 3600;
    }

    var la = dms(lat), lo = dms(lon);
    if (la.isNaN || lo.isNaN || (la == 0 && lo == 0)) return;
    if (r.stringOf(ifd, 1)?.toUpperCase() == 'S') la = -la;
    if (r.stringOf(ifd, 3)?.toUpperCase() == 'W') lo = -lo;
    _put('Location', '${la.toStringAsFixed(5)}, ${lo.toStringAsFixed(5)}');
    final alt = r.doubleOf(ifd, 6);
    if (alt != null && alt.isFinite) {
      final below = r.intOf(ifd, 5) == 1;
      _put('Altitude', '${below ? '-' : ''}${alt.toStringAsFixed(0)} m');
    }
  }

  /// Adds the IFD0 at [r]'s first IFD and the EXIF/GPS IFDs it points to.
  void addTiff(TiffReader r, {TiffIfd? ifd0}) {
    final first = ifd0 ?? r.readIfd(r.firstIfdOffset);
    if (first == null) return;
    addImageIfd(r, first);
    for (final p in r.pointers(first, TiffTag.exifIfd).take(1)) {
      addExifIfd(r, r.readIfd(p));
    }
    for (final p in r.pointers(first, TiffTag.gpsIfd).take(1)) {
      addGpsIfd(r, r.readIfd(p));
    }
  }

  static String _trim(double v, int digits) {
    var s = v.toStringAsFixed(digits);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  /// "2019:09:18 16:41:53" → "2019-09-18 16:41:53".
  static String formatExifDate(String raw) {
    final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})(.*)$').firstMatch(raw.trim());
    if (m == null) return raw.trim();
    return '${m[1]}-${m[2]}-${m[3]}${m[4]}'.trim();
  }

  static String formatExposure(int num, int den) {
    if (num <= 0 || den <= 0) return '';
    final seconds = num / den;
    if (seconds >= 0.3) return '${_trim(seconds, 1)} s';
    return '1/${(den / num).round()} s';
  }
}
