import 'dart:io';
import 'dart:typed_data';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/trash/spec_trash.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/core/services/trash/windows_recycle_bin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late Directory trashDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('trash_test');
    trashDir = Directory(p.join(root.path, 'trash'));
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  File file(String name, [String text = 'x']) => File(p.join(root.path, name))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  group('the freedesktop.org layout', () {
    test('moves to files/ with a .trashinfo, lists, restores and deletes for good', () async {
      final trash = SpecTrash.inFolder(trashDir.path);
      final a = file('docs/a report.txt', 'hello');
      final folder = Directory(p.join(root.path, 'docs', 'Photos'))..createSync();
      File(p.join(folder.path, 'one.jpg')).writeAsStringSync('jpg');

      final result = await trash.moveToTrash([a.path, folder.path]);
      expect(result.failed, isEmpty);
      expect(result.trashed.map((i) => i.name), ['a report.txt', 'Photos']);
      expect(a.existsSync(), isFalse);
      expect(folder.existsSync(), isFalse);
      expect(File(p.join(trashDir.path, 'files', 'a report.txt')).readAsStringSync(), 'hello');
      final info = File(p.join(trashDir.path, 'info', 'a report.txt.trashinfo')).readAsStringSync();
      expect(info, startsWith('[Trash Info]\nPath='));
      expect(info, contains('a%20report.txt'));
      expect(info, matches(RegExp(r'DeletionDate=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\n')));

      final listed = await trash.list();
      expect(listed.map((i) => i.name).toSet(), {'a report.txt', 'Photos'});
      final photos = listed.firstWhere((i) => i.name == 'Photos');
      expect(photos.isDirectory, isTrue);
      expect(photos.originalPath, p.normalize(folder.path));
      expect(listed.firstWhere((i) => i.isDirectory == false).size, 5);

      // Something new took the name meanwhile: it comes back beside it.
      a.writeAsStringSync('new');
      final restored = await trash.restore(listed.firstWhere((i) => i.name == 'a report.txt'));
      expect(p.basename(restored), 'a report (2).txt');
      expect(File(restored).readAsStringSync(), 'hello');
      expect(a.readAsStringSync(), 'new');
      expect(File(p.join(trashDir.path, 'info', 'a report.txt.trashinfo')).existsSync(), isFalse);

      await trash.deleteForGood(photos);
      expect(await trash.list(), isEmpty);
      expect(Directory(p.join(trashDir.path, 'files', 'Photos')).existsSync(), isFalse);
    });

    test('two items of the same name both stay, under different names', () async {
      final trash = SpecTrash.inFolder(trashDir.path);
      final first = file('one/notes.txt', '1');
      final second = file('two/notes.txt', '2');
      await trash.moveToTrash([first.path]);
      await trash.moveToTrash([second.path]);
      final items = await trash.list();
      expect(items, hasLength(2));
      expect({for (final i in items) p.basename(i.storedPath)}, {'notes.txt', 'notes.2.txt'});
      expect({for (final i in items) i.name}, {'notes.txt'});
      for (final item in items) {
        await trash.restore(item);
      }
      expect(first.readAsStringSync(), '1');
      expect(second.readAsStringSync(), '2');
    });

    test('empties, and its own Trash forgets what is older than the setting', () async {
      var now = DateTime(2026, 1, 1, 12);
      final trash = SpecTrash.inFolder(trashDir.path, now: () => now);
      await trash.moveToTrash([file('old.txt').path]);
      now = DateTime(2026, 1, 25, 12);
      await trash.moveToTrash([file('recent.txt').path]);
      now = DateTime(2026, 2, 3, 12);
      expect((await trash.list()).map((i) => i.name), ['recent.txt'], reason: 'old.txt was 33 days in');
      expect(File(p.join(trashDir.path, 'files', 'old.txt')).existsSync(), isFalse);

      await TrashSettings.setKeepDays(0);
      now = DateTime(2027, 1, 1);
      expect((await trash.list()).map((i) => i.name), ['recent.txt'], reason: 'kept until emptied');

      await trash.empty();
      expect(await trash.list(), isEmpty);
      expect(Directory(p.join(trashDir.path, 'files')).listSync(), isEmpty);
    });

    test("what isn't on disk, or is the Trash itself, can't go there", () async {
      final trash = SpecTrash.inFolder(trashDir.path);
      expect(trash.canTrash(file('a.txt').path), isTrue);
      expect(trash.canTrash(ExplorerPaths.trash), isFalse);
      expect(trash.canTrash(ExplorerPaths.windowsRoots), isFalse);
      expect(trash.canTrash('explorer://remote/nas/Photos/a.jpg'), isFalse);
      expect(trash.canTrash(p.join(trashDir.path, 'files', 'x.txt')), isFalse);
      final result = await trash.moveToTrash(['explorer://remote/nas/a.txt', p.join(root.path, 'missing.txt')]);
      expect(result.trashed, isEmpty);
      expect(result.failed.keys, hasLength(2));
    });

    test('.trashinfo paths: escaped, absolute or relative to the drive', () {
      final at = DateTime(2026, 3, 4, 5, 6, 7);
      final home = SpecTrash.trashInfo('/home/me/My 100% notes.txt', at);
      expect(home, '[Trash Info]\nPath=/home/me/My%20100%25%20notes.txt\nDeletionDate=2026-03-04T05:06:07\n');
      final parsed = SpecTrash.parseTrashInfo(home)!;
      expect(parsed.path, p.normalize('/home/me/My 100% notes.txt'));
      expect(parsed.deletedAt, at);

      final usb = SpecTrash.trashInfo('/media/usb/Pics/a.jpg', at, top: '/media/usb');
      // Joined by the system's separator (escaped on Windows, where tests run too).
      expect(usb, contains(Platform.isWindows ? 'Path=Pics%5Ca.jpg\n' : 'Path=Pics/a.jpg\n'));
      expect(SpecTrash.parseTrashInfo(usb, top: '/media/usb')!.path, p.normalize('/media/usb/Pics/a.jpg'));
      expect(SpecTrash.parseTrashInfo('[Desktop Entry]\nPath=/x\n'), isNull);
    });

    test("Linux: a drive's top from /proc/self/mounts, and its Trash", () {
      final mounts = LinuxMounts(read: () => [
            '/dev/nvme0n1p2 / ext4 rw 0 0',
            'proc /proc proc rw 0 0',
            '/dev/sdb1 /media/me/My\\040Disk vfat rw 0 0',
            'tmpfs /tmp tmpfs rw 0 0',
          ].join('\n'));
      expect(mounts.topOf('/home/me/a.txt'), '/');
      expect(mounts.topOf('/media/me/My Disk/x/y.png'), '/media/me/My Disk');
      expect(mounts.topOf('/tmp/a'), '/tmp');
      expect(mounts.realTops(), ['/media/me/My Disk']);
      final dir = SpecTrash.volumeTrash(root.path, 1000);
      expect(dir.path, p.join(root.path, '.Trash-1000'));
      expect(dir.top, root.path);
    });

    test('Android: the storage volume a path is on', () {
      expect(SpecTrash.androidVolumeOf('/storage/emulated/0/DCIM/a.jpg'), '/storage/emulated/0');
      expect(SpecTrash.androidVolumeOf('/storage/emulated/0'), '/storage/emulated/0');
      expect(SpecTrash.androidVolumeOf('/storage/1A2B-3C4D/Music/x.mp3'), '/storage/1A2B-3C4D');
      expect(SpecTrash.androidVolumeOf('/storage/emulated/10/x'), isNull);
      expect(SpecTrash.androidVolumeOf('/data/user/0/x'), isNull);
    });
  });

  group('the Recycle Bin', () {
    test(r'reads $I files of both versions', () {
      final path = r'C:\Users\me\Documents\report.pdf';
      final units = path.codeUnits;
      // Version 2: the length (with its null) before the path.
      final v2 = ByteData(28 + (units.length + 1) * 2)
        ..setInt64(0, 2, Endian.little)
        ..setInt64(8, 12345, Endian.little)
        // 2026-01-02 03:04:05 UTC as a FILETIME.
        ..setInt64(16, DateTime.utc(2026, 1, 2, 3, 4, 5).difference(DateTime.utc(1601)).inMicroseconds * 10,
            Endian.little)
        ..setUint32(24, units.length + 1, Endian.little);
      for (var i = 0; i < units.length; i++) {
        v2.setUint16(28 + i * 2, units[i], Endian.little);
      }
      final info = WindowsRecycleBin.parseInfo(v2.buffer.asUint8List())!;
      expect(info.path, path);
      expect(info.size, 12345);
      expect(info.deletedAt.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));

      // Version 1: a fixed 520-byte field.
      final v1 = ByteData(24 + 520)
        ..setInt64(0, 1, Endian.little)
        ..setInt64(8, 7, Endian.little);
      for (var i = 0; i < units.length; i++) {
        v1.setUint16(24 + i * 2, units[i], Endian.little);
      }
      expect(WindowsRecycleBin.parseInfo(v1.buffer.asUint8List())!.path, path);
      expect(WindowsRecycleBin.parseInfo(Uint8List(10)), isNull);
    });

    // The real Recycle Bin, with files this test made, and nothing else.
    test('sends to it, finds, restores and deletes for good what it sent', () async {
      final bin = WindowsRecycleBin();
      expect(bin.canTrash(r'\\server\share\a.txt'), isFalse);
      expect(bin.canTrash('/c/Users/a.txt'), isFalse, reason: 'not a full Windows path');
      final a = file('Folders trash test ${DateTime.now().microsecondsSinceEpoch}.txt', 'recycled');
      final folder = Directory(p.join(root.path, 'Folders trash test folder'))..createSync();
      File(p.join(folder.path, 'inside.txt')).writeAsStringSync('in');

      final result = await bin.moveToTrash([a.path, folder.path]);
      expect(result.failed, isEmpty, reason: '${result.failed}');
      expect(a.existsSync(), isFalse);
      expect(folder.existsSync(), isFalse);
      expect(result.trashed.map((i) => i.originalPath.toLowerCase()).toSet(),
          {a.path.toLowerCase(), folder.path.toLowerCase()});
      final file1 = result.trashed.firstWhere((i) => !i.isDirectory);
      expect(file1.name, p.basename(a.path));
      expect(p.basename(file1.storedPath), startsWith(r'$R'));
      expect(bin.contains(file1.storedPath), isTrue);
      expect((await bin.list()).any((i) => i.storedPath == file1.storedPath), isTrue);

      final back = await bin.restore(file1);
      expect(back.toLowerCase(), a.path.toLowerCase());
      expect(a.readAsStringSync(), 'recycled');

      final dir = result.trashed.firstWhere((i) => i.isDirectory);
      await bin.deleteForGood(dir);
      expect(Directory(dir.storedPath).existsSync(), isFalse);
      expect((await bin.list()).any((i) => i.storedPath == dir.storedPath), isFalse);
    }, skip: !Platform.isWindows);
  });
}
