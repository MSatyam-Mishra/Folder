import 'dart:io';

import 'package:folders/core/platform/old_app_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The data of the app under an old name moves to the new name's folder, once,
/// and never over anything.
void main() {
  late Directory root;
  late Directory old;
  late Directory older;
  late Directory now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('old_app_data');
    old = Directory(p.join(root.path, 'Folder'));
    older = Directory(p.join(root.path, 'Explorer'));
    now = Directory(p.join(root.path, 'Folders'));
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> dataIn(Directory dir, [String secret = 'kept']) async {
    await Directory(p.join(dir.path, 'vault')).create(recursive: true);
    await File(p.join(dir.path, 'vault', 'secret.bin')).writeAsString(secret);
    await File(p.join(dir.path, 'shared_preferences.json')).writeAsString('{}');
  }

  test('everything moves into the new folder, empty as the system made it', () async {
    await dataIn(old);
    await now.create();
    expect(await OldAppData.moveFolder(old, now), isTrue);
    expect(old.existsSync(), isFalse);
    expect(File(p.join(now.path, 'vault', 'secret.bin')).readAsStringSync(), 'kept');
    expect(File(p.join(now.path, 'shared_preferences.json')).existsSync(), isTrue);
  });

  test('also if the new folder is not there yet', () async {
    await dataIn(old);
    expect(await OldAppData.moveFolder(old, now), isTrue);
    expect(File(p.join(now.path, 'vault', 'secret.bin')).existsSync(), isTrue);
  });

  test('a new folder with anything in it stays as it is, and so does the old', () async {
    await dataIn(old);
    await now.create();
    await File(p.join(now.path, 'shared_preferences.json')).writeAsString('newer');
    expect(await OldAppData.moveFolder(old, now), isFalse);
    expect(File(p.join(now.path, 'shared_preferences.json')).readAsStringSync(), 'newer');
    expect(File(p.join(old.path, 'vault', 'secret.bin')).existsSync(), isTrue);
  });

  test('with no old folder nothing happens', () async {
    await now.create();
    expect(await OldAppData.moveFolder(old, now), isFalse);
    expect(now.existsSync(), isTrue);
  });

  group('two old names', () {
    test("Folder's data wins over Explorer's, which stays where it is", () async {
      await dataIn(old, 'from Folder');
      await dataIn(older, 'from Explorer');
      expect(await OldAppData.moveNewestFolder([old, older], now), isTrue);
      expect(File(p.join(now.path, 'vault', 'secret.bin')).readAsStringSync(), 'from Folder');
      expect(older.existsSync(), isTrue);
    });

    test("without Folder's, Explorer's moves", () async {
      await dataIn(older, 'from Explorer');
      expect(await OldAppData.moveNewestFolder([old, older], now), isTrue);
      expect(File(p.join(now.path, 'vault', 'secret.bin')).readAsStringSync(), 'from Explorer');
    });

    test('the newest name comes first on every computer', () {
      final names = OldAppData.oldNames;
      if (Platform.isWindows) expect(names, ['Folder', 'Explorer']);
      if (Platform.isLinux || Platform.isMacOS) expect(names, ['com.synqixlabs.folder', 'com.synqixlabs.explory']);
    });
  });
}
