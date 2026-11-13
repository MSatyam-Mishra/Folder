import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/formats/archive_open.dart';
import 'package:folders/core/services/compress/archive_sink.dart';
import 'package:folders/core/services/compress/compress_job.dart';
import 'package:folders/core/services/compress/pbkdf2_sha1.dart';
import 'package:koni_codecs/crypto.dart' as koni;
import 'package:path/path.dart' as p;

/// "Compress…": every kind, level, password and split this app writes,
/// read back by the app's own archive reader. With
/// `EXPLORER_COMPRESS_KEEP=folder` the archives are kept there, to check
/// with other tools (7-Zip, Python's zipfile, tarfile, pyzipper, py7zr).
void main() {
  final keep = Platform.environment['EXPLORER_COMPRESS_KEEP'];
  late Directory root;
  late Directory out;
  late Map<String, List<int>> files;

  String at(String path) => p.joinAll([root.path, ...path.split('/')]);

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('explorer_compress_src');
    out = keep != null
        ? (Directory(keep)..createSync(recursive: true))
        : Directory.systemTemp.createTempSync('explorer_compress_out');
    final random = Random(7);
    final text = utf8.encode(List.generate(4000, (i) => 'line $i of a text that repeats itself a little').join('\n'));
    files = {
      'Docs/notes.txt': text,
      'Docs/empty.txt': const [],
      'Docs/Ünïcödé näme €.md': utf8.encode('# Hello\n'),
      'Docs/${'long' * 30}/deep/file.txt': utf8.encode('deep'),
      'Media/noise.bin': List.generate(300000, (_) => random.nextInt(256)),
      'Media/photo.jpg': List.generate(70000, (_) => random.nextInt(256)),
      'top.txt': utf8.encode('top'),
    };
    files.forEach((path, bytes) {
      final file = File(at(path));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
    });
    Directory(at('Docs/Empty folder')).createSync();
  });

  tearDownAll(() {
    root.deleteSync(recursive: true);
    if (keep == null) out.deleteSync(recursive: true);
  });

  List<String> sources() => [at('Docs'), at('Media'), at('top.txt')];

  /// Opens what was made with the app's reader, and checks every file.
  Future<void> readBack(List<String> parts, {String? password}) async {
    final opened = await openArchive(parts.first, password: password);
    try {
      final entries = {for (final e in opened.backend.entries) e.path.replaceAll(r'\', '/'): e};
      for (final MapEntry(key: path, value: bytes) in files.entries) {
        final entry = entries[path];
        expect(entry, isNotNull, reason: '$path in ${p.basename(parts.first)}: ${entries.keys}');
        final read = BytesBuilder();
        await for (final chunk in opened.backend.openRead(entry!)) {
          read.add(chunk);
        }
        expect(read.length, bytes.length, reason: path);
        expect(read.takeBytes(), bytes, reason: path);
      }
      expect(entries.keys.any((k) => k.startsWith('Docs/Empty folder')), isTrue, reason: 'empty folders stay');
      if (parts.length > 1) expect(opened.volumes, hasLength(parts.length));
    } finally {
      await opened.backend.close();
    }
  }

  CompressResult make(String name, CompressOptions options) {
    final destination = CompressJob.freePath(out.path, options.kind.nameFor(name), split: options.volumeSize != null);
    return CompressJob.compress(sources(), destination, options);
  }

  group('every kind reads back', () {
    for (final kind in ArchiveKind.values) {
      final levels = kind.levels.isEmpty ? [CompressLevel.normal] : kind.levels;
      for (final level in levels) {
        test('${kind.label} ${level.label}', () async {
          final result = make('all ${kind.name} ${level.name}', CompressOptions(kind: kind, level: level));
          expect(result.parts, hasLength(1));
          expect(result.skipped, isEmpty);
          await readBack(result.parts);
        });
      }
    }
  });

  group('passwords', () {
    test('ZIP with AES-256', () async {
      final result = make('secret zip', const CompressOptions(kind: ArchiveKind.zip, password: 'pässword 1'));
      await readBack(result.parts, password: 'pässword 1');
      // Encrypted: the text isn't there to read.
      final raw = File(result.parts.single).readAsBytesSync();
      expect(latin1.decode(raw, allowInvalid: true).contains('line 1 of a text'), isFalse);
    });

    for (final level in [CompressLevel.store, CompressLevel.fast, CompressLevel.normal]) {
      test('7z ${level.label} with AES-256', () async {
        final result = make('secret 7z ${level.name}',
            CompressOptions(kind: ArchiveKind.sevenZip, level: level, password: 'pässword 1'));
        await readBack(result.parts, password: 'pässword 1');
      });
    }

    test('7z with its names encrypted needs the password to list', () async {
      final result = make('hidden names',
          const CompressOptions(kind: ArchiveKind.sevenZip, password: 'pw', encryptNames: true));
      final raw = File(result.parts.single).readAsBytesSync();
      expect(latin1.decode(raw, allowInvalid: true).contains('notes'), isFalse);
      // Names are UTF-16 in a 7z header: not there either.
      expect(String.fromCharCodes(raw).contains('n\u0000o\u0000t\u0000e\u0000s'), isFalse);
      await expectLater(openArchive(result.parts.single), throwsA(anything));
      await readBack(result.parts, password: 'pw');
    });
  });

  group('volumes', () {
    for (final kind in [ArchiveKind.zip, ArchiveKind.sevenZip, ArchiveKind.tarGz]) {
      test('${kind.label} in parts of 64 KB, numbered .001, .002…', () async {
        final result = make('split ${kind.name}',
            CompressOptions(kind: kind, level: CompressLevel.store, volumeSize: ArchiveSink.minVolume));
        expect(result.parts.length, greaterThan(2));
        expect(result.parts.first, endsWith('.${kind.extension}.001'));
        for (final part in result.parts.take(result.parts.length - 1)) {
          expect(File(part).lengthSync(), ArchiveSink.minVolume);
        }
        await readBack(result.parts);
      });
    }

    test('a split that fits in one part keeps its plain name', () {
      final result = CompressJob.compress([at('top.txt')], p.join(out.path, 'one part.zip'),
          const CompressOptions(volumeSize: 1 << 20));
      expect(result.parts, [p.join(out.path, 'one part.zip')]);
    });

    test('an encrypted 7z in parts', () async {
      final result = make('split secret',
          const CompressOptions(kind: ArchiveKind.sevenZip, password: 'x', encryptNames: true, volumeSize: 100000));
      expect(result.parts.length, greaterThan(1));
      await readBack(result.parts, password: 'x');
    });
  });

  group('pieces', () {
    test('patching reaches back into an earlier part', () {
      final path = p.join(out.path, 'patched.bin');
      final sink = ArchiveSink(path, volumeSize: ArchiveSink.minVolume)
        ..add(Uint8List(ArchiveSink.minVolume * 2 + 100));
      sink.patch(ArchiveSink.minVolume - 2, [1, 2, 3, 4]);
      sink.patch(5, [9]);
      sink.patch(ArchiveSink.minVolume * 2 + 50, [7]);
      final parts = sink.close();
      final joined = [for (final part in parts) ...File(part).readAsBytesSync()];
      expect(joined.length, ArchiveSink.minVolume * 2 + 100);
      expect(joined.sublist(ArchiveSink.minVolume - 2, ArchiveSink.minVolume + 2), [1, 2, 3, 4]);
      expect(joined[5], 9);
      expect(joined[ArchiveSink.minVolume * 2 + 50], 7);
    });

    test("WinZip's key: PBKDF2-HMAC-SHA1 as RFC 6070 and koni's give it", () {
      String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final password = utf8.encode('password');
      final salt = utf8.encode('salt');
      expect(hex(pbkdf2HmacSha1(password, salt, 1, 20)), '0c60c80f961f0e71f3a9b524af6012062fe037a6');
      expect(hex(pbkdf2HmacSha1(password, salt, 2, 20)), 'ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957');
      expect(hex(pbkdf2HmacSha1(password, salt, 4096, 20)), '4b007901b765489abead49d926f721d065a429c1');
      expect(
        hex(pbkdf2HmacSha1(utf8.encode('passwordPASSWORDpassword'), utf8.encode('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 25)),
        '3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038',
      );
      final winZipSalt = Uint8List.fromList(List.generate(16, (i) => i * 13));
      final long = utf8.encode('pässword ' * 10); // Longer than a block: hashed first.
      for (final key in [utf8.encode('pässword 1'), long]) {
        expect(pbkdf2HmacSha1(key, winZipSalt, 1000, 66), koni.pbkdf2(koni.Hmac.sha1(Uint8List.fromList(key)), winZipSalt, 1000, 66));
      }
    });

    test('a name gets the kind it is made as', () {
      expect(ArchiveKind.tarGz.nameFor('photos.zip'), 'photos.tar.gz');
      expect(ArchiveKind.zip.nameFor('photos.tar.gz'), 'photos.zip');
      expect(ArchiveKind.sevenZip.nameFor('notes'), 'notes.7z');
    });

    test('links are left out, never followed', () {
      final link = Link(at('Docs/link to media'))..createSync(at('Media'));
      addTearDown(link.deleteSync);
      final names = CompressJob.collect([at('Docs')]).map((i) => i.name);
      expect(names.where((n) => n.contains('link to media')), isEmpty);
    });

    test('cancelling stops at once and removes every part', () async {
      final big = File(at('big.bin'))..writeAsBytesSync(List.generate(6 << 20, (i) => (i * 31) & 0xFF));
      addTearDown(big.deleteSync);
      final destination = p.join(out.path, 'cancelled.tar.bz2');
      final started = Completer<void>();
      final job = CompressJob([big.path], destination,
          const CompressOptions(kind: ArchiveKind.tarBz2, volumeSize: ArchiveSink.minVolume), onProgress: (progress) {
        if (!started.isCompleted) started.complete();
      });
      final pending = job.start();
      await started.future;
      job.cancel();
      expect(await pending, isNull);
      // It closes its files and removes its parts itself, within a chunk.
      for (var i = 0; i < 50 && out.listSync().any((e) => p.basename(e.path).startsWith('cancelled')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(out.listSync().where((e) => p.basename(e.path).startsWith('cancelled')), isEmpty);
    });

    test('a job in the background tells how far it has come', () async {
      final seen = <CompressProgress>[];
      final destination = p.join(out.path, 'background.zip');
      final result = await CompressJob(sources(), destination, const CompressOptions(), onProgress: seen.add).start();
      expect(result!.parts, [destination]);
      expect(seen, isNotEmpty);
      expect(seen.last.done, seen.last.total);
    });
  });
}
