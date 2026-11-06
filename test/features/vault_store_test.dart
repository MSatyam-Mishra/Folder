import 'dart:io';

import 'package:folders/features/vault/vault_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late VaultStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_test');
    store = VaultStore(root: Directory(p.join(temp.path, 'vault')));
  });

  tearDown(() => temp.delete(recursive: true));

  File file(String name, String content) =>
      File(p.join(temp.path, 'docs', name))
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

  test('moves files in and lists them newest first', () async {
    final a = file('a.txt', 'first');
    final b = file('b.pdf', 'second');
    await store.add(a);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.add(b);

    expect(a.existsSync(), isFalse);
    expect(b.existsSync(), isFalse);
    final items = await store.list();
    expect(items.map((i) => i.name), ['b.pdf', 'a.txt']);
    expect(items.last.file.readAsStringSync(), 'first');
    expect(items.last.size, 5);
    expect(items.last.originalPath, a.path);
  });

  test('copies when asked to keep the original', () async {
    final a = file('a.txt', 'keep');
    await store.add(a, keepOriginal: true);
    expect(a.existsSync(), isTrue);
    expect((await store.list()).single.file.readAsStringSync(), 'keep');
  });

  test(
    'restores without overwriting, falling back when the folder is gone',
    () async {
      final a = file('a.txt', 'vaulted');
      final item = await store.add(a);
      file('a.txt', 'new file with the same name');

      final restored = await store.restore(item, fallbackDir: temp.path);
      expect(p.basename(restored), 'a (1).txt');
      expect(File(restored).readAsStringSync(), 'vaulted');
      expect(await store.list(), isEmpty);

      final b = file('b.txt', 'b');
      final itemB = await store.add(b);
      Directory(p.join(temp.path, 'docs')).deleteSync(recursive: true);
      final restoredB = await store.restore(itemB, fallbackDir: temp.path);
      expect(p.dirname(restoredB), temp.path);
    },
  );

  test('deletes for good', () async {
    final item = await store.add(file('a.txt', 'x'));
    await store.delete(item);
    expect(await store.list(), isEmpty);
    expect(item.file.existsSync(), isFalse);
  });
}
