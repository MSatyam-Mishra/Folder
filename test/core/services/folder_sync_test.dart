import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/services/toolbox/folder_compare.dart';
import 'package:folders/core/services/toolbox/folder_listing.dart';
import 'package:folders/core/services/toolbox/folder_sync.dart';
import 'package:folders/core/services/toolbox/sync_pairs.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Folder sync: comparing two folders, what each mode plans, carrying it out,
/// and saved pairs.
void main() {
  late Directory root;
  final base = DateTime(2026, 6, 1, 12);
  final deleted = <String>[];

  String at(String path) => p.joinAll([root.path, ...path.split('/')]);
  String left(String path) => at('left/$path');
  String right(String path) => at('right/$path');

  File save(String path, String text, {Duration age = Duration.zero}) {
    final file = File(at(path))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
    file.setLastModifiedSync(base.subtract(age));
    return file;
  }

  String read(String path) => File(at(path)).readAsStringSync();
  bool exists(String path) => FileSystemEntity.typeSync(at(path), followLinks: false) != FileSystemEntityType.notFound;

  FolderComparison compare({CompareOptions options = const CompareOptions()}) =>
      FolderComparer.compare(at('left'), at('right'), options: options);

  setUp(() {
    root = Directory.systemTemp.createTempSync('explorer_sync');
    Directory(at('left')).createSync();
    Directory(at('right')).createSync();
    deleted.clear();
    AppDelete.override = (path) async {
      deleted.add(p.relative(path, from: root.path).replaceAll(r'\', '/'));
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        Directory(path).deleteSync(recursive: true);
      } else {
        File(path).deleteSync();
      }
    };
  });
  tearDown(() {
    AppDelete.override = null;
    BackgroundTasks.instance.reset();
    root.deleteSync(recursive: true);
  });

  group('comparing', () {
    test('sorts every difference into its group, and counts what is the same', () {
      save('left/same.txt', 'same');
      save('right/same.txt', 'same');
      save('left/only left.txt', 'L');
      save('right/only right.txt', 'R');
      save('left/newer left.txt', 'new', age: Duration.zero);
      save('right/newer left.txt', 'old', age: const Duration(days: 1));
      save('left/newer right.txt', 'old', age: const Duration(days: 1));
      save('right/newer right.txt', 'newer');
      save('left/size.txt', 'short');
      save('right/size.txt', 'much longer');
      save('left/clash', 'a file');
      save('right/clash/inside.txt', 'a folder');
      save('left/deep/a/b.txt', 'deep');
      save('right/deep/a/b.txt', 'deep');
      save('left/new folder/one.txt', '1');
      save('left/new folder/sub/two.txt', '22');

      final comparison = compare();
      expect(diffsByPath(comparison), {
        'new folder': SyncDiff.onlyLeft,
        'only left.txt': SyncDiff.onlyLeft,
        'only right.txt': SyncDiff.onlyRight,
        'newer left.txt': SyncDiff.newerLeft,
        'newer right.txt': SyncDiff.newerRight,
        'size.txt': SyncDiff.differentSize,
        'clash': SyncDiff.typeClash,
      });
      expect(comparison.identical, 2, reason: 'same.txt and deep/a/b.txt');
      expect(comparison.identicalBytes, 'same'.length + 'deep'.length);
      final folder = comparison.items.firstWhere((item) => item.path == 'new folder');
      expect(folder.left!.isFolder, isTrue);
      expect(folder.left!.files, 2, reason: 'a folder on one side is one item with all it holds');
      expect(folder.left!.size, 3);
      expect(comparison.leftFiles, 9);
      expect(comparison.items.first.diff, SyncDiff.onlyLeft, reason: 'in the order of the groups');
    });

    test('times 2 seconds apart are the same; an hour apart only when asked', () {
      save('left/fat.txt', 'x');
      save('right/fat.txt', 'x');
      File(right('fat.txt')).setLastModifiedSync(base.add(const Duration(milliseconds: 1999)));
      save('left/dst.txt', 'y');
      save('right/dst.txt', 'y');
      File(right('dst.txt')).setLastModifiedSync(base.add(const Duration(hours: 1, seconds: 1)));

      expect(diffsByPath(compare()), {'dst.txt': SyncDiff.newerRight});
      expect(diffsByPath(compare(options: const CompareOptions(ignoreHourShift: true))), isEmpty);
      expect(FolderComparer.compareTimes(0, 2001), -1);
      expect(FolderComparer.compareTimes(5000, 3000), 0);
    });

    test('contents are read only when asked, and only where the size matches', () {
      save('left/hidden change.txt', 'abcd');
      save('right/hidden change.txt', 'abce');
      save('left/touched.txt', 'same');
      save('right/touched.txt', 'same', age: const Duration(days: 2));
      final big = List.generate(3 << 20, (i) => i % 251);
      File(left('big.bin')).writeAsBytesSync(big);
      File(right('big.bin')).writeAsBytesSync([...big]..[big.length - 1] = 7);
      File(left('big.bin')).setLastModifiedSync(base);
      File(right('big.bin')).setLastModifiedSync(base);

      expect(diffsByPath(compare()), {'touched.txt': SyncDiff.newerLeft});
      final progress = <CompareProgress>[];
      final read = FolderComparer.compare(
        at('left'),
        at('right'),
        options: const CompareOptions(contents: true),
        report: progress.add,
      );
      expect(diffsByPath(read), {
        'big.bin': SyncDiff.differentContents,
        'hidden change.txt': SyncDiff.differentContents,
      }, reason: 'touched.txt holds the same bytes, so only its date differs');
      expect(read.identical, 1);
      expect(progress.last.phase, ComparePhase.contents);
      expect(progress.last.bytesTotal, 4 + 4 + big.length);
      expect(FolderComparer.sameContents(left('touched.txt'), right('touched.txt')), isTrue);
    });

    test('names that differ only in case are one file where the system says so', () {
      save('left/Photo.JPG', 'p');
      save('right/photo.jpg', 'p');
      expect(diffsByPath(compare()), Platform.isLinux ? hasLength(2) : isEmpty);
    });

    test('links and junctions are neither followed nor compared', () {
      save('outside/secret.txt', 'outside');
      save('left/real.txt', 'r');
      save('right/real.txt', 'r');
      var made = 0;
      try {
        Link(left('link')).createSync(at('outside'));
        made++;
        Link(right('file link')).createSync(at('outside/secret.txt'));
        made++;
      } on FileSystemException {
        // No right to make links here.
      }
      if (Platform.isWindows &&
          Process.runSync('cmd', ['/c', 'mklink', '/J', right('junction'), at('outside')]).exitCode == 0) {
        made++;
      }
      if (made == 0) {
        markTestSkipped("can't make links here");
        return;
      }
      final comparison = compare();
      expect(comparison.items, isEmpty, reason: 'nothing past a link counts');
      expect(comparison.skippedLinks, made);
      expect(comparison.rightFiles, 1);
    });

    test('the quick listing gives what asking each file would, past 260 characters too', () {
      save('left/a.txt', 'hello');
      save('left/sub/b.txt', 'b');
      final deep = [for (var i = 0; i < 12; i++) 'a folder with a long name $i'].join('/');
      save('left/$deep/far.txt', 'far away');
      expect(left(deep).length, greaterThan(260));
      final listed = {for (final entry in FolderListing.list(at('left'))!) entry.name: entry};
      expect(listed.keys, unorderedEquals(['a.txt', 'sub', 'a folder with a long name 0']));
      expect(listed['a.txt']!.kind, EntryKind.file);
      expect(listed['a.txt']!.size, 5);
      expect(
        (listed['a.txt']!.modified - File(left('a.txt')).lastModifiedSync().millisecondsSinceEpoch).abs(),
        lessThan(1000),
      );
      expect(listed['sub']!.kind, EntryKind.folder);
      final far = FolderListing.list(left(deep))!.single;
      expect((far.name, far.size), ('far.txt', 8));
      expect(FolderListing.list(at('nowhere')), isNull);
      expect(diffsByPath(compare()), {'a.txt': SyncDiff.onlyLeft, 'sub': SyncDiff.onlyLeft, 'a folder with a long name 0': SyncDiff.onlyLeft});
      expect(compare().leftFiles, 3);
    });

    test('says why two folders cannot be compared', () {
      expect(FolderComparer.problem(null, at('right')), 'Choose both folders');
      expect(FolderComparer.problem(at('left'), at('left')), 'These are the same folder');
      Directory(left('inner')).createSync();
      expect(FolderComparer.problem(at('left'), left('inner')), 'One folder is inside the other');
      expect(FolderComparer.problem('explorer://remote/abc/photos', at('right')), 'Only folders on this device can be synced');
      expect(FolderComparer.problem('explorer://category/Video', at('right')), 'Only folders on this device can be synced');
      expect(FolderComparer.problem(at('left'), at('gone')), contains('not there'));
      expect(FolderComparer.problem(at('left'), at('right')), isNull);
    });

    test('a comparison runs in the background, tells how far it has come and stops at once', () async {
      for (var i = 0; i < 50; i++) {
        save('left/f$i.txt', '$i');
      }
      final heard = <CompareProgress>[];
      final done = await FolderCompare(at('left'), at('right'), onProgress: heard.add).start();
      expect(done!.items, hasLength(50));
      expect(heard, isNotEmpty);

      final stopped = FolderCompare(at('left'), at('right'));
      final result = stopped.start();
      stopped.stop();
      expect(await result, isNull);
    });
  });

  group('planning', () {
    late FolderComparison comparison;

    setUp(() {
      save('left/only left.txt', 'L');
      save('right/only right.txt', 'R');
      save('left/newer left.txt', 'new');
      save('right/newer left.txt', 'old', age: const Duration(days: 1));
      save('left/newer right.txt', 'old', age: const Duration(days: 1));
      save('right/newer right.txt', 'newer');
      save('left/size.txt', 'short');
      save('right/size.txt', 'much longer');
      save('left/clash', 'a file');
      save('right/clash/inside.txt', 'a folder');
      comparison = compare();
    });

    Map<String, List<String>> actions(SyncPlan plan) {
      final byKind = <String, List<String>>{};
      for (final action in plan.actions) {
        (byKind[action.kind.name] ??= []).add(action.item.path);
      }
      return byKind;
    }

    test('copy takes what is new or newer on the left, and never deletes', () {
      final plan = SyncPlanner.plan(comparison, SyncMode.copy);
      expect(actions(plan), {
        'copyRight': ['only left.txt'],
        'replaceRight': ['newer left.txt'],
      });
      expect(plan.deletes, 0);
      expect([for (final item in plan.untouched) item.path]..sort(), ['clash', 'newer right.txt', 'only right.txt', 'size.txt']);
    });

    test('mirror makes the right a copy of the left: replaces, and deletes extras', () {
      final plan = SyncPlanner.plan(comparison, SyncMode.mirror);
      expect(actions(plan), {
        'deleteRight': ['clash', 'only right.txt'],
        'copyRight': ['only left.txt', 'clash'],
        'replaceRight': ['newer left.txt', 'newer right.txt', 'size.txt'],
      });
      expect(plan.actions.first.kind, SyncActionKind.deleteRight, reason: 'the folder in the way goes first');
      expect(plan.actions.first.item.path, 'clash');
      expect(plan.actions.last.item.path, 'only right.txt', reason: 'extras go last, after the copies');
      expect(plan.deletes, 2);
      expect(plan.deleteBytes, 'a folder'.length + 'R'.length);
    });

    test('two-way: newer wins both ways, and conflicts wait for a choice', () {
      var plan = SyncPlanner.plan(comparison, SyncMode.twoWay);
      expect(actions(plan), {
        'copyRight': ['only left.txt'],
        'copyLeft': ['only right.txt'],
        'replaceRight': ['newer left.txt'],
        'replaceLeft': ['newer right.txt'],
      });
      expect({for (final c in plan.conflicts) c.item.path: c.reason}, {
        'clash': ConflictReason.typeClash,
        'size.txt': ConflictReason.sameDate,
      });
      expect(plan.skippedConflicts, 2);
      expect(plan.deletes, 0);

      plan = SyncPlanner.plan(comparison, SyncMode.twoWay, choices: {
        'size.txt': ConflictChoice.right,
        'clash': ConflictChoice.left,
      });
      expect(actions(plan)['replaceLeft'], ['newer right.txt', 'size.txt']);
      expect(actions(plan)['deleteRight'], ['clash']);
      expect(actions(plan)['copyRight'], ['only left.txt', 'clash']);
      expect(plan.skippedConflicts, 0);
    });

    test('two-way: a file changed on both sides since the last sync is a conflict', () {
      final plan = SyncPlanner.plan(comparison, SyncMode.twoWay, lastSync: base.subtract(const Duration(hours: 1)));
      expect({for (final c in plan.conflicts) c.item.path: c.reason}, {
        'clash': ConflictReason.typeClash,
        'size.txt': ConflictReason.sameDate,
      }, reason: 'the newer files changed on one side only');

      final both = SyncPlanner.plan(comparison, SyncMode.twoWay, lastSync: base.subtract(const Duration(days: 3)));
      expect(both.conflicts.where((c) => c.reason == ConflictReason.bothChanged).map((c) => c.item.path).toList()..sort(),
          ['newer left.txt', 'newer right.txt']);
    });
  });

  group('syncing', () {
    test('mirror copies, replaces and deletes, through the browser\'s delete, and keeps dates', () async {
      save('left/only left.txt', 'L', age: const Duration(days: 5));
      save('left/folder/a.txt', 'a');
      save('left/folder/sub/b.txt', 'bb', age: const Duration(days: 9));
      save('right/only right.txt', 'R');
      save('left/newer left.txt', 'new');
      save('right/newer left.txt', 'old', age: const Duration(days: 1));
      save('left/clash', 'a file');
      save('right/clash/inside.txt', 'a folder');

      final plan = SyncPlanner.plan(compare(), SyncMode.mirror);
      final heard = <SyncProgress>[];
      final outcome = await FolderSyncRunner(plan, onProgress: heard.add).run();
      expect(outcome.failures, isEmpty);
      expect(outcome.cancelled, isFalse);
      expect(outcome.copied, 3);
      expect(outcome.replaced, 1);
      expect(outcome.deleted, 2);
      expect(read('right/only left.txt'), 'L');
      expect(read('right/folder/sub/b.txt'), 'bb');
      expect(read('right/newer left.txt'), 'new');
      expect(read('right/clash'), 'a file');
      expect(exists('right/only right.txt'), isFalse);
      expect(deleted, unorderedEquals(['right/clash', 'right/newer left.txt', 'right/only right.txt']),
          reason: 'the older copy a replace takes the place of goes the same way');
      expect(File(right('only left.txt')).lastModifiedSync(), base.subtract(const Duration(days: 5)));
      expect(File(right('folder/sub/b.txt')).lastModifiedSync(), base.subtract(const Duration(days: 9)));
      expect(heard.last.fraction, 1);
      expect(compare().matches, isTrue, reason: 'the two folders match now');
      expect(Directory(at('right')).listSync(recursive: true).where((e) => e.path.endsWith('.tmp')), isEmpty);
    });

    test('two-way copies both ways', () async {
      save('left/a.txt', 'a');
      save('right/b.txt', 'b');
      save('left/c.txt', 'old', age: const Duration(days: 1));
      save('right/c.txt', 'new!');
      final outcome = await FolderSyncRunner(SyncPlanner.plan(compare(), SyncMode.twoWay)).run();
      expect(outcome.summary, '2 copied, 1 replaced');
      expect(read('left/b.txt'), 'b');
      expect(read('right/a.txt'), 'a');
      expect(read('left/c.txt'), 'new!');
      expect(compare().matches, isTrue);
    });

    test('a file changed since the comparison is left alone', () async {
      save('left/x.txt', 'new');
      save('right/x.txt', 'old', age: const Duration(days: 1));
      save('right/extra.txt', 'extra');
      final plan = SyncPlanner.plan(compare(), SyncMode.mirror);
      save('right/x.txt', 'edited meanwhile', age: const Duration(hours: 1));
      save('right/extra.txt', 'edited too!');
      final outcome = await FolderSyncRunner(plan).run();
      expect(outcome.failures.map((f) => f.path), ['x.txt', 'extra.txt']);
      expect(outcome.failures.first.reason, contains('compare again'));
      expect(read('right/x.txt'), 'edited meanwhile');
      expect(read('right/extra.txt'), 'edited too!');
      expect(deleted, isEmpty);
    });

    test('Cancel stops in the middle of a file and leaves no part of it', () async {
      final big = List.generate(8 << 20, (i) => i % 256);
      File(left('big.bin')).writeAsBytesSync(big);
      save('left/later.txt', 'later');
      save('right/big.bin', 'the old copy', age: const Duration(days: 1));
      save('right/later.txt', 'old', age: const Duration(days: 1));
      final plan = SyncPlanner.plan(compare(), SyncMode.copy);
      expect(plan.actions.first.kind, SyncActionKind.replaceRight);
      expect(plan.actions.first.item.path, 'big.bin');
      late FolderSyncRunner runner;
      runner = FolderSyncRunner(plan, tellEvery: Duration.zero, onProgress: (progress) {
        if (progress.doneBytes > 0) runner.cancel();
      });
      final outcome = await runner.run();
      expect(outcome.cancelled, isTrue);
      expect(outcome.copied + outcome.replaced, 0);
      expect(read('right/big.bin'), 'the old copy', reason: 'the old copy stays');
      expect(read('right/later.txt'), 'old');
      expect(Directory(at('right')).listSync().map((e) => p.basename(e.path)).toList()..sort(), ['big.bin', 'later.txt'],
          reason: 'no temporary file is left behind');
    });

    test('a folder copy cancelled half way leaves nothing', () async {
      for (var i = 0; i < 20; i++) {
        File(left('album/$i.bin'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(List.filled(1 << 20, i));
      }
      final plan = SyncPlanner.plan(compare(), SyncMode.copy);
      late FolderSyncRunner runner;
      runner = FolderSyncRunner(plan, tellEvery: Duration.zero, onProgress: (progress) {
        if (progress.doneBytes > 5 << 20) runner.cancel();
      });
      final outcome = await runner.run();
      expect(outcome.cancelled, isTrue);
      expect(Directory(at('right')).listSync(), isEmpty);
    });

    test('a sync is a background task that can be cancelled, and tells its saved pair', () async {
      SharedPreferences.setMockInitialValues({});
      save('left/a.txt', 'a');
      save('right/b.txt', 'b');
      final pair = SyncPair(id: SyncPairs.newId(), name: 'Test', left: at('left'), right: at('right'));
      await SyncPairs.put(pair);
      final job = SyncJob.start(SyncPlanner.plan(compare(), SyncMode.mirror), pairId: pair.id);
      expect(SyncJob.running, job);
      expect(job.task.headline, 'Sync in progress');
      expect(job.task.kind, TaskKind.copy);
      expect(job.task.canCancel, isTrue);
      final outcome = await job.outcome;
      expect(outcome.summary, '1 copied, 1 deleted');
      expect(job.task.status, TaskStatus.done);
      expect(job.task.message, '1 copied, 1 deleted');
      expect(SyncJob.running, isNull);
      final saved = (await SyncPairs.load()).single;
      expect(saved.lastSummary, '1 copied, 1 deleted');
      expect(saved.lastSync, isNotNull);
      expect(saved.lastRun, saved.lastSync);
    });
  });

  group('saved pairs', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('are saved, renamed, run and removed', () async {
      expect(await SyncPairs.load(), isEmpty);
      final first = SyncPair(
        id: 'a',
        name: SyncPair.defaultName(at('Photos'), at('Backup')),
        left: at('Photos'),
        right: at('Backup'),
        mode: SyncMode.mirror,
        options: const CompareOptions(contents: true, ignoreHourShift: true),
      );
      await SyncPairs.put(first);
      await SyncPairs.put(SyncPair(id: 'b', name: 'Music', left: at('m'), right: at('n'), mode: SyncMode.twoWay));
      var pairs = await SyncPairs.load();
      expect(pairs.map((pair) => pair.id), ['b', 'a'], reason: 'newest first');
      expect(pairs.last.name, 'Photos → Backup');
      expect(pairs.last.mode, SyncMode.mirror);
      expect(pairs.last.options.contents, isTrue);
      expect(pairs.last.options.ignoreHourShift, isTrue);

      await SyncPairs.rename('a', 'Camera');
      final at0 = DateTime(2026, 10, 1);
      await SyncPairs.recordRun('a', at: at0, summary: '3 copied', complete: false);
      pairs = await SyncPairs.load();
      expect(pairs.last.name, 'Camera');
      expect(pairs.last.lastRun, at0);
      expect(pairs.last.lastSummary, '3 copied');
      expect(pairs.last.lastSync, isNull, reason: 'it did not go to the end');

      await SyncPairs.remove('b');
      expect((await SyncPairs.load()).map((pair) => pair.id), ['a']);
    });

    test('a broken entry is left out', () async {
      SharedPreferences.setMockInitialValues({SyncPairs.key: '[{"id": 1}, {"id": "x", "left": "a", "right": "b"}]'});
      final pairs = await SyncPairs.load();
      expect(pairs.single.id, 'x');
      expect(pairs.single.mode, SyncMode.copy);
      SharedPreferences.setMockInitialValues({SyncPairs.key: 'not json'});
      expect(await SyncPairs.load(), isEmpty);
    });
  });
}
