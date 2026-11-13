import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/smb/smb_client.dart';
import 'package:folders/core/services/remote/smb/smb_connection.dart';
import 'package:folders/core/services/remote/smb/smb_constants.dart';
import 'package:folders/core/services/remote/smb/smb_file_system.dart';

/// Against real servers, only when `EXPLORER_SMB_SERVERS` lists them,
/// separated by spaces: `smb://user:password@host:port/share`, plus optional
/// query parts: `encrypted=` a share that needs encryption, `guest=` a share
/// open to guests, `big=` megabytes for the speed test, `dialects=202,311`.
///
/// The servers used are in `servers/` here: Samba 4.19 with signing required
/// and a share that needs encryption, and impacket's smbserver.py (SMB 2.0.2
/// only; Windows Defender flags impacket, so it runs in a container too):
///
///   docker build -t folders-smb-test test/core/services/remote/smb/servers/samba
///   docker run -d --rm --name folders-smb-test -p 4456:445 folders-smb-test
///   docker build -t folders-impacket-test test/core/services/remote/smb/servers/impacket
///   docker run -d --rm --name folders-impacket-test -p 4455:4455 folders-impacket-test
///
///   EXPLORER_SMB_SERVERS="smb://tester:Secret123@127.0.0.1:4456/data?encrypted=secret&guest=public&big=64
///     smb://tester:Secret123@127.0.0.1:4455/TEST?big=16" flutter test test/core/services/remote/smb/smb_server_test.dart
void main() {
  final servers = (Platform.environment['EXPLORER_SMB_SERVERS'] ?? '').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).map(Uri.parse).toList();
  if (servers.isEmpty) {
    test('SMB servers (set EXPLORER_SMB_SERVERS to run)', () {}, skip: 'no EXPLORER_SMB_SERVERS');
    return;
  }
  for (final url in servers) {
    _suite(url);
  }
}

void _suite(Uri url) {
  final user = Uri.decodeComponent(url.userInfo.split(':').first);
  final password = Uri.decodeComponent(url.userInfo.split(':').skip(1).join(':'));
  final share = url.pathSegments.first;
  final q = url.queryParameters;
  final dialects = q['dialects']?.split(',').map((d) => int.parse(d, radix: 16)).toList();
  final options = dialects == null ? const SmbOptions() : SmbOptions(dialects: dialects);
  final tag = 'folders-test-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 20)}';
  final base = '/$share/$tag';

  RemoteConnection conn({String? username, String rootPath = '/', Map<String, String> extra = const {}}) => RemoteConnection(
        id: 'test',
        protocol: RemoteProtocol.smb,
        name: 'test',
        host: url.host,
        port: url.port,
        rootPath: rootPath,
        username: username ?? user,
        options: extra,
      );

  DartSmbFileSystem fs({String? username, String? pass, String rootPath = '/', Map<String, String> extra = const {}}) =>
      DartSmbFileSystem(conn(username: username, rootPath: rootPath, extra: extra), MemoryRemoteSecrets({'password': pass ?? password}), options: options);

  Uint8List bytes(int n, int seed) {
    final r = Random(seed);
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  Future<Uint8List> readAll(RemoteFileSystem f, String path, {int start = 0, int? end}) async {
    final b = BytesBuilder(copy: false);
    await for (final c in f.openRead(path, start: start, end: end)) {
      b.add(c);
    }
    return b.takeBytes();
  }

  group('${url.host}:${url.port}/$share', () {
    late DartSmbFileSystem f;

    setUpAll(() async {
      f = fs();
      await f.connect();
      await f.createDirectory(base);
    });

    tearDownAll(() async {
      try {
        await f.delete(base);
      } catch (_) {}
      await f.close();
    });

    test('lists the shares, without the hidden ones unless asked', () async {
      final shares = await f.list('/');
      final names = shares.map((e) => e.name.toLowerCase()).toList();
      expect(names, contains(share.toLowerCase()));
      expect(names.any((n) => n.endsWith(r'$')), isFalse);
      expect(shares.every((e) => e.isDirectory), isTrue);
      final all = fs(extra: {'showHiddenShares': 'true'});
      final allNames = (await all.list('/')).map((e) => e.name.toLowerCase()).toList();
      await all.close();
      expect(allNames.length, greaterThanOrEqualTo(names.length));
      // ignore: avoid_print
      print('shares: $names, with hidden: $allNames, dialect ${SmbDialect.name(f.client!.dialect)}, '
          'signed ${f.client!.signed}, cipher ${f.client!.connection.cipher}, signing alg ${f.client!.connection.signingAlgorithm}');
    });

    test('a wrong password is refused as such', () async {
      final bad = fs(pass: 'not-the-password');
      await expectLater(
        bad.connect(),
        throwsA(isA<RemoteException>()
            .having((e) => e.kind, 'kind', RemoteErrorKind.auth)
            .having((e) => e.message, 'message', contains('password'))),
      );
      await bad.close();
    });

    test('a missing share and a missing file say not found', () async {
      final bad = fs(rootPath: '/no-such-share-here');
      await expectLater(bad.connect(), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
      await bad.close();
      await expectLater(f.stat('$base/nothing.txt'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
      await expectLater(f.list('$base/nothing'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    });

    test('writes and reads a few MB back exactly, and ranges of it', () async {
      final data = bytes(5 * 1024 * 1024 + 12345, 1);
      var progress = 0;
      await f.write('$base/big.bin', Stream.fromIterable([for (var i = 0; i < data.length; i += 65536) data.sublist(i, min(data.length, i + 65536))]),
          length: data.length, onProgress: (n) => progress = n);
      expect(progress, data.length);
      final st = await f.stat('$base/big.bin');
      expect(st.size, data.length);
      expect(st.isDirectory, isFalse);
      expect(st.modified, isNotNull);
      final back = await readAll(f, '$base/big.bin');
      expect(back.length, data.length);
      expect(back, data);
      for (final (s, e) in [(0, 1), (100, 200000), (1048570, 1048600), (data.length - 10, null), (3000000, 4500001), (data.length, null)]) {
        final part = await readAll(f, '$base/big.bin', start: s, end: e);
        expect(part, data.sublist(s, e ?? data.length), reason: 'range $s-$e');
      }
      // Past the end: just what there is.
      expect((await readAll(f, '$base/big.bin', start: data.length - 5, end: data.length + 100)).length, 5);
    });

    test('write refuses to overwrite unless asked, and overwrite replaces', () async {
      await f.write('$base/a.txt', Stream.value('first version'.codeUnits));
      await expectLater(
        f.write('$base/a.txt', Stream.value('second'.codeUnits)),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)),
      );
      await f.write('$base/a.txt', Stream.value('second'.codeUnits), overwrite: true);
      expect(String.fromCharCodes(await readAll(f, '$base/a.txt')), 'second');
      // An empty file.
      await f.write('$base/empty.txt', const Stream.empty());
      expect((await f.stat('$base/empty.txt')).size, 0);
      expect(await readAll(f, '$base/empty.txt'), isEmpty);
    });

    test('a failed write leaves nothing behind', () async {
      final broken = Stream<List<int>>.fromIterable([List.filled(300000, 1)]).asyncExpand((c) async* {
        yield c;
        throw StateError('source failed');
      });
      await expectLater(f.write('$base/broken.bin', broken), throwsA(anything));
      await expectLater(f.stat('$base/broken.bin'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    });

    test('folders: create, rename, move, delete with everything in them', () async {
      await f.createDirectory('$base/dir');
      await expectLater(
        f.createDirectory('$base/dir'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)),
      );
      await f.createDirectory('$base/dir/sub');
      await f.write('$base/dir/sub/x.txt', Stream.value([1, 2, 3]));
      await f.write('$base/dir/y.txt', Stream.value([4, 5]));
      await f.rename('$base/dir/y.txt', '$base/dir/z.txt');
      expect((await f.list('$base/dir')).map((e) => e.name).toSet(), {'sub', 'z.txt'});
      await f.write('$base/dir/w.txt', Stream.value([9]));
      await expectLater(
        f.rename('$base/dir/w.txt', '$base/dir/z.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)),
      );
      await f.rename('$base/dir', '$base/moved');
      expect((await f.stat('$base/moved/sub/x.txt')).size, 3);
      await f.rename('$base/moved/sub/x.txt', '$base/x-up.txt');
      expect(await readAll(f, '$base/x-up.txt'), [1, 2, 3]);
      await f.delete('$base/moved');
      await expectLater(f.stat('$base/moved'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
      await f.delete('$base/x-up.txt');
      final names = (await f.list(base)).map((e) => e.name).toList();
      expect(names, isNot(contains('moved')));
      expect(names, isNot(contains('x-up.txt')));
    });

    test('a folder with thousands of files lists in full', () async {
      const count = 2500;
      await f.createDirectory('$base/many');
      final c = f.client!;
      final tree = await c.tree(share);
      final sw = Stopwatch()..start();
      for (var i = 0; i < count; i += 50) {
        await Future.wait([
          for (var j = i; j < min(count, i + 50); j++)
            () async {
              final h = await c.create(tree, '$tag/many/file-${j.toString().padLeft(5, '0')} with a longer name.txt',
                  access: FileAccess.writeData | FileAccess.synchronize, disposition: CreateDisposition.create);
              await c.closeHandle(h);
            }(),
        ]);
      }
      final made = sw.elapsedMilliseconds;
      sw.reset();
      final entries = await f.list('$base/many');
      final listed = sw.elapsedMilliseconds;
      expect(entries.length, count);
      expect(entries.map((e) => e.name).toSet().length, count);
      expect(entries.every((e) => !e.isDirectory && e.path.startsWith('$base/many/')), isTrue);
      sw.reset();
      await f.delete('$base/many');
      // ignore: avoid_print
      print('$count files: made in ${made}ms, listed in ${listed}ms, deleted in ${sw.elapsedMilliseconds}ms');
      await expectLater(f.stat('$base/many'), throwsA(isA<RemoteException>()));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('reconnects by itself after the connection drops', () async {
      await f.write('$base/r.txt', Stream.value([7, 7, 7]));
      f.client!.connection.destroy();
      expect((await f.stat('$base/r.txt')).size, 3);
      // And in the middle of a read.
      final data = bytes(3 * 1024 * 1024, 5);
      await f.write('$base/r.bin', Stream.value(data));
      final got = BytesBuilder(copy: false);
      var dropped = false;
      await for (final c in f.openRead('$base/r.bin')) {
        got.add(c);
        if (!dropped && got.length > 1024 * 1024) {
          dropped = true;
          f.client!.connection.destroy();
        }
      }
      expect(got.takeBytes(), data);
    });

    if (q['encrypted'] case final enc?) {
      test('a share that needs encryption works, encrypted', () async {
        final e = fs(rootPath: '/$enc');
        await e.connect();
        final data = bytes(2 * 1024 * 1024 + 7, 9);
        await e.write('/$enc/$tag.bin', Stream.value(data));
        expect(await readAll(e, '/$enc/$tag.bin'), data);
        final tree = await e.client!.tree(enc);
        expect(tree.encrypt, isTrue);
        await e.delete('/$enc/$tag.bin');
        await e.close();
      });

      test('encryption can be asked for on any share', () async {
        final e = fs(extra: {'encrypt': 'true'});
        await e.connect();
        await e.write('$base/enc.txt', Stream.value([1, 2, 3, 4]));
        expect(await readAll(e, '$base/enc.txt'), [1, 2, 3, 4]);
        expect(e.client!.encrypted, isTrue);
        await e.close();
      });
    }

    if (q['guest'] case final g?) {
      test('a guest gets into a guest share with no user name', () async {
        final guest = fs(username: '', pass: '', rootPath: '/$g');
        await guest.connect();
        expect(guest.client!.isGuest, isTrue);
        await guest.list('/$g');
        await guest.close();
      });
    }

    test('speed: one big file each way', () async {
      final mb = int.tryParse(q['big'] ?? '') ?? 32;
      final data = bytes(mb * 1024 * 1024, 3);
      final sw = Stopwatch()..start();
      await f.write('$base/speed.bin', Stream.fromIterable([for (var i = 0; i < data.length; i += 1 << 20) data.sublist(i, i + (1 << 20))]));
      final w = sw.elapsedMilliseconds;
      sw.reset();
      var n = 0;
      await for (final c in f.openRead('$base/speed.bin')) {
        n += c.length;
      }
      final r = sw.elapsedMilliseconds;
      expect(n, data.length);
      // ignore: avoid_print
      print('$mb MB: write ${(mb / (w / 1000)).toStringAsFixed(1)} MB/s, read ${(mb / (r / 1000)).toStringAsFixed(1)} MB/s '
          '(SMB ${SmbDialect.name(f.client!.dialect)}, signed ${f.client!.signed}, io ${f.client!.readSize ~/ 1024} KB)');
      await f.delete('$base/speed.bin');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('${url.host}:${url.port} raw client', () {
    test('every dialect the server has signs in and reads', () async {
      for (final d in [SmbDialect.smb202, SmbDialect.smb210, SmbDialect.smb300, SmbDialect.smb302, SmbDialect.smb311]) {
        if (dialects != null && !dialects.contains(d)) continue;
        SmbClient c;
        try {
          c = await SmbClient.connect(host: url.host, port: url.port, user: user, password: password, options: SmbOptions(dialects: [d]));
        } on SmbStatusException {
          continue; // not offered by this server
        } on SmbConnectionException {
          continue;
        } on SmbProtocolException {
          continue;
        }
        final t = await c.tree(share);
        await c.list(t, '');
        // ignore: avoid_print
        print('SMB ${SmbDialect.name(d)}: ok (signed ${c.signed}, cipher ${c.connection.cipher})');
        await c.close();
      }
    });
  });
}
