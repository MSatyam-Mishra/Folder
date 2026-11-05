/// Streaming ZIP reader (ZIP, ZIP64, JAR/APK/XAPK, CBZ…).
///
/// Lists from the central directory only (no local headers, no
/// decompression), streams entries of any size with bounded memory, checks
/// CRC-32, and decrypts ZipCrypto and WinZip AES (AE-1/AE-2).
library;

import 'dart:convert';
import 'dart:io' show RawZLibFilter;
import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;
// koni_codecs is resolved through koni_sevenz/koni_rar (same version); it
// should also be listed in pubspec.yaml.
import 'package:koni_codecs/crypto.dart' as kc;
import 'package:koni_codecs/koni_codecs.dart' show LzmaDecoder;

import 'archive_backend.dart';
import 'archive_codecs.dart';

const int _sigLocal = 0x04034b50;
const int _sigCentral = 0x02014b50;
const int _sigEocd = 0x06054b50;
const int _sigZip64Locator = 0x07064b50;
const int _sigZip64Eocd = 0x06064b50;

/// Per-entry data the reader needs beyond [ArcEntry].
class _ZipItem {
  _ZipItem({
    required this.flags,
    required this.method,
    required this.crc,
    required this.packedSize,
    required this.size,
    required this.localOffset,
    required this.dosTime,
    this.aesStrength,
    this.aesVersion,
  });

  final int flags;
  final int method; // actual method (AES extra resolved)
  final int crc;
  final int packedSize;
  final int size;
  final int localOffset;
  final int dosTime;
  final int? aesStrength;
  final int? aesVersion;

  bool get encrypted => flags & 1 != 0;
  bool get isAes => aesStrength != null;
}

class ZipBackend extends ArcBackend {
  ZipBackend._(this._source, this.entries, this._items, this._bias,
      this.formatLabel, this._password, this._limits);

  final koni.ByteSource _source;
  final List<_ZipItem> _items;
  final int _bias;
  final String? _password;
  final ArcLimits _limits;

  @override
  final List<ArcEntry> entries;

  @override
  final String formatLabel;

  /// Opens [source]. The backend owns the source and closes it in [close].
  static Future<ZipBackend> open(
    koni.ByteSource source, {
    String? password,
    ArcLimits limits = const ArcLimits(),
  }) async {
    final len = source.length;
    if (len < 22) {
      throw ArcException(ArcErrorKind.corrupt, 'The ZIP file is truncated.');
    }
    final tailLen = len < 65557 + 20 ? len : 65557 + 20;
    final tail = await source.read(len - tailLen, tailLen);
    final td = ByteData.sublistView(tail);
    var eocd = -1;
    for (var i = tailLen - 22; i >= 0; i--) {
      if (td.getUint32(i, Endian.little) != _sigEocd) continue;
      final commentLen = td.getUint16(i + 20, Endian.little);
      if (i + 22 + commentLen <= tailLen) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The ZIP file is damaged or incomplete (no central directory).',
      );
    }
    final eocdPos = len - tailLen + eocd;
    var disk = td.getUint16(eocd + 4, Endian.little);
    var cdDisk = td.getUint16(eocd + 6, Endian.little);
    var count = td.getUint16(eocd + 10, Endian.little);
    var cdSize = td.getUint32(eocd + 12, Endian.little);
    var cdOffset = td.getUint32(eocd + 16, Endian.little);
    var cdEnd = eocdPos; // where the central directory actually ends
    var zip64 = false;

    if (eocd >= 20 &&
        td.getUint32(eocd - 20, Endian.little) == _sigZip64Locator) {
      final recorded = _u64(td, eocd - 20 + 8);
      final guess = eocdPos - 20 - 56;
      int? at;
      for (final cand in [recorded, guess]) {
        if (cand < 0 || cand + 56 > len) continue;
        final rec = await source.read(cand, 56);
        if (ByteData.sublistView(rec).getUint32(0, Endian.little) ==
            _sigZip64Eocd) {
          at = cand;
          break;
        }
      }
      if (at != null) {
        final rec = ByteData.sublistView(await source.read(at, 56));
        zip64 = true;
        disk = rec.getUint32(16, Endian.little);
        cdDisk = rec.getUint32(20, Endian.little);
        count = _u64(rec, 32);
        cdSize = _u64(rec, 40);
        cdOffset = _u64(rec, 48);
        cdEnd = at;
      }
    }
    if (disk != 0 || cdDisk != 0) {
      throw ArcException(
        ArcErrorKind.unsupported,
        'This is one part of a split ZIP (.z01/.z02…). Folder can\'t join '
        'that kind of split archive.',
      );
    }
    if (count > limits.maxEntries) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        'The archive lists $count entries, more than Folder will open.',
      );
    }
    final bias = cdEnd - (cdOffset + cdSize);
    if (bias < 0 || cdSize > 512 * 1024 * 1024) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The ZIP central directory is damaged.',
      );
    }
    final cd = await source.read(cdOffset + bias, cdSize);
    final parsed = _parseCentral(cd, count, limits);
    return ZipBackend._(
      source,
      parsed.$1,
      parsed.$2,
      bias,
      zip64 ? 'ZIP64' : 'ZIP',
      password,
      limits,
    );
  }

  static int _u64(ByteData d, int at) =>
      d.getUint32(at, Endian.little) +
      d.getUint32(at + 4, Endian.little) * 0x100000000;

  static (List<ArcEntry>, List<_ZipItem>) _parseCentral(
    Uint8List cd,
    int expected,
    ArcLimits limits,
  ) {
    final d = ByteData.sublistView(cd);
    final entries = <ArcEntry>[];
    final items = <_ZipItem>[];
    var pos = 0;
    while (pos + 46 <= cd.length) {
      if (d.getUint32(pos, Endian.little) != _sigCentral) break;
      final madeBy = d.getUint16(pos + 4, Endian.little);
      final flags = d.getUint16(pos + 8, Endian.little);
      var method = d.getUint16(pos + 10, Endian.little);
      final time = d.getUint16(pos + 12, Endian.little);
      final date = d.getUint16(pos + 14, Endian.little);
      final crc = d.getUint32(pos + 16, Endian.little);
      var packed = d.getUint32(pos + 20, Endian.little);
      var size = d.getUint32(pos + 24, Endian.little);
      final nameLen = d.getUint16(pos + 28, Endian.little);
      final extraLen = d.getUint16(pos + 30, Endian.little);
      final commentLen = d.getUint16(pos + 32, Endian.little);
      final extAttr = d.getUint32(pos + 38, Endian.little);
      var localOffset = d.getUint32(pos + 42, Endian.little);
      final nameStart = pos + 46;
      final extraStart = nameStart + nameLen;
      final next = extraStart + extraLen + commentLen;
      if (next > cd.length) break;
      final nameBytes = Uint8List.sublistView(cd, nameStart, extraStart);

      String? unicodeName;
      DateTime? modified;
      int? aesStrength, aesVersion;
      var e = extraStart;
      final extraEnd = extraStart + extraLen;
      while (e + 4 <= extraEnd) {
        final id = d.getUint16(e, Endian.little);
        final sz = d.getUint16(e + 2, Endian.little);
        final body = e + 4;
        if (body + sz > extraEnd) break;
        switch (id) {
          case 0x0001: // ZIP64 extended information
            var q = body;
            if (size == 0xFFFFFFFF && q + 8 <= body + sz) {
              size = _u64(d, q);
              q += 8;
            }
            if (packed == 0xFFFFFFFF && q + 8 <= body + sz) {
              packed = _u64(d, q);
              q += 8;
            }
            if (localOffset == 0xFFFFFFFF && q + 8 <= body + sz) {
              localOffset = _u64(d, q);
              q += 8;
            }
          case 0x7075: // Info-ZIP Unicode path
            if (sz > 5 && cd[body] == 1) {
              final nameCrc = d.getUint32(body + 1, Endian.little);
              if (nameCrc == koni.Crc32.compute(nameBytes)) {
                unicodeName = utf8.decode(
                  Uint8List.sublistView(cd, body + 5, body + sz),
                  allowMalformed: true,
                );
              }
            }
          case 0x5455: // extended timestamp (UTC unix seconds)
            if (sz >= 5 && cd[body] & 1 != 0) {
              final secs = d.getInt32(body + 1, Endian.little);
              modified = DateTime.fromMillisecondsSinceEpoch(
                secs * 1000,
                isUtc: true,
              );
            }
          case 0x000a: // NTFS times
            var q = body + 4;
            while (q + 4 <= body + sz) {
              final tag = d.getUint16(q, Endian.little);
              final tsz = d.getUint16(q + 2, Endian.little);
              if (tag == 1 && tsz >= 8 && q + 12 <= body + sz) {
                final ft = _u64(d, q + 4);
                if (ft > 0) {
                  // 100 ns ticks since 1601-01-01.
                  final micros = ft ~/ 10 - 11644473600000000;
                  modified = DateTime.fromMicrosecondsSinceEpoch(
                    micros,
                    isUtc: true,
                  );
                }
              }
              q += 4 + tsz;
            }
          case 0x9901: // WinZip AES
            if (sz >= 7) {
              aesVersion = d.getUint16(body, Endian.little);
              aesStrength = cd[body + 4];
              method = d.getUint16(body + 5, Endian.little);
            }
        }
        e = body + sz;
      }

      final name = unicodeName ?? _decodeName(nameBytes, flags & 0x800 != 0);
      final host = madeBy >> 8;
      final unixMode = (extAttr >> 16) & 0xFFFF;
      final isUnixDir = host == 3 && (unixMode & 0xF000) == 0x4000;
      final isLink = host == 3 && (unixMode & 0xF000) == 0xA000;
      final isDir = name.endsWith('/') ||
          name.endsWith(r'\') ||
          isUnixDir ||
          (extAttr & 0x10 != 0 && size == 0 && host != 3);
      final norm = normalizeArcPath(name);
      String? unsupported;
      if (flags & 0x40 != 0) {
        unsupported = 'PKWARE strong encryption isn\'t supported.';
      } else if (!isDir && !_supportedMethods.contains(method)) {
        unsupported = '${methodName(method)} compression isn\'t supported.';
      }
      final index = entries.length;
      entries.add(
        ArcEntry(
          index: index,
          path: norm.path,
          isDirectory: isDir,
          size: isDir ? 0 : size,
          packedSize: isDir ? 0 : packed,
          modified: modified ?? dosDateTime(date, time),
          isEncrypted: flags & 1 != 0,
          isSymlink: isLink && !isDir,
          unsafePath: norm.escaped,
          method: isDir ? null : methodName(method),
          crc32: crc,
          unsupportedReason: unsupported,
        ),
      );
      items.add(
        _ZipItem(
          flags: flags,
          method: method,
          crc: crc,
          packedSize: packed,
          size: size,
          localOffset: localOffset,
          dosTime: time,
          aesStrength: aesStrength,
          aesVersion: aesVersion,
        ),
      );
      if (entries.length > limits.maxEntries) {
        throw ArcException(
          ArcErrorKind.tooLarge,
          'The archive has more entries than Folder will open.',
        );
      }
      pos = next;
    }
    if (entries.isEmpty && expected > 0) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The ZIP central directory is damaged.',
      );
    }
    return (entries, items);
  }

  static const _supportedMethods = {0, 8, 9, 12, 14, 95};

  static String methodName(int method) => switch (method) {
    0 => 'Stored',
    1 => 'Shrink',
    6 => 'Implode',
    8 => 'Deflate',
    9 => 'Deflate64',
    12 => 'BZip2',
    14 => 'LZMA',
    19 => 'LZ77',
    93 => 'Zstandard',
    95 => 'XZ',
    96 => 'JPEG',
    97 => 'WavPack',
    98 => 'PPMd',
    _ => 'Method $method',
  };

  static String _decodeName(Uint8List bytes, bool isUtf8) {
    if (isUtf8) return utf8.decode(bytes, allowMalformed: true);
    var ascii = true;
    for (final b in bytes) {
      if (b >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) return String.fromCharCodes(bytes);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      final sb = StringBuffer();
      for (final b in bytes) {
        sb.writeCharCode(b < 0x80 ? b : _cp437High.codeUnitAt(b - 0x80));
      }
      return sb.toString();
    }
  }

  static const String _cp437High =
      'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐'
      '└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';

  @override
  Stream<Uint8List> openRead(ArcEntry entry) {
    final item = _items[entry.index];
    if (entry.isDirectory) return const Stream.empty();
    final reason = entry.unsupportedReason;
    if (reason != null) {
      throw ArcException(
        ArcErrorKind.unsupported,
        reason,
        entryPath: entry.path,
      );
    }
    if (item.encrypted && (_password == null || _password.isEmpty)) {
      throw ArcException(
        ArcErrorKind.needPassword,
        '"${entry.name}" is password protected.',
        entryPath: entry.path,
      );
    }
    return _read(entry, item);
  }

  Stream<Uint8List> _read(ArcEntry entry, _ZipItem item) async* {
    final local = await _source.read(item.localOffset + _bias, 30);
    final ld = ByteData.sublistView(local);
    if (ld.getUint32(0, Endian.little) != _sigLocal) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The archive is damaged (bad local header for "${entry.name}").',
        entryPath: entry.path,
      );
    }
    final dataStart = item.localOffset +
        _bias +
        30 +
        ld.getUint16(26, Endian.little) +
        ld.getUint16(28, Endian.little);
    if (dataStart + item.packedSize > _source.length) {
      throw ArcException(
        ArcErrorKind.corrupt,
        'The archive is truncated ("${entry.name}" runs past the end).',
        entryPath: entry.path,
      );
    }

    Stream<Uint8List> raw = readRange(
      _source,
      dataStart,
      item.packedSize,
      chunkSize: 256 * 1024,
    );
    var verifyCrc = true;
    if (item.encrypted) {
      if (item.isAes) {
        raw = _aesDecrypt(raw, item, entry);
        // AE-2 stores no CRC; the MAC covers integrity instead.
        verifyCrc = item.aesVersion != 2;
      } else {
        raw = _zipCryptoDecrypt(raw, item, entry);
      }
    }

    final Stream<Uint8List> plain = switch (item.method) {
      0 => raw,
      8 => inflateStream(raw),
      9 => inflate64Stream(raw),
      12 => bzip2Stream(raw),
      14 => _lzmaStream(raw, item, entry),
      95 => xzStream(raw),
      _ => throw ArcException(
        ArcErrorKind.unsupported,
        '${methodName(item.method)} compression isn\'t supported.',
        entryPath: entry.path,
      ),
    };

    final crc = koni.Crc32();
    var total = 0;
    try {
      await for (final chunk in plain) {
        total += chunk.length;
        if (total > item.size) {
          throw ArcException(
            ArcErrorKind.tooLarge,
            '"${entry.name}" unpacks to more data than the archive declares '
            '(possible zip bomb).',
            entryPath: entry.path,
          );
        }
        if (verifyCrc) crc.add(chunk);
        yield chunk;
      }
    } on ArcException {
      rethrow;
    } on FormatException catch (e) {
      throw _decodeError(entry, item, e.message);
    } catch (e) {
      throw mapKoniError(e, entryPath: entry.path);
    }
    if (total != item.size) {
      throw _decodeError(entry, item, 'size $total != ${item.size}');
    }
    if (verifyCrc && crc.value != item.crc) {
      if (item.encrypted) {
        throw ArcException(
          ArcErrorKind.wrongPassword,
          'Wrong password for "${entry.name}".',
          entryPath: entry.path,
        );
      }
      throw ArcException(
        ArcErrorKind.checksum,
        '"${entry.name}" failed its CRC check: the archive is damaged.',
        entryPath: entry.path,
      );
    }
  }

  ArcException _decodeError(ArcEntry entry, _ZipItem item, String detail) {
    if (item.encrypted) {
      return ArcException(
        ArcErrorKind.wrongPassword,
        'Wrong password for "${entry.name}" (or the data is damaged).',
        entryPath: entry.path,
        detail: detail,
      );
    }
    return ArcException(
      ArcErrorKind.corrupt,
      '"${entry.name}" is damaged and can\'t be unpacked.',
      entryPath: entry.path,
      detail: detail,
    );
  }

  // ----- ZipCrypto -----------------------------------------------------------

  Stream<Uint8List> _zipCryptoDecrypt(
    Stream<Uint8List> input,
    _ZipItem item,
    ArcEntry entry,
  ) async* {
    final keys = _ZipCryptoKeys(utf8.encode(_password!));
    var header = 12;
    final check = item.flags & 0x08 != 0
        ? (item.dosTime >> 8) & 0xFF
        : (item.crc >> 24) & 0xFF;
    var last = 0;
    await for (final chunk in input) {
      final out = Uint8List.fromList(chunk);
      var start = 0;
      if (header > 0) {
        final n = header < out.length ? header : out.length;
        for (var i = 0; i < n; i++) {
          last = keys.decrypt(out[i]);
        }
        header -= n;
        start = n;
        if (header == 0 && last != check) {
          throw ArcException(
            ArcErrorKind.wrongPassword,
            'Wrong password for "${entry.name}".',
            entryPath: entry.path,
          );
        }
      }
      for (var i = start; i < out.length; i++) {
        out[i] = keys.decrypt(out[i]);
      }
      if (start < out.length) yield Uint8List.sublistView(out, start);
    }
  }

  // ----- WinZip AES ------------------------------------------------------------

  Stream<Uint8List> _aesDecrypt(
    Stream<Uint8List> input,
    _ZipItem item,
    ArcEntry entry,
  ) async* {
    final strength = item.aesStrength!;
    if (strength < 1 || strength > 3) {
      throw ArcException(
        ArcErrorKind.unsupported,
        'Unknown AES key size in "${entry.name}".',
        entryPath: entry.path,
      );
    }
    final keyLen = 8 + strength * 8; // 16, 24, 32
    final saltLen = keyLen ~/ 2;
    final headerLen = saltLen + 2;
    final dataLen = item.packedSize - headerLen - 10;
    if (dataLen < 0) {
      throw ArcException(
        ArcErrorKind.corrupt,
        '"${entry.name}" is damaged.',
        entryPath: entry.path,
      );
    }
    final pending = BytesBuilder(copy: false);
    var pendingLen = 0;
    kc.AesCtrLeStream? ctr;
    kc.Hmac? mac;
    var consumed = 0; // data bytes decrypted so far
    final trailer = Uint8List(10);
    var trailerLen = 0;

    await for (final chunk in input) {
      var c = chunk;
      if (ctr == null) {
        pending.add(c);
        pendingLen += c.length;
        if (pendingLen < headerLen) continue;
        final all = pending.takeBytes();
        pendingLen = 0;
        final salt = Uint8List.sublistView(all, 0, saltLen);
        final verifier = Uint8List.sublistView(all, saltLen, headerLen);
        final derived = kc.pbkdf2(
          kc.Hmac.sha1(Uint8List.fromList(utf8.encode(_password!))),
          Uint8List.fromList(salt),
          1000,
          keyLen * 2 + 2,
        );
        if (derived[keyLen * 2] != verifier[0] ||
            derived[keyLen * 2 + 1] != verifier[1]) {
          throw ArcException(
            ArcErrorKind.wrongPassword,
            'Wrong password for "${entry.name}".',
            entryPath: entry.path,
          );
        }
        ctr = kc.AesCtrLeStream(
          kc.Aes(Uint8List.fromList(derived.sublist(0, keyLen))),
        );
        mac = kc.Hmac.sha1(
          Uint8List.fromList(derived.sublist(keyLen, keyLen * 2)),
        );
        c = Uint8List.sublistView(all, headerLen);
      }
      // Split the chunk into ciphertext and the trailing 10-byte MAC.
      final dataRemaining = dataLen - consumed;
      final take = c.length < dataRemaining ? c.length : dataRemaining;
      if (take > 0) {
        final out = Uint8List.fromList(Uint8List.sublistView(c, 0, take));
        mac!.add(out);
        ctr.processInPlace(out);
        consumed += take;
        yield out;
      }
      for (var i = take; i < c.length && trailerLen < 10; i++) {
        trailer[trailerLen++] = c[i];
      }
    }
    if (ctr == null || consumed != dataLen || trailerLen != 10) {
      throw ArcException(
        ArcErrorKind.corrupt,
        '"${entry.name}" is truncated.',
        entryPath: entry.path,
      );
    }
    final digest = mac!.finish();
    for (var i = 0; i < 10; i++) {
      if (digest[i] != trailer[i]) {
        throw ArcException(
          ArcErrorKind.checksum,
          '"${entry.name}" failed its authentication check (damaged data or '
          'wrong password).',
          entryPath: entry.path,
        );
      }
    }
  }

  // ----- LZMA (method 14) ------------------------------------------------------

  Stream<Uint8List> _lzmaStream(
    Stream<Uint8List> input,
    _ZipItem item,
    ArcEntry entry,
  ) async* {
    if (item.size > _limits.maxInMemoryEntry) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        '"${entry.name}" is too large to unpack (LZMA entries are decoded in '
        'memory).',
        entryPath: entry.path,
      );
    }
    final output = Uint8List(item.size);
    LzmaDecoder? decoder;
    final head = BytesBuilder(copy: false);
    await for (final chunk in input) {
      if (decoder == null) {
        head.add(chunk);
        if (head.length < 9) continue;
        final all = head.takeBytes();
        final propsSize = all[2] | (all[3] << 8);
        if (propsSize != 5 || all.length < 4 + propsSize) {
          throw const FormatException('bad LZMA header');
        }
        decoder = LzmaDecoder(output: output)..setProps(all[4]);
        decoder.addInput(Uint8List.sublistView(all, 4 + propsSize));
      } else {
        decoder.addInput(chunk);
      }
    }
    if (decoder == null) throw const FormatException('truncated LZMA data');
    decoder.setInputComplete();
    if (decoder.outputPosition != item.size) {
      throw const FormatException('LZMA stream ended early');
    }
    for (var i = 0; i < output.length; i += 1 << 20) {
      final end = i + (1 << 20) < output.length ? i + (1 << 20) : output.length;
      yield Uint8List.sublistView(output, i, end);
    }
  }

  @override
  Future<void> close() => _source.close();
}

/// Traditional PKWARE encryption keys.
class _ZipCryptoKeys {
  _ZipCryptoKeys(List<int> password) {
    for (final b in password) {
      _update(b);
    }
  }

  int _k0 = 305419896;
  int _k1 = 591751049;
  int _k2 = 878082192;

  static final Uint32List _crcTable = () {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      }
      t[n] = c;
    }
    return t;
  }();

  static int _crc(int crc, int b) =>
      (_crcTable[(crc ^ b) & 0xFF] ^ (crc >>> 8)) & 0xFFFFFFFF;

  void _update(int b) {
    _k0 = _crc(_k0, b);
    _k1 = (_k1 + (_k0 & 0xFF)) & 0xFFFFFFFF;
    _k1 = ((_k1 * 134775813) + 1) & 0xFFFFFFFF;
    _k2 = _crc(_k2, (_k1 >>> 24) & 0xFF);
  }

  int decrypt(int c) {
    final temp = (_k2 & 0xFFFF) | 2;
    final p = (c ^ (((temp * (temp ^ 1)) >> 8) & 0xFF)) & 0xFF;
    _update(p);
    return p;
  }
}

/// Raw DEFLATE through the platform zlib (fast, bounded memory).
Stream<Uint8List> inflateStream(Stream<Uint8List> input) async* {
  final filter = RawZLibFilter.inflateFilter(raw: true);
  await for (final chunk in input) {
    filter.process(chunk, 0, chunk.length);
    List<int>? out;
    while ((out = filter.processed(flush: false)) != null) {
      if (out!.isNotEmpty) yield _asBytes(out);
    }
  }
  List<int>? out;
  while ((out = filter.processed(end: true)) != null) {
    if (out!.isNotEmpty) yield _asBytes(out);
  }
}

Uint8List _asBytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);
