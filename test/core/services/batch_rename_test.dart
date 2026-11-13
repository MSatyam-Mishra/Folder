import 'dart:io';

import 'package:folders/core/services/batch_rename.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final folder = p.join(Directory.systemTemp.path, 'batch');
  RenameSource file(String name, {DateTime? modified, bool dir = false}) =>
      RenameSource(p.join(folder, name), isDirectory: dir, modified: modified);

  List<String> names(List<RenameSource> sources, BatchRenameOptions o) =>
      [for (var i = 0; i < sources.length; i++) BatchRename.newName(sources[i], i, o)];

  group('new names', () {
    test('the pattern: name, extension, numbers and dates', () {
      final sources = [
        file('IMG_001.JPG', modified: DateTime(2026, 7, 4, 10)),
        file('IMG_002.jpg', modified: DateTime(2026, 7, 5)),
        file('Notes', dir: true, modified: DateTime(2025, 1, 2)),
      ];
      expect(names(sources, const BatchRenameOptions()), ['IMG_001.JPG', 'IMG_002.jpg', 'Notes']);
      expect(names(sources, const BatchRenameOptions(pattern: 'Holiday {n}', digits: 3)),
          ['Holiday 001.JPG', 'Holiday 002.jpg', 'Holiday 003']);
      expect(names(sources, const BatchRenameOptions(pattern: '{n:2} {name}', start: 10, step: 5)),
          ['10 IMG_001.JPG', '15 IMG_002.jpg', '20 Notes']);
      expect(names(sources, const BatchRenameOptions(pattern: '{date} {name}')),
          ['2026-07-04 IMG_001.JPG', '2026-07-05 IMG_002.jpg', '2025-01-02 Notes']);
      expect(names(sources, const BatchRenameOptions(pattern: '{date:yyyyMMdd}_{n}')),
          ['20260704_1.JPG', '20260705_2.jpg', '20250102_3']);
      // Without keeping extensions the pattern makes the whole name.
      expect(names(sources, const BatchRenameOptions(pattern: '{name}', keepExtension: false)),
          ['IMG_001.JPG', 'IMG_002.jpg', 'Notes']);
      expect(names(sources.take(2).toList(), const BatchRenameOptions(pattern: 'photo.{ext}', keepExtension: false)),
          ['photo.JPG', 'photo.jpg']);
      expect(names([file('.bashrc')], const BatchRenameOptions(pattern: '{name}-old')), ['.bashrc-old']);
      expect(names([file('a.txt')], const BatchRenameOptions(pattern: '{nope} {name}')), ['{nope} a.txt']);
    });

    test('find and replace: plain or regular expression, with or without case', () {
      final sources = [file('IMG_0042.jpg'), file('img_7.png')];
      expect(names(sources, const BatchRenameOptions(find: 'img_', replace: 'Photo ')),
          ['Photo 0042.jpg', 'Photo 7.png']);
      expect(names(sources, const BatchRenameOptions(find: 'img_', replace: 'Photo ', matchCase: true)),
          ['IMG_0042.jpg', 'Photo 7.png']);
      expect(names(sources, const BatchRenameOptions(find: r'^(\w+)_0*(\d+)$', replace: r'$2-$1', regex: true)),
          ['42-IMG.jpg', '7-img.png']);
      // The extension stays out of it unless it's part of the name.
      expect(names(sources, const BatchRenameOptions(find: 'jpg', replace: 'x')), ['IMG_0042.jpg', 'img_7.png']);
      expect(names(sources, const BatchRenameOptions(find: 'jpg', replace: 'jpeg', keepExtension: false)),
          ['IMG_0042.jpeg', 'img_7.png']);
      expect(() => BatchRename.newName(sources.first, 0, const BatchRenameOptions(find: '(', regex: true)),
          throwsFormatException);
    });

    test('case, then what goes before and after', () {
      final sources = [file('my holiday_PHOTO-01.JPG')];
      expect(names(sources, const BatchRenameOptions(nameCase: NameCase.lower)), ['my holiday_photo-01.JPG']);
      expect(names(sources, const BatchRenameOptions(nameCase: NameCase.upper)), ['MY HOLIDAY_PHOTO-01.JPG']);
      expect(names(sources, const BatchRenameOptions(nameCase: NameCase.title)), ['My Holiday_Photo-01.JPG']);
      expect(names(sources, const BatchRenameOptions(nameCase: NameCase.lower, prefix: 'A ', suffix: ' (B)')),
          ['A my holiday_photo-01 (B).JPG']);
      expect(BatchRename.titleCase('élan vital'), 'Élan Vital');
    });
  });

  group('checks', () {
    List<RenamePlan> plan(List<RenameSource> sources, BatchRenameOptions o,
            {Set<String> there = const {}, bool insensitive = true, bool windows = true}) =>
        BatchRename.plan(sources, o, namesIn: (_) => there, caseInsensitive: insensitive, windowsRules: windows);

    test('forbidden characters, reserved names, endings, empty names', () {
      final sources = [file('a.txt')];
      expect(plan(sources, const BatchRenameOptions(pattern: 'x:y')).single.problem, RenameProblem.forbidden);
      expect(plan(sources, const BatchRenameOptions(pattern: 'CON')).single.problem, RenameProblem.reserved);
      expect(plan(sources, const BatchRenameOptions(pattern: 'CON'), windows: false).single.problem, isNull);
      expect(plan(sources, const BatchRenameOptions(pattern: 'end. ', keepExtension: false)).single.problem,
          RenameProblem.forbidden);
      expect(plan(sources, const BatchRenameOptions(pattern: '', keepExtension: false)).single.problem,
          RenameProblem.empty);
      expect(plan(sources, BatchRenameOptions(pattern: 'x' * 300)).single.problem, RenameProblem.tooLong);
      expect(plan(sources, const BatchRenameOptions(find: '[', regex: true)).single.problem, RenameProblem.badPattern);
    });

    test('names given twice, and names taken by what stays', () {
      final sources = [file('a.txt'), file('b.txt'), file('c.txt')];
      final twice = plan(sources, const BatchRenameOptions(pattern: 'same'));
      expect(twice.map((p) => p.problem), everyElement(RenameProblem.duplicate));
      // "d.txt" is there and isn't being renamed.
      final taken = plan([file('a.txt')], const BatchRenameOptions(pattern: 'd'), there: {'a.txt', 'D.TXT'});
      expect(taken.single.problem, RenameProblem.exists);
      expect(plan([file('a.txt')], const BatchRenameOptions(pattern: 'd'), there: {'a.txt', 'D.TXT'}, insensitive: false)
          .single
          .problem, isNull);
      // b.txt keeps its name, so a.txt can't have it.
      final clash = plan([file('a.txt'), file('b.txt')], const BatchRenameOptions(find: 'a', replace: 'b'),
          there: {'a.txt', 'b.txt'});
      expect(clash.first.problem, RenameProblem.duplicate);
      // A swap: each name is freed by the other.
      final swap = plan([file('1.txt'), file('2.txt')], const BatchRenameOptions(pattern: '{n}', start: 2, step: -1),
          there: {'1.txt', '2.txt'});
      expect(swap.map((p) => p.newName), ['2.txt', '1.txt']);
      expect(swap.every((p) => p.ok), isTrue);
      // Only a change of case is fine.
      final upper = plan([file('a.txt')], const BatchRenameOptions(nameCase: NameCase.upper), there: {'a.txt'});
      expect(upper.single.problem, isNull);
      expect(upper.single.newName, 'A.txt');
      // Unchanged isn't a problem.
      expect(plan([file('a.txt')], const BatchRenameOptions(), there: {'a.txt'}).single.changed, isFalse);
    });
  });

  group('on disk', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('batch_rename_test'));
    tearDown(() async => root.delete(recursive: true));

    RenameSource real(String name, [String text = '']) {
      final f = File(p.join(root.path, name))..writeAsStringSync(text.isEmpty ? name : text);
      return RenameSource.of(f);
    }

    test('swaps names through temporary ones, then Undo puts them back', () async {
      final a = real('a.txt', 'A');
      final b = real('b.txt', 'B');
      final plans = [RenamePlan(a, 'b.txt'), RenamePlan(b, 'a.txt')];
      final result = await BatchRename.apply(plans);
      expect(result.failed, isEmpty);
      expect(result.done, hasLength(2));
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), 'B');
      expect(File(p.join(root.path, 'b.txt')).readAsStringSync(), 'A');
      expect(root.listSync().map((e) => p.basename(e.path)).toSet(), {'a.txt', 'b.txt'}, reason: 'no temporary names left');
      expect(BatchRename.last, same(result));

      await BatchRename.undo(result);
      expect(File(p.join(root.path, 'a.txt')).readAsStringSync(), 'A');
      expect(File(p.join(root.path, 'b.txt')).readAsStringSync(), 'B');
      expect(BatchRename.last, isNull);
    });

    test('renames folders and changes case; what fails keeps its name', () async {
      final dir = Directory(p.join(root.path, 'photos'))..createSync();
      final plans = BatchRename.plan(
        [RenameSource.of(dir), real('x.txt')],
        const BatchRenameOptions(nameCase: NameCase.upper),
      );
      expect(plans.every((p) => p.ok), isTrue);
      // Something takes the name before it's applied.
      final result = await BatchRename.apply([...plans, RenamePlan(real('gone.txt'), 'kept.txt')]
        ..add(RenamePlan(RenameSource(p.join(root.path, 'missing.txt')), 'other.txt')));
      expect(Directory(p.join(root.path, 'PHOTOS')).existsSync(), isTrue);
      expect(root.listSync().map((e) => p.basename(e.path)), containsAll(['PHOTOS', 'X.txt', 'kept.txt']));
      expect(result.failed.keys.single, endsWith('missing.txt'));
    });
  });
}
