/// Opens any supported archive: detects the format from content first and
/// the extension second, resolves multi-volume sets, and returns an
/// [ArcBackend].
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:koni_archive_core/io.dart' as kio;
import 'package:koni_archive_core/koni_archive_core.dart' as koni;
import 'package:path/path.dart' as p;

import 'archive_backend.dart';
import 'archive_rar.dart';
import 'archive_sevenz.dart';
import 'archive_tar.dart';
import 'archive_zip.dart';
import 'iso_reader.dart';

enum ArcFormat { zip, rar, sevenZip, tar, gzip, bzip2, xz, iso }

/// An opened archive plus where it came from.
class ArcOpened {
  ArcOpened(this.backend, this.format, this.volumes);
  final ArcBackend backend;
  final ArcFormat format;

  /// Every file making up the archive (first volume first).
  final List<String> volumes;
}

/// Identifies the format of [head] (the first bytes of a file; 64 KiB is
/// plenty except for disc images, which [detectArchiveFormat] checks).
ArcFormat? sniffArchiveBytes(Uint8List head) {
  bool at(int o, List<int> sig) {
    if (head.length < o + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (head[o + i] != sig[i]) return false;
    }
    return true;
  }

  if (at(0, [0x50, 0x4B, 0x03, 0x04]) ||
      at(0, [0x50, 0x4B, 0x05, 0x06]) ||
      at(0, [0x50, 0x4B, 0x07, 0x08])) {
    return ArcFormat.zip;
  }
  if (at(0, [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) return ArcFormat.rar;
  if (at(0, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) return ArcFormat.sevenZip;
  if (at(0, [0x1F, 0x8B])) return ArcFormat.gzip;
  if (at(0, [0x42, 0x5A, 0x68]) && head.length > 3 &&
      head[3] >= 0x31 && head[3] <= 0x39) {
    return ArcFormat.bzip2;
  }
  if (at(0, [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) return ArcFormat.xz;
  if (head.length >= 512 &&
      looksLikeTarHeader(Uint8List.sublistView(head, 0, 512))) {
    return ArcFormat.tar;
  }
  return null;
}

ArcFormat? _formatFromExtension(String path) {
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.tar.gz') || name.endsWith('.tgz')) return ArcFormat.gzip;
  if (name.endsWith('.tar.bz2') ||
      name.endsWith('.tbz') ||
      name.endsWith('.tbz2')) {
    return ArcFormat.bzip2;
  }
  if (name.endsWith('.tar.xz') || name.endsWith('.txz')) return ArcFormat.xz;
  final ext = p.extension(name).replaceFirst('.', '');
  return switch (ext) {
    'zip' || 'jar' || 'war' || 'ear' || 'aar' || 'apk' || 'xapk' || 'apks' ||
    'cbz' || 'epub' || 'ipa' || 'appx' || 'msix' || 'nupkg' || 'vsix' ||
    'whl' || 'kmz' => ArcFormat.zip,
    'rar' || 'cbr' => ArcFormat.rar,
    '7z' || 'cb7' => ArcFormat.sevenZip,
    'tar' || 'cbt' => ArcFormat.tar,
    'gz' || 'gzip' => ArcFormat.gzip,
    'bz2' => ArcFormat.bzip2,
    'xz' => ArcFormat.xz,
    'iso' || 'udf' || 'img' => ArcFormat.iso,
    _ => null,
  };
}

/// Detects [source]'s format: magic bytes first, then disc-image
/// signatures, a ZIP directory at the end (self-extractors), and finally the
/// file name.
Future<ArcFormat?> detectArchiveFormat(
  koni.ByteSource source,
  String path,
) async {
  final headLen = source.length < 1024 ? source.length : 1024;
  final head = headLen == 0 ? Uint8List(0) : await source.read(0, headLen);
  final byMagic = sniffArchiveBytes(head);
  if (byMagic != null) return byMagic;
  if (await isDiscImage(source)) return ArcFormat.iso;
  final byName = _formatFromExtension(path);
  if (byName == ArcFormat.zip || byName == null) {
    // Self-extracting or prefixed ZIPs keep the directory at the end.
    final tailLen = source.length < 66000 ? source.length : 66000;
    if (tailLen >= 22) {
      final tail = await source.read(source.length - tailLen, tailLen);
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4B &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          return ArcFormat.zip;
        }
      }
    }
  }
  return byName;
}

// ---------------------------------------------------------------------------
// Multi-volume naming
// ---------------------------------------------------------------------------

final _partRar = RegExp(r'^(.*)\.part(\d+)\.(rar|cbr)$', caseSensitive: false);
final _oldRarPart = RegExp(r'^(.*)\.([rs])(\d\d)$', caseSensitive: false);
final _numbered = RegExp(r'^(.*)\.(\d{3})$');

/// Describes how the parts of a multi-volume set are named.
class VolumeSet {
  VolumeSet._(this.first, this._nameOf, this.kind);

  /// Path of volume 1.
  final String first;
  final String Function(int number) _nameOf;

  /// `rar-new` (.partN.rar), `rar-old` (.rar/.r00), `split` (.001) or
  /// `single`.
  final String kind;

  /// Path of volume [number] (1-based).
  String pathOf(int number) => _nameOf(number);

  /// Works out the set [path] belongs to.
  static VolumeSet of(String path) {
    final dir = p.dirname(path);
    final name = p.basename(path);
    var m = _partRar.firstMatch(name);
    if (m != null) {
      final base = m.group(1)!;
      final width = m.group(2)!.length;
      final ext = m.group(3)!;
      String nameOf(int n) =>
          p.join(dir, '$base.part${n.toString().padLeft(width, '0')}.$ext');
      return VolumeSet._(nameOf(1), nameOf, 'rar-new');
    }
    m = _oldRarPart.firstMatch(name);
    if (m != null) {
      final base = m.group(1)!;
      final rar = _existingCase(dir, '$base.rar') ?? _existingCase(dir, '$base.cbr');
      return _oldRar(dir, base, rar ?? p.join(dir, '$base.rar'));
    }
    if (name.toLowerCase().endsWith('.rar') ||
        name.toLowerCase().endsWith('.cbr')) {
      final base = name.substring(0, name.length - 4);
      if (_existingCase(dir, '$base.r00') != null) {
        return _oldRar(dir, base, p.join(dir, name));
      }
    }
    m = _numbered.firstMatch(name);
    if (m != null) {
      final base = m.group(1)!;
      String nameOf(int n) =>
          p.join(dir, '$base.${n.toString().padLeft(3, '0')}');
      return VolumeSet._(nameOf(1), nameOf, 'split');
    }
    return VolumeSet._(path, (n) => n == 1 ? path : '', 'single');
  }

  static VolumeSet _oldRar(String dir, String base, String first) {
    final upper = p.extension(first) == '.RAR';
    String nameOf(int n) {
      if (n == 1) return first;
      final k = n - 2; // .r00 is volume 2
      final letter = String.fromCharCode(
        (upper ? 0x52 : 0x72) + k ~/ 100,
      );
      return p.join(dir, '$base.$letter${(k % 100).toString().padLeft(2, '0')}');
    }

    return VolumeSet._(first, nameOf, 'rar-old');
  }

  static String? _existingCase(String dir, String name) {
    for (final candidate in [name, name.toUpperCase(), name.toLowerCase()]) {
      final path = p.join(dir, candidate);
      if (File(path).existsSync()) return path;
    }
    // Mixed case: e.g. Name.R00.
    final ext = p.extension(name);
    final stem = name.substring(0, name.length - ext.length);
    for (final e in [ext.toUpperCase(), ext.toLowerCase()]) {
      final path = p.join(dir, '$stem$e');
      if (File(path).existsSync()) return path;
    }
    return null;
  }
}

/// Opens the archive at [path] (any volume of a multi-volume set).
///
/// [onProgress]/[onEntries] report listing progress for formats that must
/// decompress to list (compressed TAR).
Future<ArcOpened> openArchive(
  String path, {
  String? password,
  ArcLimits? limits,
  ArcFormat? forceFormat,
  void Function(double progress)? onProgress,
  void Function(List<ArcEntry> batch)? onEntries,
}) async {
  limits ??= ArcLimits.forPlatform();
  final set = VolumeSet.of(path);
  var firstPath = path;
  if (set.kind != 'single' && File(set.first).existsSync()) {
    firstPath = set.first;
  } else if (set.kind != 'single') {
    if (!File(set.first).existsSync()) {
      throw ArcException(
        ArcErrorKind.missingVolume,
        'The first part "${p.basename(set.first)}" of this multi-volume '
        'archive is missing.',
      );
    }
  }

  final opened = <koni.ByteSource>[];
  Future<koni.ByteSource> openFile(String file) async {
    try {
      final s = await kio.FileByteSource.open(file);
      opened.add(s);
      return s;
    } on FileSystemException catch (e) {
      throw ArcException(
        ArcErrorKind.io,
        'Couldn\'t open "${p.basename(file)}"'
        '${e.osError?.message == null ? '' : ': ${e.osError!.message}'}.',
        detail: e.message,
      );
    }
  }

  try {
    final volumes = <String>[firstPath];
    koni.ByteSource source = await openFile(firstPath);

    // Split archives (.001, .002…) are plain concatenations.
    if (set.kind == 'split') {
      final parts = <koni.ByteSource>[source];
      for (var n = 2; n < 10000; n++) {
        final next = set.pathOf(n);
        if (!File(next).existsSync()) break;
        parts.add(await openFile(next));
        volumes.add(next);
      }
      if (parts.length > 1) {
        source = ConcatByteSource(parts, name: firstPath);
      }
    }

    final format =
        forceFormat ?? await detectArchiveFormat(source, firstPath);
    if (format == null) {
      throw ArcException(
        ArcErrorKind.notArchive,
        'This file isn\'t an archive Folders recognises.',
      );
    }
    final name = set.kind == 'split'
        ? p.basename(firstPath).replaceFirst(RegExp(r'\.\d{3}$'), '')
        : p.basename(firstPath);

    ArcBackend backend;
    switch (format) {
      case ArcFormat.zip:
        backend = await ZipBackend.open(source, password: password, limits: limits);
      case ArcFormat.rar:
        final isMulti = set.kind == 'rar-new' || set.kind == 'rar-old';
        backend = await RarBackend.open(
          source,
          password: password,
          limits: limits,
          volumeName: (n) => p.basename(
            isMulti ? set.pathOf(n) : _guessRarVolume(firstPath, n),
          ),
          volumeExists: (n) {
            final next = isMulti ? set.pathOf(n) : _guessRarVolume(firstPath, n);
            return next.isNotEmpty && File(next).existsSync();
          },
          nextVolume: (n) async {
            final next = isMulti ? set.pathOf(n) : _guessRarVolume(firstPath, n);
            if (next.isEmpty || !File(next).existsSync()) return null;
            volumes.add(next);
            return openFile(next);
          },
        );
      case ArcFormat.sevenZip:
        try {
          backend = await SevenZBackend.open(
            source,
            password: password,
            limits: limits,
            parts: volumes.length,
          );
        } on ArcException catch (e) {
          if (set.kind == 'split' && e.kind == ArcErrorKind.corrupt) {
            throw ArcException(
              ArcErrorKind.missingVolume,
              'Part "${p.basename(set.pathOf(volumes.length + 1))}" of this '
              'split archive seems to be missing.',
              detail: e.detail,
            );
          }
          rethrow;
        }
      case ArcFormat.tar:
      case ArcFormat.gzip:
      case ArcFormat.bzip2:
      case ArcFormat.xz:
        backend = await TarBackend.open(
          source,
          switch (format) {
            ArcFormat.gzip => TarCompression.gzip,
            ArcFormat.bzip2 => TarCompression.bzip2,
            ArcFormat.xz => TarCompression.xz,
            _ => TarCompression.none,
          },
          name: name,
          limits: limits,
          onProgress: onProgress,
          onEntries: onEntries,
        );
      case ArcFormat.iso:
        backend = await IsoImage.open(source, limits: limits);
    }
    return ArcOpened(backend, format, volumes);
  } catch (e) {
    for (final s in opened) {
      try {
        await s.close();
      } catch (_) {}
    }
    if (e is ArcException) rethrow;
    throw mapKoniError(e);
  }
}

/// Without recognisable volume names, try both RAR naming schemes.
String _guessRarVolume(String first, int n) {
  final set = VolumeSet.of(first);
  if (set.kind == 'rar-new' || set.kind == 'rar-old') return set.pathOf(n);
  final dir = p.dirname(first);
  final name = p.basename(first);
  final stem = name.substring(0, name.length - p.extension(name).length);
  final oldStyle = p.join(dir, '$stem.r${(n - 2).toString().padLeft(2, '0')}');
  if (File(oldStyle).existsSync()) return oldStyle;
  return '';
}
