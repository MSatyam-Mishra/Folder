import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/services/trash/spec_trash.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late Trash before;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('app_delete_test');
    before = Trash.instance;
    Trash.instance = SpecTrash.inFolder(p.join(root.path, 'trash'));
  });

  tearDown(() async {
    Trash.instance = before;
    await root.delete(recursive: true);
  });

  test("a tool's delete puts the item in the Trash, where it can be restored", () async {
    final folder = Directory(p.join(root.path, 'docs', 'Old photos'))..createSync(recursive: true);
    File(p.join(folder.path, 'a.jpg')).writeAsStringSync('jpg');

    await AppDelete.delete(folder.path);

    expect(folder.existsSync(), isFalse);
    final listed = await Trash.instance.list();
    expect(listed.map((i) => i.name), ['Old photos']);
    final back = await Trash.instance.restore(listed.single);
    expect(File(p.join(back, 'a.jpg')).readAsStringSync(), 'jpg');
  });
}
