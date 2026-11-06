import 'dart:io';

import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/features/file_explorere/bloc/folder_search.dart';
import 'package:folders/features/file_explorere/bloc/grouping.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('explorer_search_test');
  });

  tearDown(() => root.delete(recursive: true));

  Future<File> file(String relative, {int bytes = 1, DateTime? modified}) async {
    final f = File(p.joinAll([root.path, ...relative.split('/')]));
    await f.create(recursive: true);
    await f.writeAsBytes(List.filled(bytes, 0));
    if (modified != null) await f.setLastModified(modified);
    return f;
  }

  Future<FileStat?> stat(FileSystemEntity e) async => e.stat();
  Map<String, List<String>> named(List<EntityGroup> groups) => {
        for (final g in groups) g.label: [for (final e in g.entities) p.basename(e.path)],
      };

  group('groupEntities', () {
    // A Thursday.
    final now = DateTime(2026, 10, 22, 15);

    test('by date, as File Explorer does', () async {
      final entities = [
        await file('today.txt', modified: DateTime(2026, 10, 22, 9)),
        await file('yesterday.txt', modified: DateTime(2026, 10, 21, 9)),
        await file('monday.txt', modified: DateTime(2026, 10, 19, 9)),
        await file('last-week.txt', modified: DateTime(2026, 10, 14, 9)),
        await file('this-month.txt', modified: DateTime(2026, 10, 2, 9)),
        await file('last-month.txt', modified: DateTime(2026, 9, 10, 9)),
        await file('this-year.txt', modified: DateTime(2026, 2, 1, 9)),
        await file('old.txt', modified: DateTime(2019, 5, 1, 9)),
      ];
      final groups = await groupEntities(entities, GroupBy.date, stat: stat, now: now);
      expect(named(groups), {
        'Today': ['today.txt'],
        'Yesterday': ['yesterday.txt'],
        'Earlier this week': ['monday.txt'],
        'Last week': ['last-week.txt'],
        'Earlier this month': ['this-month.txt'],
        'Last month': ['last-month.txt'],
        'Earlier this year': ['this-year.txt'],
        'A long time ago': ['old.txt'],
      });
      expect(groups.map((g) => g.label).first, 'Today', reason: 'newest first');
    });

    test('by size, type and name; items keep their order', () async {
      final folder = await Directory(p.join(root.path, 'Music')).create();
      final entities = <FileSystemEntity>[
        folder,
        await file('empty.txt', bytes: 0),
        await file('b-small.jpg', bytes: 20 * 1024),
        await file('a-tiny.jpg', bytes: 100),
        await file('9 notes.md', bytes: 10),
      ];
      expect(named(await groupEntities(entities, GroupBy.size, stat: stat)), {
        'Folders': ['Music'],
        'Empty': ['empty.txt'],
        'Tiny (under 16 KB)': ['a-tiny.jpg', '9 notes.md'],
        'Small (16 KB – 1 MB)': ['b-small.jpg'],
      });
      final byType = await groupEntities(entities, GroupBy.type, stat: stat);
      expect(byType.first.label, 'Folder');
      expect(byType.firstWhere((g) => g.entities.length == 2).entities.map((e) => p.basename(e.path)),
          ['b-small.jpg', 'a-tiny.jpg']);
      expect(named(await groupEntities(entities, GroupBy.name, stat: stat)).keys,
          ['0–9', 'A', 'B', 'E', 'M']);
      expect(await groupEntities(entities, GroupBy.none, stat: stat), isEmpty);
    });
  });

  test('NameMatcher: anywhere in the name, or a * ? pattern', () {
    expect(NameMatcher('report').matches('Q3 Report final.pdf'), isTrue);
    expect(NameMatcher('report').matches('notes.txt'), isFalse);
    expect(NameMatcher('*.pdf').matches('Q3 Report.PDF'), isTrue);
    expect(NameMatcher('*.pdf').matches('report.pdf.txt'), isFalse);
    expect(NameMatcher('IMG_20??*').matches('IMG_2026_01.jpg'), isTrue);
    expect(NameMatcher('a+b (1)').matches('a+b (1).txt'), isTrue, reason: 'no regex in plain text');
  });

  test('searchSubfolders finds matches inside folders, nearest first', () async {
    await file('top-report.txt');
    await file('Work/report.pdf');
    await file('Work/2025/Q3/report-final.pdf');
    await file('Work/notes.txt');
    await file('.cache/report.tmp');
    final found = <String>[];
    await for (final batch in searchSubfolders(root.path, 'report')) {
      found.addAll(batch.map((e) => p.relative(e.path, from: root.path).replaceAll(r'\', '/')));
    }
    expect(found, ['Work/report.pdf', 'Work/2025/Q3/report-final.pdf'],
        reason: "the folder's own items and hidden ones aren't included");

    final withHidden = <String>[];
    await for (final batch in searchSubfolders(root.path, 'report', showHidden: true)) {
      withHidden.addAll(batch.map((e) => p.basename(e.path)));
    }
    expect(withHidden, contains('report.tmp'));
  });
}
