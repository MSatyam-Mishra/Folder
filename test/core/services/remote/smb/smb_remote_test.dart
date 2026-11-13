import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_registry.dart';
import 'package:folders/core/services/remote/smb/smb_remote.dart';
import 'package:folders/core/services/remote/smb/windows_smb_file_system.dart';

/// Registration, the choice between Windows' client and the plain-Dart one,
/// and the Windows route's file operations (on a local folder standing in
/// for `\\host`, and, when `EXPLORER_SMB_WINDOWS_HOST` names a server
/// Windows is already connected to, on that server for real).
void main() {
  RemoteConnection conn({String host = 'nas', int? port, String user = 'me', Map<String, String> options = const {}, String rootPath = '/'}) =>
      RemoteConnection(id: 'c', protocol: RemoteProtocol.smb, name: 'NAS', host: host, port: port, username: user, options: options, rootPath: rootPath);

  test('registers as "Windows share (SMB)" on port 445', () {
    RemoteProtocols.clear();
    registerRemoteProtocols();
    final info = RemoteProtocols.of(RemoteProtocol.smb)!;
    expect(info.label, 'Windows share (SMB)');
    expect(info.defaultPort, 445);
    expect(info.usesPassword, isTrue);
    expect(info.needsHost, isTrue);
    expect(info.create(conn(), MemoryRemoteSecrets()), isA<SmbRemoteFileSystem>());
    RemoteProtocols.clear();
  });

  test('UNC paths, IPv6 literals included', () {
    final w = WindowsSmbFileSystem(conn(host: 'nas'), MemoryRemoteSecrets());
    expect(w.uncOf('/'), r'\\nas');
    expect(w.uncOf('/Public/a b/c.txt'), r'\\nas\Public\a b\c.txt');
    expect(WindowsSmbFileSystem(conn(host: 'fe80::1%12'), MemoryRemoteSecrets()).uncHost, r'\\fe80--1s12.ipv6-literal.net');
    expect(WindowsSmbFileSystem(conn(host: '[2001:db8::5]'), MemoryRemoteSecrets()).uncHost, r'\\2001-db8--5.ipv6-literal.net');
    expect(WindowsSmbFileSystem(conn(host: '192.168.1.5'), MemoryRemoteSecrets()).uncHost, r'\\192.168.1.5');
  });

  test('Windows error codes become plain words', () {
    expect(windowsSmbError(1326, host: 'nas').kind, RemoteErrorKind.auth);
    expect(windowsSmbError(67, host: 'nas').kind, RemoteErrorKind.notFound);
    expect(windowsSmbError(53, host: 'nas').kind, RemoteErrorKind.network);
    expect(windowsSmbError(183, host: 'nas').kind, RemoteErrorKind.alreadyExists);
    expect(WindowsSmbException(1219, windowsSmbError(1219, host: 'nas')).worthFallback, isTrue);
    expect(WindowsSmbException(1326, windowsSmbError(1326, host: 'nas')).worthFallback, isFalse);
  });

  test('the plain-Dart client is used off Windows, on other ports, and when asked', () async {
    // Nothing listens on these; the point is which engine tries.
    Future<String?> engineFor(RemoteConnection c, {required bool windows}) async {
      final fs = SmbRemoteFileSystem(c, MemoryRemoteSecrets(), windowsAllowed: windows);
      try {
        await fs.connect();
      } catch (_) {}
      return fs.engine;
    }

    // A refused connection leaves no engine, but must not use Windows' client
    // for a non-standard port: that would try port 445 instead.
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = s.port;
    await s.close();
    expect(await engineFor(conn(host: '127.0.0.1', port: closedPort), windows: true), isNull);
    expect(SmbRemoteFileSystem(conn(port: 4455), MemoryRemoteSecrets(), windowsAllowed: true).engine, isNull);
  });

  group('Windows route on a stand-in folder', () {
    late Directory root;
    late WindowsSmbFileSystem fs;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('folders-smb-win');
      await Directory('${root.path}${Platform.pathSeparator}Share').create();
      await Directory('${root.path}${Platform.pathSeparator}Other').create();
      fs = WindowsSmbFileSystem(conn(), MemoryRemoteSecrets(), rootOverride: root.path);
      await fs.connect();
    });

    tearDown(() async {
      await fs.close();
      await root.delete(recursive: true);
    });

    Future<List<int>> readAll(String p, {int start = 0, int? end}) async =>
        [for (final c in await fs.openRead(p, start: start, end: end).toList()) ...c];

    test('shares, files, ranges, rename, delete', () async {
      expect((await fs.list('/')).map((e) => e.name).toSet(), {'Share', 'Other'});
      final data = Uint8List.fromList(List.generate(300000, (i) => (i * 13) & 0xff));
      var progress = 0;
      await fs.write('/Share/a.bin', Stream.value(data), onProgress: (n) => progress = n);
      expect(progress, data.length);
      await expectLater(fs.write('/Share/a.bin', Stream.value([1])), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
      expect(await readAll('/Share/a.bin'), data);
      expect(await readAll('/Share/a.bin', start: 1000, end: 2000), data.sublist(1000, 2000));
      final st = await fs.stat('/Share/a.bin');
      expect(st.size, data.length);
      expect(st.isDirectory, isFalse);
      await fs.createDirectory('/Share/dir');
      await expectLater(fs.createDirectory('/Share/dir'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
      await fs.write('/Share/dir/b.txt', Stream.value([1, 2, 3]));
      final listing = await fs.list('/Share');
      expect(listing.map((e) => (e.name, e.isDirectory, e.size)).toSet(), {('a.bin', false, data.length), ('dir', true, 0)});
      expect(listing.firstWhere((e) => e.name == 'a.bin').modified, isNotNull);
      await fs.rename('/Share/dir/b.txt', '/Share/c.txt');
      await fs.write('/Share/d.txt', Stream.value([4]));
      await expectLater(fs.rename('/Share/d.txt', '/Share/c.txt'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
      await fs.delete('/Share/dir');
      await fs.delete('/Share/c.txt');
      await expectLater(fs.stat('/Share/c.txt'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
      await expectLater(fs.delete('/Share/c.txt'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
      await expectLater(fs.list('/Share/nothing'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
      // A failed write doesn't leave a half file.
      final broken = Stream<List<int>>.fromIterable([List.filled(1000, 1)]).asyncExpand((c) async* {
        yield c;
        throw StateError('source failed');
      });
      await expectLater(fs.write('/Share/broken.bin', broken), throwsA(anything));
      expect(File('${root.path}${Platform.pathSeparator}Share${Platform.pathSeparator}broken.bin').existsSync(), isFalse);
    });
  }, skip: Platform.isWindows ? false : 'the folder listing uses Windows\' FindFirstFileExW');

  final realHost = Platform.environment['EXPLORER_SMB_WINDOWS_HOST'];
  final realShare = Platform.environment['EXPLORER_SMB_WINDOWS_SHARE'] ?? 'data';
  test('Windows route on a real server', () async {
    // Windows must already be connected (net use \\host\share /TCPPORT:...
    // for a test server on another port); no user name means "as is".
    final fs = WindowsSmbFileSystem(conn(host: realHost!, user: '', rootPath: '/$realShare'), MemoryRemoteSecrets());
    await fs.connect();
    final shares = (await fs.list('/')).map((e) => e.name.toLowerCase()).toList();
    expect(shares, contains(realShare.toLowerCase()));
    final dir = '/$realShare/folders-win-${Random().nextInt(1 << 30)}';
    await fs.createDirectory(dir);
    final data = Uint8List.fromList(List.generate(5 << 20, (i) => (i * 7) & 0xff));
    await fs.write('$dir/big.bin', Stream.value(data));
    final back = [for (final c in await fs.openRead('$dir/big.bin').toList()) ...c];
    expect(back.length, data.length);
    expect(Uint8List.fromList(back), data);
    for (var i = 0; i < 300; i++) {
      await fs.write('$dir/f$i.txt', Stream.value([i & 0xff]));
    }
    expect((await fs.list(dir)).length, 301);
    await fs.rename('$dir/big.bin', '$dir/renamed.bin');
    expect((await fs.stat('$dir/renamed.bin')).size, data.length);
    await fs.delete(dir);
    await expectLater(fs.stat(dir), throwsA(isA<RemoteException>()));
    await fs.close();
  }, skip: realHost == null ? 'set EXPLORER_SMB_WINDOWS_HOST' : false, timeout: const Timeout(Duration(minutes: 3)));
}
