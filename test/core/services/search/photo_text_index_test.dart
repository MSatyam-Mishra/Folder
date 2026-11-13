import 'dart:io';

import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The index of text read in photos, with a fake text reader.
void main() {
  late Directory root;
  late List<String> read;
  late Map<String, String?> texts;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('photo_index_test');
    read = [];
    texts = {};
  });
  tearDown(() => root.delete(recursive: true));

  PhotoTextIndex index({int maxEntries = 100}) => PhotoTextIndex(
        folder: () async => p.join(root.path, 'search'),
        ocr: (path) async {
          read.add(path);
          return texts[path];
        },
        maxEntries: maxEntries,
      );

  test('reads each photo once, keyed by path, size and date', () async {
    final photos = index();
    await photos.load();
    texts['/p/a.jpg'] = '  TOTAL\n\n 12.40  ';
    expect(await photos.read('/p/a.jpg', 100, 1), 'TOTAL 12.40');
    expect(await photos.read('/p/a.jpg', 100, 1), 'TOTAL 12.40');
    expect(read, ['/p/a.jpg']);
    expect(photos.known('/p/a.jpg', 100, 1), 'TOTAL 12.40');
    expect(photos.known('/p/a.jpg', 100, 2), isNull, reason: 'changed since');
    expect(photos.known('/p/a.jpg', 101, 1), isNull);
    texts['/p/a.jpg'] = 'TOTAL 15.00';
    expect(await photos.read('/p/a.jpg', 101, 1), 'TOTAL 15.00');
    expect(read, hasLength(2));
  });

  test('a photo without text is known to have none', () async {
    final photos = index();
    expect(await photos.read('/p/cat.jpg', 5, 5), '');
    expect(photos.known('/p/cat.jpg', 5, 5), '');
  });

  test('asked twice at once, reads once', () async {
    final photos = index();
    texts['/p/a.jpg'] = 'hello';
    final both = await Future.wait([photos.read('/p/a.jpg', 1, 1), photos.read('/p/a.jpg', 1, 1)]);
    expect(both, ['hello', 'hello']);
    expect(read, hasLength(1));
  });

  test('kept on disk and loaded again', () async {
    final photos = index();
    texts['/p/a.jpg'] = 'receipt';
    await photos.read('/p/a.jpg', 3, 4);
    await photos.save();
    final again = index();
    await again.load();
    expect(again.known('/p/a.jpg', 3, 4), 'receipt');
    expect(again.length, 1);
  });

  test('a damaged index starts again', () async {
    await Directory(p.join(root.path, 'search')).create(recursive: true);
    await File(p.join(root.path, 'search', 'photo_text.json')).writeAsString('{not json');
    final photos = index();
    await photos.load();
    expect(photos.length, 0);
  });

  test('the oldest go first past the cap', () async {
    final photos = index(maxEntries: 2);
    for (final name in ['a', 'b', 'c']) {
      await photos.read('/p/$name.jpg', 1, 1);
    }
    expect(photos.length, 2);
    expect(photos.known('/p/a.jpg', 1, 1), isNull);
    expect(photos.known('/p/c.jpg', 1, 1), '');
  });

  test('only pictures the system can read', () {
    expect(PhotoTextIndex.canRead('a/IMG_1.JPG'), isTrue);
    expect(PhotoTextIndex.canRead('a/scan.heic'), isTrue);
    expect(PhotoTextIndex.canRead('a/raw.dng'), isFalse);
    expect(PhotoTextIndex.canRead('a/anim.gif'), isFalse);
  });
}
