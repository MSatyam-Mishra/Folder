import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/ftp/ftp_fs.dart';
import 'package:folders/core/services/remote/known_hosts.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/sftp/sftp_fs.dart';
import 'package:folders/core/services/remote/webdav/webdav_fs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The SFTP, FTP, FTPS and WebDAV clients against real servers. Opt-in:
/// EXPLORER_REMOTE_SERVERS points to the servers.json that
/// tool/remote_servers/remote_test_servers.py writes once its servers are up.
void main() {
  final infoPath = Platform.environment['EXPLORER_REMOTE_SERVERS'];
  final skip = infoPath == null ? 'Set EXPLORER_REMOTE_SERVERS to run against real servers' : null;
  final info = infoPath == null ? const <String, Object?>{} : jsonDecode(File(infoPath).readAsStringSync()) as Map<String, Object?>;
  final user = info['user'] as String? ?? '';
  final password = info['password'] as String? ?? '';

  setUp(() {
    if (Platform.environment['EXPLORER_FTP_LOG'] != null) ftpDebugLog = debugPrint;
    SharedPreferences.setMockInitialValues({});
    RemoteKnownHosts.instance.reset();
  });

  RemoteConnection place(RemoteProtocol protocol, String portKey, {Map<String, String> options = const {}, String host = '127.0.0.1'}) =>
      RemoteConnection(
        id: 'test',
        protocol: protocol,
        name: 'Test',
        host: host,
        port: info[portKey] as int?,
        username: user,
        options: options,
      );

  Future<String> readAll(Stream<List<int>> stream) async => utf8.decode([for (final chunk in await stream.toList()) ...chunk]);

  /// The same steps on every protocol.
  Future<void> exercise(RemoteFileSystem fs) async {
    final folder = '/run ${DateTime.now().microsecondsSinceEpoch} é';
    await fs.createDirectory(folder);
    await expectLater(fs.createDirectory(folder), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    final file = '$folder/notes #1 ü.txt';
    final text = 'Hello, network places. ${'0123456789' * 2000}';
    final bytes = utf8.encode(text);
    var sent = 0;
    await fs.write(file, Stream.fromIterable([bytes.sublist(0, 1000), bytes.sublist(1000)]), length: bytes.length, onProgress: (s) => sent = s);
    expect(sent, bytes.length);
    await expectLater(
      fs.write(file, Stream.value(Uint8List(3)), length: 3),
      throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)),
    );
    await fs.createDirectory('$folder/inside');
    await fs.write('$folder/inside/deep.bin', Stream.value(List.filled(10, 7)), length: 10);

    final listed = await fs.list(folder);
    expect({for (final e in listed) e.name}, {'notes #1 ü.txt', 'inside'});
    final entry = listed.firstWhere((e) => e.name == 'notes #1 ü.txt');
    expect(entry.isDirectory, isFalse);
    expect(entry.size, bytes.length);
    expect(entry.path, file);
    expect(listed.firstWhere((e) => e.name == 'inside').isDirectory, isTrue);

    final stat = await fs.stat(file);
    expect(stat.size, bytes.length);
    expect(stat.isDirectory, isFalse);
    expect((await fs.stat(folder)).isDirectory, isTrue);
    await expectLater(fs.stat('$folder/missing.txt'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));

    expect(await readAll(fs.openRead(file)), text);
    expect(await readAll(fs.openRead(file, start: 7, end: 21)), text.substring(7, 21));
    expect(await readAll(fs.openRead(file, start: bytes.length - 5)), text.substring(text.length - 5));
    // Stopping a read part way leaves the connection usable.
    final first = await fs.openRead(file).first;
    expect(first, isNotEmpty);
    expect(await readAll(fs.openRead(file, start: 1, end: 6)), text.substring(1, 6));

    await fs.write(file, Stream.value(utf8.encode('short')), length: 5, overwrite: true);
    expect(await readAll(fs.openRead(file)), 'short');

    final renamed = '$folder/renamed.txt';
    await fs.rename(file, renamed);
    await fs.write(file, Stream.value(utf8.encode('again')), length: 5);
    await expectLater(fs.rename(file, renamed), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await fs.rename('$folder/inside', '$folder/moved inside');
    expect({for (final e in await fs.list(folder)) e.name}, {'renamed.txt', 'notes #1 ü.txt', 'moved inside'});
    expect(await readAll(fs.openRead('$folder/moved inside/deep.bin')), String.fromCharCodes(List.filled(10, 7)));

    await fs.delete(folder);
    await expectLater(fs.stat(folder), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
  }

  Future<void> wrongPassword(RemoteFileSystem fs) async {
    await expectLater(fs.connect(), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.auth)));
    await fs.close();
  }

  group('SFTP', () {
    test('password: every step', () async {
      final fs = SftpFileSystem(place(RemoteProtocol.sftp, 'sftp'), MemoryRemoteSecrets({'password': password}));
      await fs.connect();
      await exercise(fs);
      await fs.close();
    });

    test('private key with a passphrase', () async {
      final key = File(info['key'] as String).readAsStringSync();
      final fs = SftpFileSystem(place(RemoteProtocol.sftp, 'sftp'),
          MemoryRemoteSecrets({'privateKey': key, 'passphrase': info['keyPassphrase'] as String}));
      await fs.connect();
      expect(await fs.list('/'), isA<List<RemoteEntry>>());
      await fs.close();

      final noPassphrase = SftpFileSystem(place(RemoteProtocol.sftp, 'sftp'), MemoryRemoteSecrets({'privateKey': key}));
      await expectLater(noPassphrase.connect(), throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('passphrase'))));
    });

    test('a wrong password is an auth error', () async {
      await wrongPassword(SftpFileSystem(place(RemoteProtocol.sftp, 'sftp'), MemoryRemoteSecrets({'password': 'nope'})));
    });

    test('the host key is kept, and a changed one stops the connection', () async {
      final fs = SftpFileSystem(place(RemoteProtocol.sftp, 'sftp'), MemoryRemoteSecrets({'password': password}));
      await fs.connect();
      await fs.close();
      final key = RemoteKnownHosts.keyFor('sftp', '127.0.0.1', info['sftp'] as int);
      final kept = await RemoteKnownHosts.instance.fingerprintOf(key);
      expect(kept, startsWith('ssh-ed25519 SHA256:'));

      await RemoteKnownHosts.instance.remember(key, 'ssh-ed25519 SHA256:someoneelse');
      final again = SftpFileSystem(place(RemoteProtocol.sftp, 'sftp'), MemoryRemoteSecrets({'password': password}));
      RemoteTrustException? caught;
      try {
        await again.connect();
      } on RemoteTrustException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.fingerprint, kept);
      await caught.trust();
      await again.connect();
      await again.close();
    });
  }, skip: skip);

  group('FTP', () {
    test('passive: every step', () async {
      final fs = FtpFileSystem(place(RemoteProtocol.ftp, 'ftp'), MemoryRemoteSecrets({'password': password}));
      await fs.connect();
      await exercise(fs);
      await fs.close();
    });

    test('active mode', () async {
      final fs = FtpFileSystem(place(RemoteProtocol.ftp, 'ftp', options: {'passive': 'false'}), MemoryRemoteSecrets({'password': password}));
      await fs.connect();
      await fs.write('/active.txt', Stream.value(utf8.encode('active')), length: 6, overwrite: true);
      expect(await readAll(fs.openRead('/active.txt')), 'active');
      expect((await fs.list('/')).map((e) => e.name), contains('active.txt'));
      await fs.delete('/active.txt');
      await fs.close();
    });

    test('several things at once', () async {
      final fs = FtpFileSystem(place(RemoteProtocol.ftp, 'ftp'), MemoryRemoteSecrets({'password': password}));
      await fs.connect();
      await fs.write('/a.txt', Stream.value(utf8.encode('A' * 100000)), length: 100000, overwrite: true);
      final results = await Future.wait([
        readAll(fs.openRead('/a.txt')),
        fs.list('/').then((l) => '${l.length}'),
        readAll(fs.openRead('/a.txt', start: 10, end: 20)),
        fs.stat('/a.txt').then((e) => '${e.size}'),
      ]);
      expect(results[0].length, 100000);
      expect(results[2], 'A' * 10);
      expect(results[3], '100000');
      await fs.delete('/a.txt');
      await fs.close();
    });

    test('a wrong password is an auth error', () async {
      await wrongPassword(FtpFileSystem(place(RemoteProtocol.ftp, 'ftp'), MemoryRemoteSecrets({'password': 'nope'})));
    });
  }, skip: skip);

  group('FTPS', () {
    /// The test server's own certificate, trusted as if the user had said so
    /// before. (Refusing it mid-handshake crashes pyftpdlib, so the refusal
    /// is tried last.)
    Future<void> trustServer(int port) async {
      final pem = File('${info['work']}${Platform.pathSeparator}cert.pem').readAsStringSync();
      final der = base64.decode(const LineSplitter().convert(pem).where((l) => l.isNotEmpty && !l.startsWith('-----')).join());
      final fingerprint = sha256.convert(der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
      await RemoteKnownHosts.instance.remember(RemoteKnownHosts.keyFor('tls', 'localhost', port), fingerprint);
    }

    test('explicit TLS: every step', () async {
      await trustServer(info['ftps'] as int);
      final fs = FtpFileSystem(place(RemoteProtocol.ftps, 'ftps', host: 'localhost'), MemoryRemoteSecrets({'password': password}));
      await fs.connect();
      await exercise(fs);
      await fs.close();
    });

    test('implicit TLS: every step', () async {
      await trustServer(info['ftpsImplicit'] as int);
      final fs = FtpFileSystem(
        place(RemoteProtocol.ftps, 'ftpsImplicit', host: 'localhost', options: {'implicitTls': 'true'}),
        MemoryRemoteSecrets({'password': password}),
      );
      await fs.connect();
      await exercise(fs);
      await fs.close();
    }, skip: info['ftpsImplicit'] == null ? 'No implicit FTPS server' : null);

    test("a certificate this device doesn't know is asked about", () async {
      final fs = FtpFileSystem(place(RemoteProtocol.ftps, 'ftps', host: 'localhost'), MemoryRemoteSecrets({'password': password}));
      await expectLater(
        fs.connect(),
        throwsA(isA<RemoteTrustException>().having((e) => e.message, 'message', contains("doesn't know the server's certificate"))),
      );
    });
  }, skip: skip);

  group('WebDAV', () {
    test('Basic sign-in over HTTP: every step', () async {
      final fs = WebDavFileSystem(
        place(RemoteProtocol.webdav, 'webdavBasic', options: {'https': 'false', 'path': '/dav'}),
        MemoryRemoteSecrets({'password': password}),
      );
      await fs.connect();
      await exercise(fs);
      await fs.close();
    });

    test('Digest sign-in, the address typed whole', () async {
      final fs = WebDavFileSystem(
        place(RemoteProtocol.webdav, 'webdavDigest', host: 'http://127.0.0.1:${info['webdavDigest']}/dav'),
        MemoryRemoteSecrets({'password': password}),
      );
      await fs.connect();
      await exercise(fs);
      await fs.close();
    });

    test('HTTPS with its own certificate, trusted once', () async {
      final fs = WebDavFileSystem(
        place(RemoteProtocol.webdav, 'webdavHttps', host: 'localhost', options: {'path': '/dav'}),
        MemoryRemoteSecrets({'password': password}),
      );
      RemoteTrustException? caught;
      try {
        await fs.connect();
      } on RemoteTrustException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      await caught!.trust();
      await fs.connect();
      await fs.write('/https.txt', Stream.value(utf8.encode('tls')), length: 3, overwrite: true);
      expect(await readAll(fs.openRead('/https.txt')), 'tls');
      await fs.delete('/https.txt');
      await fs.close();
    });

    test('a wrong password is an auth error', () async {
      await wrongPassword(WebDavFileSystem(
        place(RemoteProtocol.webdav, 'webdavDigest', options: {'https': 'false', 'path': '/dav'}),
        MemoryRemoteSecrets({'password': 'nope'}),
      ));
    });
  }, skip: skip);
}
