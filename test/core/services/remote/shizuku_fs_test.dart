import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/shizuku/shizuku.dart';
import 'package:folders/core/services/remote/shizuku/shizuku_fs.dart';
import 'package:path/path.dart' as p;

/// ShizukuNative.kt's side of the channel, on a folder of this computer
/// standing in for the phone's Android folder.
class FakeShizuku {
  FakeShizuku(this.root);

  final Directory root;
  final calls = <String>[];
  final _reads = <int, RandomAccessFile>{};
  final _writes = <int, RandomAccessFile>{};
  var _next = 1;
  int disconnects = 0;

  /// Fails `write` after this many calls.
  int? failWriteAfter;

  String _local(Object? devicePath) {
    final path = devicePath! as String;
    expect(path, startsWith(ShizukuPlaces.androidFolder));
    return p.join(root.path, path.substring(ShizukuPlaces.androidFolder.length).replaceFirst('/', ''));
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'connect':
        return 2000;
      case 'list':
        final dir = Directory(_local(args['path']));
        if (!dir.existsSync()) throw PlatformException(code: 'notFound');
        return [
          for (final e in dir.listSync())
            {
              'name': p.basename(e.path),
              'dir': e is Directory,
              'size': e is File ? e.lengthSync() : 0,
              'modified': e.statSync().modified.millisecondsSinceEpoch,
            },
        ];
      case 'stat':
        final path = _local(args['path']);
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.notFound) throw PlatformException(code: 'notFound');
        final stat = FileStat.statSync(path);
        final dir = type == FileSystemEntityType.directory;
        return '${dir ? 'd' : 'f'}\t${dir ? 0 : stat.size}\t${stat.modified.millisecondsSinceEpoch}';
      case 'openRead':
        final file = File(_local(args['path']));
        if (!file.existsSync()) throw PlatformException(code: 'notFound');
        final raf = file.openSync()..setPositionSync((args['start'] as int?) ?? 0);
        _reads[_next] = raf;
        return _next++;
      case 'read':
        return _reads[args['handle']]!.readSync(args['max'] as int);
      case 'openWrite':
        final file = File(_local(args['path']));
        if (file.existsSync() && args['overwrite'] != true) throw PlatformException(code: 'alreadyExists');
        if (!file.parent.existsSync()) throw PlatformException(code: 'notFound');
        _writes[_next] = file.openSync(mode: FileMode.write);
        return _next++;
      case 'write':
        final left = failWriteAfter;
        if (left != null) {
          failWriteAfter = left - 1;
          if (left == 0) throw PlatformException(code: 'other', message: 'No space left');
        }
        _writes[args['handle']]!.writeFromSync(args['bytes'] as Uint8List);
        return null;
      case 'close':
        _reads.remove(args['handle'])?.closeSync();
        _writes.remove(args['handle'])?.closeSync();
        return null;
      case 'mkdir':
        final dir = Directory(_local(args['path']));
        if (dir.existsSync()) throw PlatformException(code: 'alreadyExists');
        dir.createSync();
        return null;
      case 'delete':
        final path = _local(args['path']);
        if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) throw PlatformException(code: 'notFound');
        if (FileSystemEntity.isDirectorySync(path)) {
          Directory(path).deleteSync(recursive: true);
        } else {
          File(path).deleteSync();
        }
        return null;
      case 'rename':
        final from = _local(args['from']);
        final to = _local(args['to']);
        if (FileSystemEntity.typeSync(to) != FileSystemEntityType.notFound) throw PlatformException(code: 'alreadyExists');
        if (FileSystemEntity.isDirectorySync(from)) {
          Directory(from).renameSync(to);
        } else {
          File(from).renameSync(to);
        }
        return null;
      case 'disconnect':
        disconnects++;
        return null;
    }
    throw MissingPluginException(call.method);
  }

  int get openHandles => _reads.length + _writes.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/shizuku');
  late Directory root;
  late FakeShizuku fake;
  late ShizukuFileSystem fs;

  setUp(() {
    root = Directory.systemTemp.createTempSync('shizuku_fs_test');
    Directory(p.join(root.path, 'data', 'com.game', 'files')).createSync(recursive: true);
    Directory(p.join(root.path, 'obb')).createSync();
    fake = FakeShizuku(root);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, fake.handle);
    fs = ShizukuFileSystem(ShizukuPlaces.connection, channel: channel);
  });

  tearDown(() async {
    await fs.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    root.deleteSync(recursive: true);
  });

  test('paths start at the Android folder', () {
    expect(fs.devicePath('/'), '/storage/emulated/0/Android');
    expect(fs.devicePath('/data/com.game/../com.game/files'), '/storage/emulated/0/Android/data/com.game/files');
    final card = ShizukuFileSystem(
      const RemoteConnection(id: 'sd', protocol: RemoteProtocol.shizuku, name: 'Card', options: {'base': '/storage/1234-5678/Android'}),
      channel: channel,
    );
    expect(card.devicePath('/obb'), '/storage/1234-5678/Android/obb');
  });

  test('lists and stats folders and files', () async {
    await fs.connect();
    File(p.join(root.path, 'data', 'com.game', 'files', 'save.dat')).writeAsBytesSync(List.filled(42, 7));
    final top = await fs.list('/');
    expect(top.map((e) => e.path), containsAll(['/data', '/obb']));
    expect(top.every((e) => e.isDirectory), isTrue);
    final files = await fs.list('/data/com.game/files');
    expect(files.single.path, '/data/com.game/files/save.dat');
    expect(files.single.isDirectory, isFalse);
    expect(files.single.size, 42);
    expect(files.single.modified, isNotNull);
    final stat = await fs.stat('/data/com.game/files/save.dat');
    expect(stat.size, 42);
    expect((await fs.stat('/data')).isDirectory, isTrue);
    await expectLater(fs.stat('/data/nothing'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
  });

  test('writes and reads in chunks, whole and in part', () async {
    final bytes = Uint8List.fromList(List.generate(ShizukuFileSystem.chunkSize * 2 + 1234, (i) => Random(i).nextInt(256)));
    final sent = <int>[];
    await fs.write(
      '/data/com.game/files/big.bin',
      Stream.fromIterable([for (var i = 0; i < bytes.length; i += 100000) bytes.sublist(i, min(i + 100000, bytes.length))]),
      onProgress: sent.add,
    );
    expect(sent.last, bytes.length);
    expect(fake.calls.where((c) => c == 'write').length, 2, reason: 'buffered to chunkSize or more');
    expect(File(p.join(root.path, 'data', 'com.game', 'files', 'big.bin')).readAsBytesSync(), bytes);

    final whole = await fs.openRead('/data/com.game/files/big.bin').expand((c) => c).toList();
    expect(whole, bytes);
    final part = await fs.openRead('/data/com.game/files/big.bin', start: 1000, end: ShizukuFileSystem.chunkSize + 5000).expand((c) => c).toList();
    expect(part, bytes.sublist(1000, ShizukuFileSystem.chunkSize + 5000));
    expect(await fs.openRead('/data/com.game/files/big.bin', start: 10, end: 10).toList(), isEmpty);
    expect(fake.openHandles, 0, reason: 'every handle closed');

    // Stopping early closes the file too.
    await fs.openRead('/data/com.game/files/big.bin').first;
    await pumpEventQueue();
    expect(fake.openHandles, 0);
  });

  test("doesn't overwrite unless asked, and leaves no half file", () async {
    await fs.write('/data/com.game/a.txt', Stream.value([1, 2, 3]));
    await expectLater(
      fs.write('/data/com.game/a.txt', Stream.value([4])),
      throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)),
    );
    await fs.write('/data/com.game/a.txt', Stream.value([4]), overwrite: true);
    expect(File(p.join(root.path, 'data', 'com.game', 'a.txt')).readAsBytesSync(), [4]);

    fake.failWriteAfter = 1;
    final chunk = List.filled(ShizukuFileSystem.chunkSize, 1);
    await expectLater(fs.write('/data/com.game/b.bin', Stream.fromIterable([chunk, chunk, chunk])), throwsA(isA<RemoteException>()));
    expect(File(p.join(root.path, 'data', 'com.game', 'b.bin')).existsSync(), isFalse);
    expect(fake.openHandles, 0);
  });

  test('makes folders, renames and deletes', () async {
    await fs.createDirectory('/obb/com.game');
    expect((await fs.stat('/obb/com.game')).isDirectory, isTrue);
    await fs.write('/obb/com.game/main.obb', Stream.value([9]));
    await fs.rename('/obb/com.game/main.obb', '/obb/com.game/main.1.obb');
    expect((await fs.list('/obb/com.game')).single.name, 'main.1.obb');
    await fs.write('/obb/com.game/x', Stream.value([9]));
    await expectLater(
      fs.rename('/obb/com.game/x', '/obb/com.game/main.1.obb'),
      throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)),
    );
    await fs.delete('/obb/com.game');
    expect(Directory(p.join(root.path, 'obb', 'com.game')).existsSync(), isFalse);
    await expectLater(fs.delete('/'), throwsA(isA<RemoteException>()));
  });

  test('the helper stops when the last place closes', () async {
    final other = ShizukuFileSystem(ShizukuPlaces.connection, channel: channel);
    await fs.connect();
    await other.connect();
    await fs.close();
    expect(fake.disconnects, 0);
    await other.close();
    await other.close();
    expect(fake.disconnects, 1);
  });

  test('errors in plain words', () {
    RemoteException error(String code) => ShizukuFileSystem.errorFor(PlatformException(code: code, message: 'x'), '/data/com.game');
    expect(error('notFound').kind, RemoteErrorKind.notFound);
    expect(error('notFound').message, contains('com.game'));
    expect(error('alreadyExists').kind, RemoteErrorKind.alreadyExists);
    expect(error('permission').kind, RemoteErrorKind.permission);
    expect(error('unsupported').kind, RemoteErrorKind.unsupported);
    expect(error('notRunning').kind, RemoteErrorKind.auth);
    expect(error('notRunning').message, contains('Shizuku'));
    expect(error('notAllowed').kind, RemoteErrorKind.auth);
    expect(error('weird').kind, RemoteErrorKind.other);
  });

  group('ShizukuPlaces', () {
    test('locked folders from Android 11', () {
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Android/data', sdkInt: 30), isTrue);
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Android/obb/com.game/main.obb', sdkInt: 37), isTrue);
      expect(ShizukuPlaces.isLocked('/sdcard/Android/data/com.game', sdkInt: 33), isTrue);
      expect(ShizukuPlaces.isLocked('/storage/self/primary/Android/obb', sdkInt: 33), isTrue);
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Android/data', sdkInt: 29), isFalse);
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Android/media', sdkInt: 33), isFalse);
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Android', sdkInt: 33), isFalse);
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Android/database', sdkInt: 33), isFalse);
      expect(ShizukuPlaces.isLocked('/storage/emulated/0/Download/Android/data', sdkInt: 33), isFalse);
    });

    test('redirects to the place and back', () {
      expect(
        ShizukuPlaces.redirect('/storage/emulated/0/Android/data/com.game/files', sdkInt: 33),
        'explorer://remote/shizuku/data/com.game/files',
      );
      expect(ShizukuPlaces.redirect('/sdcard/Android/obb/', sdkInt: 33), 'explorer://remote/shizuku/obb');
      expect(ShizukuPlaces.redirect('/storage/emulated/0/Android/data/a b', sdkInt: 33), 'explorer://remote/shizuku/data/a%20b');
      expect(ShizukuPlaces.redirect('/storage/emulated/0/Android/data', sdkInt: 29), isNull);
      expect(ShizukuPlaces.redirect('/storage/emulated/0/DCIM', sdkInt: 33), isNull);
      expect(ShizukuPlaces.localPathOf('explorer://remote/shizuku/data/a%20b'), '/storage/emulated/0/Android/data/a b');
      expect(ShizukuPlaces.localPathOf('explorer://remote/shizuku'), '/storage/emulated/0/Android');
      expect(ShizukuPlaces.localPathOf('explorer://remote/nas/data'), isNull);
    });
  });

  test('status reads what the phone says', () {
    expect(const ShizukuStatus(supported: false).state, ShizukuState.unsupported);
    expect(const ShizukuStatus().state, ShizukuState.notInstalled);
    expect(const ShizukuStatus(installed: true).state, ShizukuState.notRunning);
    expect(const ShizukuStatus(installed: true, running: true, version: 10).state, ShizukuState.tooOld);
    expect(const ShizukuStatus(installed: true, running: true, version: 13).state, ShizukuState.notAllowed);
    expect(const ShizukuStatus(installed: true, running: true, version: 13, denied: true).state, ShizukuState.denied);
    final ready = ShizukuStatus.fromMap(const {'installed': true, 'running': true, 'version': 13, 'granted': true, 'uid': 2000, 'sdk': 37});
    expect(ready.state, ShizukuState.ready);
    expect(ready.uid, 2000);
    expect(ready.sdk, 37);
  });
}
