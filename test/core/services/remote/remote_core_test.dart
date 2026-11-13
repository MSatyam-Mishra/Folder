import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_repository.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fake_remote.dart';

/// Saved places, the connection pool, the browser's entities and paths.
void main() {
  late FakeRemoteServer server;
  late MemoryRemoteSecretStore secrets;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RemoteProtocols.clear();
    server = FakeRemoteServer()..addFile('/Photos/a b.jpg', 'jpeg!');
    registerFakeProtocol({'': server});
    secrets = MemoryRemoteSecretStore();
    RemotePlaces.instance.reset(secretStore: secrets);
    RemotePool.instance = RemotePool(closeIdle: false);
    await RemotePlaces.instance.save(
      const RemoteConnection(id: 'nas', protocol: RemoteProtocol.sftp, name: 'NAS', host: 'nas.local', username: 'me'),
      secrets: {'password': 'secret'},
    );
  });

  tearDown(() => RemotePool.instance.closeAll());

  group('saved places', () {
    test('settings in SharedPreferences, secrets not', () async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(RemotePlaces.prefsKey)!;
      expect(saved, contains('nas.local'));
      expect(saved, isNot(contains('secret')));
      expect(await secrets.readAll('nas'), {'password': 'secret'});

      // Read again as at the next start.
      final again = RemotePlaces(secretStore: secrets);
      await again.load();
      expect(again.places.single.name, 'NAS');
      expect(again.places.single.host, 'nas.local');
      expect(await again.secretsOf('nas').read('password'), 'secret');
    });

    test('rename, edit secrets and remove', () async {
      final places = RemotePlaces.instance;
      var heard = 0;
      places.addListener(() => heard++);
      await places.rename('nas', 'Home NAS');
      expect(places.byId('nas')!.name, 'Home NAS');
      await places.save(places.byId('nas')!, secrets: {'password': null, 'privateKey': 'KEY'});
      expect(await secrets.readAll('nas'), {'privateKey': 'KEY'});
      await places.remove('nas');
      expect(places.places, isEmpty);
      expect(await secrets.readAll('nas'), isEmpty);
      expect(heard, 3);
    });

    test('new ids are letters and digits, and new', () {
      final id = RemotePlaces.instance.newId();
      expect(id, matches(RegExp(r'^[a-z0-9]+$')));
      expect(id, isNot('nas'));
      expect(RemotePlaces.instance.describe(RemotePaths.build('nas', '/Photos/2026')), 'NAS: /Photos/2026');
    });
  });

  group('pool', () {
    test('connects once, on first use', () async {
      expect(server.connects, 0);
      await RemotePool.instance.run('nas', (fs) => fs.list('/'));
      await RemotePool.instance.run('nas', (fs) => fs.stat('/Photos'));
      expect(server.connects, 1);
    });

    test('connects again after the line dropped, and tries once more', () async {
      await RemotePool.instance.run('nas', (fs) => fs.list('/'));
      server.dropNext = true;
      final listed = await RemotePool.instance.run('nas', (fs) => fs.list('/Photos'));
      expect(listed.single.name, 'a b.jpg');
      expect(server.connects, 2);
    });

    test("a wrong password isn't tried again, and the next call connects anew", () async {
      server.password = 'changed';
      await expectLater(
        RemotePool.instance.run('nas', (fs) => fs.list('/')),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.auth)),
      );
      expect(server.connects, 0);
      server.password = 'secret';
      await RemotePool.instance.run('nas', (fs) => fs.list('/'));
      expect(server.connects, 1);
    });

    test('a removed place says so', () async {
      await expectLater(
        RemotePool.instance.run('gone', (fs) => fs.list('/')),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)),
      );
    });

    test('closes connections left unused', () async {
      var now = DateTime(2026, 1, 1, 12);
      final pool = RemotePool(closeIdle: false, clock: () => now, idleTimeout: const Duration(minutes: 5));
      await pool.run('nas', (fs) => fs.list('/'));
      expect(server.open, 1);
      now = now.add(const Duration(minutes: 4));
      await pool.closeIdleNow();
      expect(server.open, 1);
      now = now.add(const Duration(minutes: 2));
      await pool.closeIdleNow();
      expect(server.open, 0);
      expect(pool.openIds, isEmpty);
    });

    test('reads through the pool, connecting first', () async {
      final bytes = await RemotePool.instance.openRead('nas', '/Photos/a b.jpg', start: 1, end: 4).expand((c) => c).toList();
      expect(utf8.decode(bytes), 'peg');
    });

    test('maps socket errors to plain words', () {
      expect(remoteError(const SocketException('x', osError: OSError('refused', 111))).kind, RemoteErrorKind.network);
      expect(remoteError(const SocketException('x', osError: OSError('refused', 111))).message, contains('refused'));
      expect(remoteError(StateError('odd')).kind, RemoteErrorKind.other);
    });
  });

  group('entities and paths', () {
    test('the repository lists entities that answer from their listing', () async {
      final entities = await RemoteFileRepository().listEntities(RemotePaths.build('nas', '/Photos'));
      final file = entities.single as File;
      expect(file, isA<RemoteFile>());
      expect(file.path, 'explorer://remote/nas/Photos/a%20b.jpg');
      expect((await file.stat()).size, 5);
      expect((await file.stat()).modified, DateTime(2026, 1, 2, 3, 4));
      expect(await file.length(), 5);
      expect(file.parent.path, 'explorer://remote/nas/Photos');
      expect(ExplorerPaths.displayNameForEntity(file.path), 'a b.jpg');
      expect(utf8.decode(await file.openRead().expand((c) => c).toList()), 'jpeg!');
    });

    test("anything else never reaches this device's disks", () async {
      final file = RemoteFile('nas', const RemoteEntry(path: '/x.txt', isDirectory: false));
      expect(() => file.readAsStringSync(), throwsA(isA<FileSystemException>()));
      expect(() => file.delete(), throwsA(isA<FileSystemException>()));
      expect(() => file.copy('C:/x.txt'), throwsA(isA<FileSystemException>()));
      final folder = RemoteDirectory('nas', const RemoteEntry(path: '/', isDirectory: true));
      expect(() => folder.createSync(), throwsA(isA<FileSystemException>()));
      expect(Directory('C:/c').existsSync(), isFalse);
    });

    test('a folder lists inside, and everything below', () async {
      server.addFile('/Photos/2026/b.jpg', 'b');
      final folder = RemoteDirectory('nas', const RemoteEntry(path: '/Photos', isDirectory: true));
      expect((await folder.list().toList()).map((e) => e.path), unorderedEquals([
        'explorer://remote/nas/Photos/a%20b.jpg',
        'explorer://remote/nas/Photos/2026',
      ]));
      expect((await folder.list(recursive: true).toList()).length, 3);
    });

    test('titles, parents and what can be done there', () async {
      final root = RemotePaths.build('nas', '/');
      final photos = RemotePaths.build('nas', '/Photos');
      expect(ExplorerPaths.isRemote(photos), isTrue);
      expect(ExplorerPaths.isVirtual(photos), isFalse, reason: 'folders can be made there');
      expect(ExplorerPaths.isLocal(photos), isFalse);
      expect(ExplorerPaths.isOnDisk(photos), isFalse);
      expect(ExplorerPaths.titleForPath(root), 'NAS');
      expect(ExplorerPaths.titleForPath(RemotePaths.build('nas', '/Photos/a b')), 'a b');
      expect(ExplorerPaths.parentOf(RemotePaths.build('nas', '/Photos/a b')), photos);
      expect(ExplorerPaths.parentOf(photos), root);
      expect(ExplorerPaths.parentOf(root), ExplorerPaths.homePath);
      expect(ExplorerPaths.isRemoteRoot(root), isTrue);
      expect(ExplorerPaths.isRemoteRoot(photos), isFalse);
    });
  });
}
