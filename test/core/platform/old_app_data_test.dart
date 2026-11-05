import 'dart:io';

import 'package:folder/core/platform/old_app_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The data of the app under its old name moves to the new name's folder, once,
/// and never over anything.
void main() {
  late Directory root;
  late Directory old;
  late Directory now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('old_app_data');
    old = Directory(p.join(root.path, 'Explorer'));
    now = Directory(p.join(root.path, 'Folder'));
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> oldData() async {
    await Directory(p.join(old.path, 'vault')).create(recursive: true);
    await File(p.join(old.path, 'vault', 'secret.bin')).writeAsString('kept');
    await File(p.join(old.path, 'shared_preferences.json')).writeAsString('{}');
  }

  test('everything moves into the new folder, empty as the system made it', () async {
    await oldData();
    await now.create();
    expect(await OldAppData.moveFolder(old, now), isTrue);
    expect(old.existsSync(), isFalse);
    expect(File(p.join(now.path, 'vault', 'secret.bin')).readAsStringSync(), 'kept');
    expect(File(p.join(now.path, 'shared_preferences.json')).existsSync(), isTrue);
  });

  test('also if the new folder is not there yet', () async {
    await oldData();
    expect(await OldAppData.moveFolder(old, now), isTrue);
    expect(File(p.join(now.path, 'vault', 'secret.bin')).existsSync(), isTrue);
  });

  test('a new folder with anything in it stays as it is, and so does the old', () async {
    await oldData();
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
}
