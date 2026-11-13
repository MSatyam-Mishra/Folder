import 'dart:io';
import 'dart:typed_data';

import 'package:folders/core/services/checksums.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _helloMd5 = '5d41402abc4b2a76b9719d911017c592';
const _helloSha1 = 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d';
const _helloSha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('checksums_test'));
  tearDown(() async => root.delete(recursive: true));

  test('the four checksums of known text', () {
    final hashes = Checksums.ofBytes('hello'.codeUnits);
    expect(hashes[HashKind.md5], _helloMd5);
    expect(hashes[HashKind.sha1], _helloSha1);
    expect(hashes[HashKind.sha256], _helloSha256);
    expect(hashes[HashKind.sha512], hasLength(128));
    expect(hashes[HashKind.sha512], startsWith('9b71d224bd62f378'));
  });

  test('a file in an isolate, with progress, matching the one-go result', () async {
    final bytes = Uint8List(3 * 1024 * 1024 + 17);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (i * 31) & 0xff;
    }
    final file = File(p.join(root.path, 'big.bin'))..writeAsBytesSync(bytes);
    final progress = <double>[];
    final job = ChecksumJob(file.path, onProgress: progress.add);
    final hashes = await job.result;
    expect(hashes, Checksums.ofBytes(bytes));
    expect(progress, isNotEmpty);
    expect(progress.last, closeTo(1, 0.01));
  });

  test('a file that is missing fails; a cancelled job stops', () async {
    await expectLater(ChecksumJob(p.join(root.path, 'missing')).result, throwsA(isA<FileSystemException>()));
    final file = File(p.join(root.path, 'a.txt'))..writeAsStringSync('hello');
    final job = ChecksumJob(file.path)..cancel();
    await expectLater(job.result, throwsA(isA<ChecksumCancelled>()));
    // It closes the file itself when it stops, so the folder can go.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });

  test('checksums pasted in many shapes', () {
    expect(Checksums.parse(_helloSha256.toUpperCase())?.hex, _helloSha256);
    expect(Checksums.parse('  $_helloMd5 ')?.kind, HashKind.md5);
    expect(Checksums.parse('$_helloSha256  folders-v1.0.13-arm64-v8a.apk'),
        (hex: _helloSha256, kind: HashKind.sha256, name: 'folders-v1.0.13-arm64-v8a.apk'));
    expect(Checksums.parse('$_helloSha1 *setup.exe')?.name, 'setup.exe');
    expect(Checksums.parse('SHA256 (my file.iso) = $_helloSha256')?.name, 'my file.iso');
    expect(Checksums.parse('MD5 (a) = $_helloMd5')?.kind, HashKind.md5);
    // PowerShell's Get-FileHash, and pairs split by colons.
    expect(Checksums.parse('SHA256          ${_helloSha256.toUpperCase()}       C:\\x.zip')?.hex, _helloSha256);
    final pairs = [for (var i = 0; i < 40; i += 2) _helloSha1.substring(i, i + 2)].join(':');
    expect(Checksums.parse(pairs)?.hex, _helloSha1);
    expect(Checksums.parse('hello'), isNull);
    expect(Checksums.parse('abc123'), isNull);
    expect(Checksums.parse(''), isNull);
  });

  test('a sums file beside the file, or its own .sha256', () async {
    final apk = File(p.join(root.path, 'folders-v1.0.13-x86_64.apk'))..writeAsStringSync('hello');
    expect(await Checksums.findSums(apk.path), isNull);
    File(p.join(root.path, 'SHA256SUMS.txt')).writeAsStringSync(
      '0000000000000000000000000000000000000000000000000000000000000000  folders-v1.0.13-arm64-v8a.apk\n'
      '$_helloSha256  folders-v1.0.13-x86_64.apk\n',
    );
    final found = await Checksums.findSums(apk.path);
    expect(found?.hex, _helloSha256);
    expect(found?.kind, HashKind.sha256);
    expect(p.basename(found!.sumsPath), 'SHA256SUMS.txt');

    final iso = File(p.join(root.path, 'disk.iso'))..writeAsStringSync('hello');
    File(p.join(root.path, 'disk.iso.md5')).writeAsStringSync('$_helloMd5\n');
    final own = await Checksums.findSums(iso.path);
    expect(own?.kind, HashKind.md5);
    expect(p.basename(own!.sumsPath), 'disk.iso.md5');
  });
}
