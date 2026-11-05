/// 7z adapter over koni_sevenz (LZMA, LZMA2, Deflate, BCJ, Delta, AES).
///
/// koni_sevenz decodes a whole solid folder in memory and keeps the most
/// recent one cached, so random access inside a folder is cheap after the
/// first read. BZip2, PPMd and BCJ2 folders are reported as unsupported.
library;

import 'dart:typed_data';

import 'package:koni_archive_core/koni_archive_core.dart' as koni;
import 'package:koni_sevenz/koni_sevenz.dart';

import 'archive_backend.dart';

class SevenZBackend extends ArcBackend {
  SevenZBackend._(this._source, this._reader, this.entries, this._byIndex,
      this.formatLabel, this._hasPassword);

  final koni.ByteSource _source;
  final koni.ArchiveReader _reader;
  final List<koni.ArchiveEntry> _byIndex;
  final bool _hasPassword;

  @override
  final List<ArcEntry> entries;

  @override
  final String formatLabel;

  static Future<SevenZBackend> open(
    koni.ByteSource source, {
    String? password,
    ArcLimits limits = const ArcLimits(),
    int parts = 1,
  }) async {
    final pw = (password == null || password.isEmpty) ? null : password;
    koni.ArchiveReader reader;
    try {
      reader = await const SevenZFormat().openReader(
        source,
        koni.ArchiveReadOptions(
          password: pw,
          maxEntryCount: limits.maxEntries,
          maxContainerDecodeSize: limits.maxInMemoryEntry,
        ),
      );
    } on koni.EncryptedArchiveException catch (e) {
      if (e is koni.InvalidPasswordException) {
        throw ArcException(ArcErrorKind.wrongPassword, 'Wrong password.');
      }
      throw ArcException(
        ArcErrorKind.needPassword,
        'This archive is password protected (file names are encrypted too).',
        detail: e.message,
      );
    } on koni.UnexpectedEofException catch (e) {
      throw ArcException(
        ArcErrorKind.corrupt,
        parts > 1
            ? 'The archive is incomplete: a part is missing or truncated.'
            : 'The archive is truncated (incomplete download?).',
        detail: e.message,
      );
    } on koni.CorruptArchiveException catch (e) {
      if (pw != null) {
        // 7z has no password check value: a wrong key decrypts the header
        // into garbage.
        throw ArcException(
          ArcErrorKind.wrongPassword,
          'Wrong password (or the archive is damaged).',
          detail: e.message,
        );
      }
      if (e.message.contains('does not fit')) {
        throw ArcException(
          ArcErrorKind.corrupt,
          parts > 1
              ? 'The archive is incomplete: a part is missing or truncated.'
              : 'The archive is truncated (incomplete download?).',
          detail: e.message,
        );
      }
      throw mapKoniError(e);
    } catch (e) {
      throw mapKoniError(e);
    }

    final entries = <ArcEntry>[];
    final byIndex = <koni.ArchiveEntry>[];
    for (final e in reader.entries) {
      final isDir = e.isDirectory;
      final comp = e.compression;
      String? unsupported;
      if (!isDir && e.uncompressedSize > 0) {
        if (comp == koni.ArchiveCompression.bzip2) {
          unsupported = 'BZip2 compression in 7z archives isn\'t supported.';
        } else if (comp == koni.ArchiveCompression.ppmd) {
          unsupported = 'PPMd compression in 7z archives isn\'t supported.';
        }
      }
      entries.add(
        ArcEntry(
          index: entries.length,
          path: e.path,
          isDirectory: isDir,
          size: isDir ? 0 : e.uncompressedSize,
          modified: e.modified,
          isEncrypted: e.isEncrypted,
          isSymlink: e.type == koni.ArchiveEntryType.symlink,
          linkTarget: e.linkTarget,
          unsafePath: e.pathEscapedRoot,
          method: isDir ? null : _methodLabel(comp),
          crc32: e.crc32,
          unsupportedReason: unsupported,
        ),
      );
      byIndex.add(e);
    }
    final label = '7z${parts > 1 ? ', $parts parts' : ''}';
    return SevenZBackend._(source, reader, entries, byIndex, label, pw != null);
  }

  static String _methodLabel(koni.ArchiveCompression c) => switch (c.name) {
    'stored' => 'Stored',
    'lzma' => 'LZMA',
    'lzma2' => 'LZMA2',
    'deflate' => 'Deflate',
    'bzip2' => 'BZip2',
    'ppmd' => 'PPMd',
    _ => c.name,
  };

  @override
  Stream<Uint8List> openRead(ArcEntry entry) {
    if (entry.isDirectory) return const Stream.empty();
    final reason = entry.unsupportedReason;
    if (reason != null) {
      throw ArcException(ArcErrorKind.unsupported, reason, entryPath: entry.path);
    }
    if (entry.isEncrypted && !_hasPassword) {
      throw ArcException(
        ArcErrorKind.needPassword,
        '"${entry.name}" is password protected.',
        entryPath: entry.path,
      );
    }
    return _read(entry);
  }

  Stream<Uint8List> _read(ArcEntry entry) async* {
    try {
      await for (final chunk in _reader.openRead(_byIndex[entry.index])) {
        yield chunk;
      }
    } on koni.SizeLimitExceededException catch (e) {
      throw ArcException(
        ArcErrorKind.tooLarge,
        'This 7z archive packs "${entry.name}" in a solid block too large for '
        'Folder to unpack in memory.',
        entryPath: entry.path,
        detail: e.message,
      );
    } on koni.CorruptArchiveException catch (e) {
      if (entry.isEncrypted) {
        throw ArcException(
          ArcErrorKind.wrongPassword,
          'Wrong password for "${entry.name}" (or the data is damaged).',
          entryPath: entry.path,
          detail: e.message,
        );
      }
      throw mapKoniError(e, entryPath: entry.path);
    } on ArcException {
      rethrow;
    } catch (e) {
      throw mapKoniError(e, entryPath: entry.path);
    }
  }

  @override
  Future<void> close() async {
    await _reader.close();
    await _source.close();
  }
}
