/// Disc image reader: ISO 9660 (with Joliet and Rock Ridge names, multi-extent
/// files over 4 GiB) and UDF 1.02–2.60 (file entries and extended file
/// entries, short/long/extended allocation descriptors, embedded data,
/// allocation extent chains and the UDF 2.50+ metadata partition).
///
/// Everything is read lazily through a [koni.ByteSource]; only directory
/// records and file entries are read while listing, never file data.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;

import 'archive_backend.dart';

const int _sector = 2048;

/// One run of file data: [length] bytes at [offset] in the image, or zeros
/// when [sparse].
class IsoExtent {
  const IsoExtent(this.offset, this.length, {this.sparse = false});
  final int offset;
  final int length;
  final bool sparse;
}

/// Which file-system tree of a hybrid image to read.
enum IsoTree { auto, udf, rockRidge, joliet, iso9660 }

/// Whether [source] carries an ISO 9660 or UDF volume.
Future<bool> isDiscImage(koni.ByteSource source) async {
  if (source.length < 17 * _sector) return false;
  for (var s = 16; s < 32 && (s + 1) * _sector <= source.length; s++) {
    final b = await source.read(s * _sector, 8);
    final id = String.fromCharCodes(b.sublist(1, 6));
    if (id == 'CD001' || id == 'BEA01' || id == 'NSR02' || id == 'NSR03') {
      return true;
    }
    if (b[0] == 0 && id != 'TEA01' && id != 'BOOT2' && id != 'CDW02') {
      // Not a recognised descriptor; keep scanning a little.
      continue;
    }
  }
  if (source.length > 257 * _sector) {
    final avdp = await source.read(256 * _sector, 16);
    if (avdp[0] == 2 && avdp[1] == 0 && _tagChecksumOk(avdp)) return true;
  }
  return false;
}

bool _tagChecksumOk(Uint8List tag) {
  var sum = 0;
  for (var i = 0; i < 16; i++) {
    if (i != 4) sum += tag[i];
  }
  return (sum & 0xFF) == tag[4];
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
int _u64(Uint8List b, int o) => _u32(b, o) + _u32(b, o + 4) * 0x100000000;

class IsoImage extends ArcBackend {
  IsoImage._(this._source, this.entries, this._extents, this.formatLabel,
      this.volumeLabel);

  final koni.ByteSource _source;
  final List<List<IsoExtent>> _extents;

  @override
  final List<ArcEntry> entries;

  @override
  final String formatLabel;

  final String? volumeLabel;

  /// Extents of [entry] (for tests and diagnostics).
  List<IsoExtent> extentsOf(ArcEntry entry) => _extents[entry.index];

  static Future<IsoImage> open(
    koni.ByteSource source, {
    IsoTree tree = IsoTree.auto,
    ArcLimits limits = const ArcLimits(),
  }) async {
    final b = _Builder(limits);
    final iso = await _Iso9660.probe(source);
    final hasUdf = await _Udf.present(source);
    Object? udfError;

    if (hasUdf && (tree == IsoTree.auto || tree == IsoTree.udf)) {
      try {
        final udf = await _Udf.read(source, b);
        if (b.entries.isNotEmpty || iso == null || tree == IsoTree.udf) {
          return b.build(source, udf.label, udf.volumeId);
        }
      } on ArcException catch (e) {
        udfError = e;
        if (tree == IsoTree.udf) rethrow;
      } catch (e) {
        udfError = e;
        if (tree == IsoTree.udf) {
          throw ArcException(
            ArcErrorKind.corrupt,
            'The UDF file system in this image is damaged.',
            detail: '$e',
          );
        }
      }
      b.reset();
    }
    if (iso == null) {
      if (udfError is ArcException) throw udfError;
      throw ArcException(
        ArcErrorKind.notArchive,
        hasUdf
            ? 'The UDF file system in this image can\'t be read.'
            : 'This isn\'t an ISO 9660 or UDF disc image.',
        detail: udfError?.toString(),
      );
    }
    final label = await iso.read(source, b, tree);
    return b.build(source, label, iso.volumeId);
  }

  @override
  Stream<Uint8List> openRead(ArcEntry entry) {
    if (entry.isDirectory || entry.isSymlink) return const Stream.empty();
    return _read(entry);
  }

  Stream<Uint8List> _read(ArcEntry entry) async* {
    var left = entry.size;
    for (final ext in _extents[entry.index]) {
      if (left <= 0) break;
      final len = ext.length < left ? ext.length : left;
      if (ext.sparse) {
        var z = len;
        while (z > 0) {
          final n = z < (1 << 20) ? z : 1 << 20;
          yield Uint8List(n);
          z -= n;
        }
      } else {
        if (ext.offset + len > _source.length) {
          throw ArcException(
            ArcErrorKind.corrupt,
            'The image is truncated ("${entry.name}" runs past its end).',
            entryPath: entry.path,
          );
        }
        yield* readRange(_source, ext.offset, len);
      }
      left -= len;
    }
    if (left > 0) {
      throw ArcException(
        ArcErrorKind.corrupt,
        '"${entry.name}" is incomplete in this image.',
        entryPath: entry.path,
      );
    }
  }

  @override
  Future<void> close() => _source.close();
}

class _Builder {
  _Builder(this.limits);
  final ArcLimits limits;
  final entries = <ArcEntry>[];
  final extents = <List<IsoExtent>>[];

  void reset() {
    entries.clear();
    extents.clear();
  }

  void add({
    required String path,
    required bool isDir,
    required int size,
    DateTime? modified,
    bool symlink = false,
    String? linkTarget,
    List<IsoExtent> data = const [],
  }) {
    final norm = normalizeArcPath(path);
    if (norm.path.isEmpty) return;
    entries.add(
      ArcEntry(
        index: entries.length,
        path: norm.path,
        isDirectory: isDir,
        size: isDir ? 0 : size,
        packedSize: isDir ? 0 : size,
        modified: modified,
        isSymlink: symlink,
        linkTarget: linkTarget,
        unsafePath: norm.escaped,
      ),
    );
    extents.add(data);
    if (entries.length > limits.maxEntries) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        'The image has more files than Folders will list.',
      );
    }
  }

  IsoImage build(koni.ByteSource source, String label, String? volumeId) =>
      IsoImage._(source, List.unmodifiable(entries), extents, label, volumeId);
}

// ---------------------------------------------------------------------------
// ISO 9660
// ---------------------------------------------------------------------------

class _Iso9660 {
  _Iso9660(this.pvd, this.joliet, this.volumeId);

  final Uint8List pvd;
  final Uint8List? joliet;
  final String? volumeId;

  static Future<_Iso9660?> probe(koni.ByteSource s) async {
    Uint8List? pvd, joliet;
    for (var sector = 16; sector < 64; sector++) {
      if ((sector + 1) * _sector > s.length) break;
      final d = await s.read(sector * _sector, _sector);
      if (String.fromCharCodes(d.sublist(1, 6)) != 'CD001') break;
      final type = d[0];
      if (type == 255) break;
      if (type == 1) pvd ??= d;
      if (type == 2 && d[88] == 0x25 && d[89] == 0x2F &&
          (d[90] == 0x40 || d[90] == 0x43 || d[90] == 0x45)) {
        joliet ??= d;
      }
    }
    if (pvd == null) return null;
    final id = latin1.decode(pvd.sublist(40, 72)).trim();
    String? volumeId = id.isEmpty ? null : id;
    if (joliet != null) {
      final jid = _ucs2(joliet.sublist(40, 72)).trim();
      if (jid.isNotEmpty) volumeId = jid;
    }
    return _Iso9660(pvd, joliet, volumeId);
  }

  static String _ucs2(Uint8List b) {
    final sb = StringBuffer();
    for (var i = 0; i + 1 < b.length; i += 2) {
      final c = (b[i] << 8) | b[i + 1];
      if (c == 0) break;
      sb.writeCharCode(c);
    }
    return sb.toString();
  }

  /// Lists the chosen tree; returns the format label.
  Future<String> read(koni.ByteSource s, _Builder b, IsoTree tree) async {
    final blockSize = _u16(pvd, 128) == 0 ? _sector : _u16(pvd, 128);
    final rootRec = Uint8List.sublistView(pvd, 156, 156 + 34);
    // Rock Ridge: the root's "." record carries an SP entry.
    final rootLba = _u32(rootRec, 2);
    final rootSize = _u32(rootRec, 10);
    int? susp;
    if (tree != IsoTree.joliet && tree != IsoTree.iso9660) {
      final first = await s.read(rootLba * blockSize, blockSize);
      susp = _suspSkip(first);
    }
    final useRr = susp != null;
    final useJoliet = !useRr && joliet != null && tree != IsoTree.iso9660;
    final src = useJoliet ? joliet! : pvd;
    final rec = Uint8List.sublistView(src, 156, 156 + 34);
    final walker = _IsoWalker(
      s,
      b,
      blockSize,
      joliet: useJoliet,
      suspSkip: useRr ? susp : null,
    );
    await walker.walk(_u32(rec, 2), useJoliet ? _u32(rec, 10) : rootSize, '');
    return useRr
        ? 'ISO 9660 + Rock Ridge'
        : useJoliet
        ? 'ISO 9660 + Joliet'
        : 'ISO 9660';
  }

  /// Returns the SUSP skip length if the root "." record has an SP entry.
  static int? _suspSkip(Uint8List dirSector) {
    final len = dirSector[0];
    if (len < 34) return null;
    final nameLen = dirSector[32];
    var p = 33 + nameLen + (nameLen.isEven ? 1 : 0);
    if (p + 7 <= len &&
        dirSector[p] == 0x53 && // 'S'
        dirSector[p + 1] == 0x50 && // 'P'
        dirSector[p + 4] == 0xBE &&
        dirSector[p + 5] == 0xEF) {
      return dirSector[p + 6];
    }
    return null;
  }
}

class _IsoWalker {
  _IsoWalker(this.s, this.b, this.blockSize,
      {required this.joliet, this.suspSkip});

  final koni.ByteSource s;
  final _Builder b;
  final int blockSize;
  final bool joliet;
  final int? suspSkip;
  final Set<int> _visited = {};

  Future<void> walk(int lba, int size, String prefix, [int depth = 0]) async {
    if (depth > 128 || !_visited.add(lba)) return;
    if (size <= 0 || lba * blockSize + size > s.length) return;
    if (size > 64 * 1024 * 1024) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'A directory in this image is implausibly large.',
      );
    }
    final data = await s.read(lba * blockSize, size);
    final subdirs = <(int, int, String)>[];
    String? pendingName;
    List<IsoExtent>? pendingExtents;
    var pendingSize = 0;
    var pos = 0;
    while (pos < data.length) {
      final len = data[pos];
      if (len == 0) {
        // Records don't cross sector boundaries; skip the padding.
        pos = (pos ~/ _sector + 1) * _sector;
        continue;
      }
      if (len < 34 || pos + len > data.length) break;
      final r = Uint8List.sublistView(data, pos, pos + len);
      pos += len;
      final nameLen = r[32];
      if (33 + nameLen > len) continue;
      final flags = r[25];
      if (nameLen == 1 && (r[33] == 0 || r[33] == 1)) continue; // . and ..
      if (flags & 0x04 != 0) continue; // associated file
      final extLba = _u32(r, 2) + r[1];
      final extSize = _u32(r, 10);
      var name = _name(Uint8List.sublistView(r, 33, 33 + nameLen));
      var isDir = flags & 0x02 != 0;
      var modified = _recDate(r, 18);
      String? linkTarget;
      var skip = false;
      var childLba = -1;
      if (suspSkip != null) {
        final rr = await _rockRidge(r, 33 + nameLen + (nameLen.isEven ? 1 : 0));
        if (rr.name != null) name = rr.name!;
        if (rr.modified != null) modified = rr.modified;
        if (rr.symlink != null) linkTarget = rr.symlink;
        if (rr.relocated) skip = true;
        if (rr.childLink != null) {
          isDir = true;
          childLba = rr.childLink!;
        }
      }
      if (skip) continue;
      final path = prefix.isEmpty ? name : '$prefix/$name';

      if (isDir) {
        if (childLba >= 0) {
          // Relocated deep directory: its "." record holds the real size.
          final first = await s.read(childLba * blockSize, blockSize);
          subdirs.add((childLba, _u32(first, 10), path));
        } else {
          subdirs.add((extLba, extSize, path));
        }
        b.add(path: path, isDir: true, size: 0, modified: modified);
        continue;
      }
      final ext = IsoExtent(extLba * blockSize, extSize);
      if (pendingName != null && pendingName == path) {
        pendingExtents!.add(ext);
        pendingSize += extSize;
      } else {
        pendingName = path;
        pendingExtents = [ext];
        pendingSize = extSize;
      }
      if (flags & 0x80 != 0) continue; // more extents follow
      b.add(
        path: path,
        isDir: false,
        size: linkTarget != null ? 0 : pendingSize,
        modified: modified,
        symlink: linkTarget != null,
        linkTarget: linkTarget,
        data: pendingExtents,
      );
      pendingName = null;
      pendingExtents = null;
      pendingSize = 0;
    }
    for (final (dLba, dSize, dPath) in subdirs) {
      await walk(dLba, dSize, dPath, depth + 1);
    }
  }

  String _name(Uint8List raw) {
    String name;
    if (joliet) {
      final sb = StringBuffer();
      for (var i = 0; i + 1 < raw.length; i += 2) {
        sb.writeCharCode((raw[i] << 8) | raw[i + 1]);
      }
      name = sb.toString();
    } else {
      name = latin1.decode(raw);
    }
    final semi = name.lastIndexOf(';');
    if (semi > 0) name = name.substring(0, semi);
    if (name.endsWith('.') && name.length > 1) {
      name = name.substring(0, name.length - 1);
    }
    return name.replaceAll('/', '_');
  }

  static DateTime? _recDate(Uint8List r, int o) {
    final year = r[o];
    if (year == 0 && r[o + 1] == 0) return null;
    final month = r[o + 1], day = r[o + 2];
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final tz = r[o + 6] >= 128 ? r[o + 6] - 256 : r[o + 6];
    final utc = DateTime.utc(1900 + year, month, day, r[o + 3], r[o + 4],
        r[o + 5]);
    return utc.subtract(Duration(minutes: tz * 15));
  }

  Future<_RrInfo> _rockRidge(Uint8List rec, int start) async {
    final info = _RrInfo();
    final nameParts = StringBuffer();
    var hasName = false;
    final link = <String>[];
    var linkPending = '';
    var linkContinues = false;

    Future<void> parse(Uint8List area, int from, int to, int depth) async {
      var p = from;
      int? ceBlock, ceOff, ceLen;
      while (p + 4 <= to) {
        final sig = (area[p] << 8) | area[p + 1];
        final len = area[p + 2];
        if (len < 4 || p + len > to) break;
        switch (sig) {
          case 0x4E4D: // NM
            final f = area[p + 4];
            if (f & 0x06 == 0) {
              nameParts.write(utf8.decode(
                Uint8List.sublistView(area, p + 5, p + len),
                allowMalformed: true,
              ));
              hasName = true;
            }
          case 0x4345: // CE
            ceBlock = _u32(area, p + 4);
            ceOff = _u32(area, p + 12);
            ceLen = _u32(area, p + 20);
          case 0x534C: // SL
            var q = p + 5;
            while (q + 2 <= p + len) {
              final cf = area[q];
              final cl = area[q + 1];
              if (q + 2 + cl > p + len) break;
              String part;
              if (cf & 0x02 != 0) {
                part = '.';
              } else if (cf & 0x04 != 0) {
                part = '..';
              } else if (cf & 0x08 != 0) {
                part = '';
              } else {
                part = utf8.decode(
                  Uint8List.sublistView(area, q + 2, q + 2 + cl),
                  allowMalformed: true,
                );
              }
              if (linkContinues) {
                linkPending += part;
              } else {
                if (linkPending.isNotEmpty || link.isNotEmpty) {
                  link.add(linkPending);
                }
                linkPending = part;
                if (cf & 0x08 != 0 && link.isEmpty) link.add('');
              }
              linkContinues = cf & 0x01 != 0;
              q += 2 + cl;
            }
            info.isLink = true;
          case 0x5446: // TF
            final f = area[p + 4];
            final long = f & 0x80 != 0;
            final step = long ? 17 : 7;
            var q = p + 5;
            if (f & 0x01 != 0) q += step; // creation
            if (f & 0x02 != 0 && q + step <= p + len) {
              info.modified = long ? null : _recDate(area, q);
            }
          case 0x434C: // CL
            info.childLink = _u32(area, p + 4);
          case 0x5245: // RE
            info.relocated = true;
          case 0x5354: // ST
            p = to;
            continue;
        }
        p += len;
      }
      final block = ceBlock, offset = ceOff, length = ceLen;
      if (block != null && offset != null && length != null && depth < 8 &&
          length > 0 && length < 65536) {
        final off = block * blockSize + offset;
        if (off + length <= s.length) {
          final area = await s.read(off, length);
          await parse(area, 0, area.length, depth + 1);
        }
      }
    }

    await parse(rec, start + (suspSkip ?? 0), rec.length, 0);
    if (hasName) info.name = nameParts.toString().replaceAll('/', '_');
    if (info.isLink) {
      link.add(linkPending);
      info.symlink = link.join('/');
      if (info.symlink!.isEmpty) info.symlink = '/';
    }
    return info;
  }
}

class _RrInfo {
  String? name;
  DateTime? modified;
  bool isLink = false;
  String? symlink;
  bool relocated = false;
  int? childLink;
}

// ---------------------------------------------------------------------------
// UDF
// ---------------------------------------------------------------------------

class _PartMap {
  _PartMap.physical(this.start) : metadata = null;
  _PartMap.metadata(this.start, this.metadata);

  /// Byte offset of the underlying physical partition.
  final int start;

  /// Metadata partition: its blocks mapped through the metadata file.
  List<IsoExtent>? metadata;
}

class _Udf {
  _Udf(this.s, this.b);

  final koni.ByteSource s;
  final _Builder b;
  int blockSize = _sector;
  final List<_PartMap> maps = [];
  final Set<int> _visited = {};
  String label = 'UDF';
  String? volumeId;
  int revision = 0;

  static Future<bool> present(koni.ByteSource s) async {
    if (s.length < 258 * _sector) return false;
    var nsr = false;
    for (var sector = 16; sector < 64; sector++) {
      if ((sector + 1) * _sector > s.length) break;
      final d = await s.read(sector * _sector, 8);
      final id = String.fromCharCodes(d.sublist(1, 6));
      if (id == 'NSR02' || id == 'NSR03') nsr = true;
      if (id == 'TEA01') break;
      if (id != 'CD001' && id != 'BEA01' && id != 'BOOT2' && id != 'CDW02' &&
          id != 'NSR02' && id != 'NSR03') {
        break;
      }
    }
    if (!nsr) return false;
    return (await _findAnchor(s)) != null;
  }

  static Future<Uint8List?> _findAnchor(koni.ByteSource s) async {
    final last = s.length ~/ _sector - 1;
    for (final sector in [256, last - 256, last]) {
      if (sector < 0 || (sector + 1) * _sector > s.length) continue;
      final d = await s.read(sector * _sector, _sector);
      if (_u16(d, 0) == 2 && _tagChecksumOk(d)) return d;
    }
    return null;
  }

  static Future<_Udf> read(koni.ByteSource s, _Builder b) async {
    final u = _Udf(s, b);
    await u._read();
    return u;
  }

  Future<void> _read() async {
    final anchor = await _findAnchor(s);
    if (anchor == null) {
      throw ArcException(ArcErrorKind.corrupt, 'UDF anchor not found.');
    }
    final vdsLen = _u32(anchor, 16);
    final vdsLoc = _u32(anchor, 20);
    final partitions = <int, int>{}; // partition number -> start sector
    Uint8List? lvd;
    final count = (vdsLen ~/ _sector).clamp(1, 64);
    for (var i = 0; i < count; i++) {
      final off = (vdsLoc + i) * _sector;
      if (off + _sector > s.length) break;
      final d = await s.read(off, _sector);
      if (!_tagChecksumOk(d)) break;
      final tag = _u16(d, 0);
      if (tag == 8) break; // terminating descriptor
      if (tag == 5) partitions[_u16(d, 22)] = _u32(d, 188);
      if (tag == 6) lvd = d;
      if (tag == 1) {
        final id = _dstring(Uint8List.sublistView(d, 24, 56));
        if (id.isNotEmpty) volumeId = id;
      }
    }
    if (lvd == null || partitions.isEmpty) {
      throw ArcException(ArcErrorKind.corrupt, 'UDF volume descriptors missing.');
    }
    blockSize = _u32(lvd, 212);
    if (blockSize != 512 && blockSize != 1024 && blockSize != 2048 &&
        blockSize != 4096) {
      throw ArcException(ArcErrorKind.corrupt, 'Unusual UDF block size.');
    }
    final lvId = _dstring(Uint8List.sublistView(lvd, 84, 212));
    if (lvId.isNotEmpty) volumeId = lvId;
    // Domain identifier suffix holds the UDF revision.
    revision = _u16(lvd, 216 + 24);

    final nMaps = _u32(lvd, 268);
    var p = 440;
    final metaFiles = <int, (int, int)>{}; // map index -> (partition, lbn)
    for (var i = 0; i < nMaps && p + 2 <= lvd.length; i++) {
      final type = lvd[p];
      final len = lvd[p + 1];
      if (len < 6 || p + len > lvd.length) break;
      if (type == 1) {
        final part = _u16(lvd, p + 4);
        final start = partitions[part];
        if (start == null) throw ArcException(ArcErrorKind.corrupt, 'UDF partition missing.');
        maps.add(_PartMap.physical(start * _sector));
      } else if (type == 2) {
        final ident = latin1.decode(lvd.sublist(p + 5, p + 28)).replaceAll('\u0000', '').trim();
        final part = _u16(lvd, p + 38);
        final start = partitions[part];
        if (start == null) throw ArcException(ArcErrorKind.corrupt, 'UDF partition missing.');
        if (ident.startsWith('*UDF Virtual')) {
          throw ArcException(
            ArcErrorKind.unsupported,
            'This UDF image uses a virtual allocation table (CD-R session), '
            'which Folders can\'t read.',
          );
        }
        if (ident.startsWith('*UDF Metadata')) {
          metaFiles[maps.length] = (part, _u32(lvd, p + 40));
          maps.add(_PartMap.metadata(start * _sector, null));
        } else {
          // Sparable partitions: data sits at its nominal place unless
          // remapped after a write error (not handled).
          maps.add(_PartMap.physical(start * _sector));
        }
      }
      p += len;
    }
    // Resolve metadata partitions through their metadata file.
    for (final entry in metaFiles.entries) {
      final map = maps[entry.key];
      final fe = await _readBlockAbs(map.start + entry.value.$2 * blockSize);
      final parsed = await _parseFileEntry(fe, _physicalRef(map.start));
      if (parsed == null) {
        throw ArcException(ArcErrorKind.corrupt, 'UDF metadata file missing.');
      }
      map.metadata = parsed.extents;
    }

    final fsdRef = _u16(lvd, 256);
    final fsdLbn = _u32(lvd, 252);
    final fsd = await _readBlock(fsdRef, fsdLbn);
    if (_u16(fsd, 0) != 256) {
      throw ArcException(ArcErrorKind.corrupt, 'UDF file set descriptor missing.');
    }
    final rootLbn = _u32(fsd, 404);
    final rootRef = _u16(fsd, 408);
    final rev = revision == 0
        ? ''
        : ' ${revision >> 8}.${(revision & 0xFF).toRadixString(16).padLeft(2, '0')}';
    label = 'UDF$rev';
    await _walkDir(rootRef, rootLbn, '', 0);
  }

  int _physicalRef(int start) {
    for (var i = 0; i < maps.length; i++) {
      if (maps[i].metadata == null && maps[i].start == start) return i;
    }
    maps.add(_PartMap.physical(start));
    return maps.length - 1;
  }

  /// Image byte offset of [lbn] in partition reference [ref].
  int _offset(int ref, int lbn) {
    if (ref < 0 || ref >= maps.length) {
      throw ArcException(ArcErrorKind.corrupt, 'Bad UDF partition reference.');
    }
    final map = maps[ref];
    final meta = map.metadata;
    if (meta == null) return map.start + lbn * blockSize;
    var pos = lbn * blockSize;
    for (final e in meta) {
      if (pos < e.length) return e.offset + pos;
      pos -= e.length;
    }
    throw ArcException(ArcErrorKind.corrupt, 'UDF metadata block out of range.');
  }

  /// Maps an extent in partition [ref] to image extents.
  List<IsoExtent> _mapExtent(int ref, int lbn, int length) {
    final map = maps[ref];
    final meta = map.metadata;
    if (meta == null) return [IsoExtent(map.start + lbn * blockSize, length)];
    final out = <IsoExtent>[];
    var pos = lbn * blockSize;
    var left = length;
    for (final e in meta) {
      if (left <= 0) break;
      if (pos >= e.length) {
        pos -= e.length;
        continue;
      }
      final take = e.length - pos < left ? e.length - pos : left;
      out.add(IsoExtent(e.offset + pos, take));
      left -= take;
      pos = 0;
    }
    return out;
  }

  Future<Uint8List> _readBlockAbs(int offset) async {
    if (offset < 0 || offset + blockSize > s.length) {
      throw ArcException(ArcErrorKind.corrupt, 'UDF structure outside the image.');
    }
    return s.read(offset, blockSize);
  }

  Future<Uint8List> _readBlock(int ref, int lbn) => _readBlockAbs(_offset(ref, lbn));

  Future<_FileEntry?> _parseFileEntry(Uint8List d, int ref, [int depth = 0]) async {
    var tag = _u16(d, 0);
    if (tag == 259 && depth < 4) {
      // Indirect entry (strategy 4096): follow it.
      final lbn = _u32(d, 36 + 4);
      final pref = _u16(d, 36 + 8);
      return _parseFileEntry(await _readBlock(pref, lbn), pref, depth + 1);
    }
    if (tag != 261 && tag != 266) return null;
    final extended = tag == 266;
    final fileType = d[27];
    final adType = _u16(d, 34) & 7;
    final size = _u64(d, 56);
    final modified = _timestamp(d, extended ? 92 : 84);
    final lEa = _u32(d, extended ? 208 : 168);
    final lAd = _u32(d, extended ? 212 : 172);
    final adStart = (extended ? 216 : 176) + lEa;
    if (adStart + lAd > d.length) {
      throw ArcException(ArcErrorKind.corrupt, 'Damaged UDF file entry.');
    }
    final extents = <IsoExtent>[];
    Uint8List? embedded;
    if (adType == 3) {
      embedded = Uint8List.fromList(d.sublist(adStart, adStart + lAd));
    } else {
      await _parseAds(d, adStart, adStart + lAd, adType, ref, extents, 0);
    }
    return _FileEntry(fileType, size, modified, extents, embedded);
  }

  Future<void> _parseAds(Uint8List d, int from, int to, int adType, int ref,
      List<IsoExtent> out, int depth) async {
    final step = switch (adType) {
      0 => 8,
      1 => 16,
      2 => 20,
      _ => throw ArcException(ArcErrorKind.unsupported, 'Unknown UDF allocation type.'),
    };
    var p = from;
    while (p + step <= to) {
      final raw = _u32(d, p);
      final kind = raw >>> 30;
      final len = raw & 0x3FFFFFFF;
      if (len == 0) break;
      int lbn, pref;
      if (adType == 0) {
        lbn = _u32(d, p + 4);
        pref = ref;
      } else if (adType == 1) {
        lbn = _u32(d, p + 4);
        pref = _u16(d, p + 8);
      } else {
        lbn = _u32(d, p + 12);
        pref = _u16(d, p + 16);
      }
      if (kind == 3) {
        // Continuation: an allocation extent descriptor holds more ADs.
        if (depth > 64) throw ArcException(ArcErrorKind.corrupt, 'UDF extent loop.');
        final aed = await _readBlock(pref, lbn);
        if (_u16(aed, 0) != 258) {
          throw ArcException(ArcErrorKind.corrupt, 'Damaged UDF extent chain.');
        }
        final n = _u32(aed, 20);
        final end = 24 + n > aed.length ? aed.length : 24 + n;
        await _parseAds(aed, 24, end, adType, pref, out, depth + 1);
        return;
      }
      if (kind == 0) {
        out.addAll(_mapExtent(pref, lbn, len));
      } else {
        out.add(IsoExtent(0, len, sparse: true));
      }
      p += step;
    }
  }

  Future<void> _walkDir(int ref, int lbn, String prefix, int depth) async {
    if (depth > 128) return;
    final key = _offset(ref, lbn);
    if (!_visited.add(key)) return;
    final fe = await _parseFileEntry(await _readBlock(ref, lbn), ref);
    if (fe == null) return;
    Uint8List data;
    if (fe.embedded != null) {
      data = fe.embedded!;
    } else {
      if (fe.size > 64 * 1024 * 1024) {
        throw ArcException(ArcErrorKind.corrupt, 'A UDF directory is implausibly large.');
      }
      final bb = BytesBuilder(copy: false);
      var left = fe.size;
      for (final e in fe.extents) {
        if (left <= 0) break;
        final n = e.length < left ? e.length : left;
        bb.add(e.sparse ? Uint8List(n) : await s.read(e.offset, n));
        left -= n;
      }
      data = bb.takeBytes();
    }
    final subdirs = <(int, int, String)>[];
    var p = 0;
    while (p + 38 <= data.length) {
      if (_u16(data, p) != 257) break;
      final chars = data[p + 18];
      final lFi = data[p + 19];
      final icbLbn = _u32(data, p + 20 + 4);
      final icbRef = _u16(data, p + 20 + 8);
      final lIu = _u16(data, p + 36);
      final nameStart = p + 38 + lIu;
      final recLen = (38 + lIu + lFi + 3) & ~3;
      if (nameStart + lFi > data.length) break;
      p += recLen;
      if (chars & 0x08 != 0 || chars & 0x04 != 0) continue; // parent, deleted
      if (lFi == 0) continue;
      final name = _cs0(Uint8List.sublistView(data, nameStart, nameStart + lFi))
          .replaceAll('/', '_');
      if (name.isEmpty) continue;
      final path = prefix.isEmpty ? name : '$prefix/$name';
      if (chars & 0x02 != 0) {
        subdirs.add((icbRef, icbLbn, path));
        final dirFe = await _parseFileEntrySafe(icbRef, icbLbn);
        b.add(path: path, isDir: true, size: 0, modified: dirFe?.modified);
        continue;
      }
      final child = await _parseFileEntrySafe(icbRef, icbLbn);
      if (child == null) continue;
      if (child.fileType == 4) {
        subdirs.add((icbRef, icbLbn, path));
        b.add(path: path, isDir: true, size: 0, modified: child.modified);
        continue;
      }
      if (child.fileType == 12) {
        b.add(path: path, isDir: false, size: 0, modified: child.modified,
            symlink: true);
        continue;
      }
      if (child.fileType != 5 && child.fileType != 0) continue; // devices
      List<IsoExtent> extents = child.extents;
      if (child.embedded != null) {
        // Small file stored inside its entry: point at those bytes.
        final feOffset = _offset(icbRef, icbLbn);
        final fe = await _readBlockAbs(feOffset);
        final extended = _u16(fe, 0) == 266;
        final lEa = _u32(fe, extended ? 208 : 168);
        final start = (extended ? 216 : 176) + lEa;
        extents = [IsoExtent(feOffset + start, child.embedded!.length)];
      }
      b.add(
        path: path,
        isDir: false,
        size: child.size,
        modified: child.modified,
        data: extents,
      );
    }
    for (final (r, l, path) in subdirs) {
      await _walkDir(r, l, path, depth + 1);
    }
  }

  Future<_FileEntry?> _parseFileEntrySafe(int ref, int lbn) async {
    try {
      return await _parseFileEntry(await _readBlock(ref, lbn), ref);
    } on ArcException {
      return null;
    }
  }

  static DateTime? _timestamp(Uint8List d, int o) {
    final typeTz = _u16(d, o);
    var tz = typeTz & 0x0FFF;
    if (tz >= 0x800) tz -= 0x1000;
    final year = _u16(d, o + 2);
    final month = d[o + 4], day = d[o + 5];
    if (year == 0 || month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    final t = DateTime.utc(year, month, day, d[o + 6], d[o + 7], d[o + 8]);
    return tz == -2047 ? t : t.subtract(Duration(minutes: tz));
  }

  /// OSTA compressed Unicode (CS0).
  static String _cs0(Uint8List b) {
    if (b.isEmpty) return '';
    final comp = b[0];
    if (comp == 8 || comp == 254) {
      return latin1.decode(b.sublist(1));
    }
    if (comp == 16 || comp == 255) {
      final sb = StringBuffer();
      for (var i = 1; i + 1 < b.length; i += 2) {
        sb.writeCharCode((b[i] << 8) | b[i + 1]);
      }
      return sb.toString();
    }
    return latin1.decode(b.sublist(1));
  }

  /// A dstring field: CS0 bytes with the used length in the last byte.
  static String _dstring(Uint8List field) {
    final used = field[field.length - 1];
    if (used == 0 || used >= field.length) return '';
    return _cs0(Uint8List.sublistView(field, 0, used)).trim();
  }
}

class _FileEntry {
  _FileEntry(this.fileType, this.size, this.modified, this.extents, this.embedded);
  final int fileType;
  final int size;
  final DateTime? modified;
  final List<IsoExtent> extents;
  final Uint8List? embedded;
}
