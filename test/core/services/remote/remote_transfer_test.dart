import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:folders/core/services/remote/remote_transfer.dart';
import 'package:folders/features/clipboard/paste_task.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fake_remote.dart';

/// Copying and moving between this device and network places, and between
/// two places.
void main() {
  late FakeRemoteServer nas;
  late FakeRemoteServer cloud;
  late Directory local;

  String onNas(String path) => RemotePaths.build('nas', path);
  String onCloud(String path) => RemotePaths.build('cloud', path);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RemoteProtocols.clear();
    nas = FakeRemoteServer()
      ..addFile('/Docs/report.txt', 'report')
      ..addFile('/Docs/Plans/a.txt', 'plan a')
      ..addFile('/Docs/Plans/deep/b.txt', 'plan b');
    cloud = FakeRemoteServer()..addFolder('/Inbox');
    registerFakeProtocol({'nas': nas, 'cloud': cloud});
    final secrets = MemoryRemoteSecretStore();
    RemotePlaces.instance.reset(secretStore: secrets);
    RemotePool.instance = RemotePool(closeIdle: false);
    for (final id in ['nas', 'cloud']) {
      await RemotePlaces.instance.save(
        RemoteConnection(id: id, protocol: RemoteProtocol.sftp, name: id, host: '$id.local'),
        secrets: {'password': 'secret'},
      );
    }
    local = await Directory.systemTemp.createTemp('remote_transfer');
  });

  tearDown(() async {
    await RemotePool.instance.closeAll();
    await local.delete(recursive: true);
  });

  test('says when the remote engine is needed', () {
    expect(transferNeedsRemote(['C:/a.txt'], 'C:/b'), isFalse);
    expect(transferNeedsRemote([onNas('/a')], 'C:/b'), isTrue);
    expect(transferNeedsRemote(['C:/a.txt'], onNas('/')), isTrue);
  });

  test('from a place to this device: files and folders with all inside', () async {
    final progress = <PasteProgress>[];
    final targets = await transferEntities(
      [onNas('/Docs/report.txt'), onNas('/Docs/Plans')],
      local.path,
      move: false,
      onProgress: progress.add,
    );
    expect(targets, [p.join(local.path, 'report.txt'), p.join(local.path, 'Plans')]);
    expect(File(p.join(local.path, 'report.txt')).readAsStringSync(), 'report');
    expect(File(p.join(local.path, 'Plans', 'deep', 'b.txt')).readAsStringSync(), 'plan b');
    expect(File(p.join(local.path, 'report.txt')).lastModifiedSync(), DateTime(2026, 1, 2, 3, 4));
    expect(progress.last.done, 'report'.length + 'plan a'.length + 'plan b'.length);
    expect(progress.last.total, progress.last.done);
    expect(nas.exists('/Docs/report.txt'), isTrue, reason: 'copied, not moved');
  });

  test('from this device to a place, with nothing overwritten', () async {
    await File(p.join(local.path, 'photo.jpg')).writeAsString('pixels');
    await Directory(p.join(local.path, 'Album', 'Day 1')).create(recursive: true);
    await File(p.join(local.path, 'Album', 'Day 1', 'x.jpg')).writeAsString('x');
    nas.addFile('/Inbox/photo.jpg', 'already here');

    final targets = await transferEntities(
      [p.join(local.path, 'photo.jpg'), p.join(local.path, 'Album')],
      onNas('/Inbox'),
      move: false,
    );
    expect(targets, [onNas('/Inbox/photo (2).jpg'), onNas('/Inbox/Album')]);
    expect(nas.text('/Inbox/photo.jpg'), 'already here');
    expect(nas.text('/Inbox/photo (2).jpg'), 'pixels');
    expect(nas.text('/Inbox/Album/Day 1/x.jpg'), 'x');
  });

  test('a move to a place copies, then deletes here', () async {
    await File(p.join(local.path, 'move me.txt')).writeAsString('bye');
    await transferEntities([p.join(local.path, 'move me.txt')], onNas('/'), move: true);
    expect(nas.text('/move me.txt'), 'bye');
    expect(File(p.join(local.path, 'move me.txt')).existsSync(), isFalse);
  });

  test('within one place: a move renames, a copy into its own folder is "- Copy"', () async {
    nas.addFolder('/Archive');
    final moved = await transferEntities([onNas('/Docs/Plans')], onNas('/Archive'), move: true);
    expect(moved, [onNas('/Archive/Plans')]);
    expect(nas.text('/Archive/Plans/deep/b.txt'), 'plan b');
    expect(nas.exists('/Docs/Plans'), isFalse);

    final copied = await transferEntities([onNas('/Docs/report.txt')], onNas('/Docs'), move: false);
    expect(copied, [onNas('/Docs/report - Copy.txt')]);
    expect(nas.text('/Docs/report - Copy.txt'), 'report');

    // Moving into where it is already does nothing.
    expect(await transferEntities([onNas('/Docs/report.txt')], onNas('/Docs'), move: true), [onNas('/Docs/report.txt')]);
  });

  test("a folder can't go into itself", () async {
    await expectLater(
      transferEntities([onNas('/Docs')], onNas('/Docs/Plans'), move: false),
      throwsA(isA<RemoteException>()),
    );
  });

  test('between two places: copied across, and moved by copying then deleting', () async {
    await transferEntities([onNas('/Docs/Plans')], onCloud('/Inbox'), move: false);
    expect(cloud.text('/Inbox/Plans/a.txt'), 'plan a');
    expect(nas.exists('/Docs/Plans'), isTrue);
    await transferEntities([onNas('/Docs/report.txt')], onCloud('/'), move: true);
    expect(cloud.text('/report.txt'), 'report');
    expect(nas.exists('/Docs/report.txt'), isFalse);
  });

  test('cancelling stops at the next chunk and leaves no half file', () async {
    nas.addFile('/big.bin', 'x' * 400);
    final cancel = RemoteCancel();
    var chunks = 0;
    nas.beforeChunk = () async {
      if (++chunks == 10) cancel.cancel();
    };
    await expectLater(
      transferEntities([onNas('/big.bin')], local.path, move: false, cancel: cancel),
      throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.cancelled)),
    );
    expect(File(p.join(local.path, 'big.bin')).existsSync(), isFalse);
  });

  test('a copy broken off as the line dropped is made again', () async {
    // Big enough to come in several chunks: the line drops after the first.
    nas.dropNextWrite = true;
    final source = p.join(local.path, 'again.txt');
    final big = 'y' * 200000;
    await File(source).writeAsString(big);
    final targets = await transferEntities([source], onNas('/'), move: false);
    expect(targets, [onNas('/again.txt')]);
    expect(nas.text('/again.txt'), big);
    expect(nas.connects, 2);
  });
}
