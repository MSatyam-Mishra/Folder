import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/toolbox/storage_scanner.dart';
import 'package:folders/features/toolbox/storage_treemap.dart';
import 'package:path/path.dart' as p;

/// The Storage analyzer's scan, its tree, and its map's layout.
void main() {
  late Directory root;

  String at(String path) => p.joinAll([root.path, ...path.split('/')]);

  void save(String path, int size) {
    final file = File(at(path));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(size, 7));
  }

  setUp(() => root = Directory.systemTemp.createTempSync('explorer_storage'));
  tearDown(() => root.deleteSync(recursive: true));

  StorageFolder folder(StorageFolder parent, String name) =>
      parent.children.whereType<StorageFolder>().firstWhere((f) => f.name == name);

  group('kinds', () {
    test('a file is known by its name', () {
      expect(StorageKind.ofName('Holiday.MP4'), StorageKind.videos);
      expect(StorageKind.ofName('IMG_0001.jpg'), StorageKind.photos);
      expect(StorageKind.ofName('DSC0001.NEF'), StorageKind.photos);
      expect(StorageKind.ofName('song.flac'), StorageKind.music);
      expect(StorageKind.ofName('report.pdf'), StorageKind.documents);
      expect(StorageKind.ofName('notes.txt'), StorageKind.documents);
      expect(StorageKind.ofName('setup.exe'), StorageKind.apps);
      expect(StorageKind.ofName('game.apk'), StorageKind.apps, reason: 'an app, though it is a ZIP');
      expect(StorageKind.ofName('backup.7z'), StorageKind.archives);
      expect(StorageKind.ofName('movie.7z.001'), StorageKind.archives);
      expect(StorageKind.ofName('disk.iso'), StorageKind.archives);
      expect(StorageKind.ofName('.gitignore'), StorageKind.other);
      expect(StorageKind.ofName('README'), StorageKind.other);
      expect(StorageKind.ofName('main.dart'), StorageKind.other);
    });
  });

  group('scanning', () {
    test('adds up every folder, by kind, rounded to whole clusters', () {
      save('Videos/trip.mp4', 300000);
      save('Videos/2025/old.mkv', 100000);
      save('Music/song.mp3', 5000);
      save('notes.txt', 10);
      save('empty.bin', 0);
      Directory(at('Nothing')).createSync();
      final cluster = StorageScanner.clusterSize(root.path);
      int disk(int size) => StorageScanner.roundUp(size, cluster);

      final result = StorageScanner(root.path).scan();
      final top = result.root;
      expect(top.files, 5);
      expect(top.folders, 4, reason: 'Videos, Videos/2025, Music and Nothing');
      expect(top.size, 300000 + 100000 + 5000 + 10);
      expect(top.disk, disk(300000) + disk(100000) + disk(5000) + disk(10));
      expect(top.kinds[StorageKind.videos.index], disk(300000) + disk(100000));
      expect(top.kinds[StorageKind.music.index], disk(5000));
      expect(top.kinds[StorageKind.documents.index], disk(10));
      expect(top.kinds.reduce((a, b) => a + b), top.disk, reason: 'every byte has a kind');

      expect([for (final child in top.children) child.name].take(3), ['Videos', 'Music', 'notes.txt'],
          reason: 'biggest first');
      final videos = folder(top, 'Videos');
      expect(videos.files, 2);
      expect(folder(videos, '2025').disk, disk(100000));
      expect(folder(top, 'Nothing').files, 0);
      expect(videos.path, at('Videos'));
      expect([for (final node in folder(videos, '2025').trail) node.name], [p.normalize(root.path), 'Videos', '2025']);
    });

    test('small files beyond the first few are only counted', () {
      for (var i = 0; i < StorageScanner.keepSmallFiles + 10; i++) {
        save('many/f$i.txt', 100 + i);
      }
      save('many/big.bin', StorageScanner.smallFile + 1);
      final many = folder(StorageScanner(root.path).scan().root, 'many');
      expect(many.files, StorageScanner.keepSmallFiles + 11);
      expect(many.children, hasLength(StorageScanner.keepSmallFiles + 1));
      expect(many.children.first.name, 'big.bin');
      expect(many.smallFiles, 10);
      final listed = many.children.fold<int>(0, (sum, child) => sum + child.disk);
      expect(listed + many.smallDisk, many.disk, reason: 'what is only counted still counts');
    });

    test('links and junctions are never followed', () {
      save('outside/huge.bin', 200000);
      save('inside/small.txt', 10);
      Link(at('inside/link')).createSync(at('outside'));
      final junction = Platform.isWindows &&
          Process.runSync('cmd', ['/c', 'mklink', '/J', at('inside/junction'), at('outside')]).exitCode == 0;
      final result = StorageScanner(at('inside')).scan();
      expect(result.root.files, 1);
      expect(result.root.size, 10);
      expect(result.links, junction ? 2 : 1);
    });

    test('the biggest files of a folder, however deep', () {
      save('a/one.bin', 5000);
      save('a/b/two.bin', 90000);
      save('a/b/c/three.bin', 40000);
      save('d/four.bin', 70000);
      final top = StorageScanner(root.path).scan().root;
      expect([for (final f in top.biggestFiles(3)) f.name], ['two.bin', 'four.bin', 'three.bin']);
      expect([for (final f in folder(top, 'a').biggestFiles(10)) f.name], ['two.bin', 'three.bin', 'one.bin']);
    });

    test('removing something shrinks every folder above it', () {
      save('a/b/movie.mp4', 90000);
      save('a/b/photo.jpg', 30000);
      save('a/keep.txt', 10);
      final top = StorageScanner(root.path).scan().root;
      final a = folder(top, 'a');
      final b = folder(a, 'b');
      final movie = b.children.firstWhere((n) => n.name == 'movie.mp4');
      final before = top.disk;
      StorageFolder.remove(movie);
      expect(top.disk, before - movie.disk);
      expect(a.files, 2);
      expect(top.kinds[StorageKind.videos.index], 0);
      expect(b.children.map((n) => n.name), ['photo.jpg']);
      StorageFolder.remove(b);
      expect(top.files, 1);
      expect(top.folders, 1);
      expect(top.kinds[StorageKind.photos.index], 0);
      expect(top.disk, a.disk);
    });

    test('several workers find what one does', () async {
      for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 8; j++) {
          for (var k = 0; k < 3; k++) {
            save('d$i/e$j/f$k/file.bin', 1000 * (i + 1) + 10 * j + k);
          }
          save('d$i/e$j/photo.jpg', 70000 + i);
        }
      }
      save('top.txt', 5);
      final one = StorageScanner(root.path).scan().root;
      final many = (await ParallelStorageScan(root.path, workers: 3).scan()).root;
      expect(many.files, one.files);
      expect(many.folders, one.folders);
      expect(many.disk, one.disk);
      expect(many.kinds, one.kinds);
      List<String> shape(StorageFolder f) => [
            for (final child in f.children)
              '${child.name}:${child.disk}${child is StorageFolder ? '(${shape(child).join(',')})' : ''}',
          ];
      expect(shape(many), shape(one));
      final deep = folder(folder(folder(many, 'd5'), 'e7'), 'f2');
      expect(deep.parent!.parent!.parent, same(many), reason: 'what workers found is part of the tree');
    });

    test('a scan runs in the background, tells how far it has come and stops at once', () async {
      for (var i = 0; i < 40; i++) {
        save('x$i/y/z.bin', 3000);
      }
      final progress = <StorageScanProgress>[];
      final result = await StorageScan(root.path, onProgress: progress.add, workers: 2).start();
      expect(result, isNotNull);
      expect(result!.root.files, 40);
      expect(result.root.folders, 80);

      final stopped = StorageScan(root.path);
      final pending = stopped.start();
      stopped.stop();
      expect(await pending, isNull);
    });

    test('Stop leaves no folder open: the tree can go at once', () async {
      for (var i = 0; i < 400; i++) {
        save('big/d$i/e/f.bin', 10);
      }
      final started = Completer<void>();
      final scan = StorageScan(at('big'), workers: 3, onProgress: (_) {
        if (!started.isCompleted) started.complete();
      });
      final pending = scan.start();
      await started.future;
      scan.stop();
      expect(await pending, isNull);
      Object? failure;
      for (var i = 0; i < 40; i++) {
        try {
          Directory(at('big')).deleteSync(recursive: true);
          failure = null;
          break;
        } on FileSystemException catch (error) {
          failure = error;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(failure, isNull, reason: 'a folder still held open');
    });
  });

  group('drives', () {
    test("df's output gives a drive's size", () {
      const output = 'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
          '/dev/nvme0n1p2   490617784 211234567 254383217      46% /\n';
      final space = StorageSpace.parseDf(output)!;
      expect(space.total, 490617784 * 1024);
      expect(space.free, 254383217 * 1024);
      expect(StorageSpace.parseDf('nonsense'), isNull);
    });

    test('mount points are read as /proc writes them', () {
      expect(StorageScanner.decodeMountPath(r'/media/me/My\040Disk'), '/media/me/My Disk');
    });

    test("this PC's drive tells its size", () async {
      final space = await StorageSpace.of(root.path);
      expect(space, isNotNull);
      expect(space!.total, greaterThan(space.free));
    });
  });

  group('map', () {
    test('squarified rectangles fill the area in proportion, without overlaps', () {
      final values = <double>[60, 30, 20, 10, 6, 4, 2, 1];
      const area = Rect.fromLTWH(10, 20, 600, 400);
      final rects = squarify(values, area);
      final total = values.reduce((a, b) => a + b);
      for (var i = 0; i < values.length; i++) {
        final rect = rects[i];
        expect(rect.width * rect.height, closeTo(area.width * area.height * values[i] / total, 1));
        expect(area.inflate(0.01).contains(rect.topLeft) && area.inflate(0.01).contains(rect.bottomRight), isTrue);
        for (var j = i + 1; j < values.length; j++) {
          final overlap = rect.intersect(rects[j]);
          expect(overlap.width <= 0.01 || overlap.height <= 0.01, isTrue, reason: '$i and $j overlap');
        }
      }
      final covered = rects.fold<double>(0, (sum, r) => sum + r.width * r.height);
      expect(covered, closeTo(area.width * area.height, 1));
      // Close to squares: nothing as thin as a slice-and-dice layout makes.
      for (final rect in rects.take(4)) {
        expect(rect.longestSide / rect.shortestSide, lessThan(3.5));
      }
    });

    test('nothing to lay out gives nothing', () {
      expect(squarify([], const Rect.fromLTWH(0, 0, 10, 10)), isEmpty);
      expect(squarify([1, 2], Rect.zero), everyElement(Rect.zero));
    });

    test('a folder maps to tiles for what it holds, and inside its folders', () {
      save('Videos/trip.mp4', 400000);
      save('Videos/clip.mp4', 200000);
      save('song.mp3', 150000);
      for (var i = 0; i < 30; i++) {
        save('small/f$i.txt', 50 + i);
      }
      final top = StorageScanner(root.path).scan().root;
      final tiles = layoutTreemap(top, const Size(800, 600), brightness: Brightness.light);
      final top0 = tiles.where((t) => t.depth == 0).toList();
      expect(top0.map((t) => t.node?.name), containsAll(['Videos', 'song.mp3', 'small']));
      final inside = tiles.where((t) => t.depth == 1 && t.owner.name == 'Videos').map((t) => t.node?.name);
      expect(inside, containsAll(['trip.mp4', 'clip.mp4']));
      final videos = top0.firstWhere((t) => t.node?.name == 'Videos');
      final song = top0.firstWhere((t) => t.node?.name == 'song.mp3');
      expect(videos.rect.width * videos.rect.height, greaterThan(song.rect.width * song.rect.height * 3));
      expect(song.color, StorageColors.of(StorageKind.music, Brightness.light));
      // The small files beyond those listed one by one share a tile.
      expect(tiles.where((t) => t.node == null && t.owner.name == 'small'), hasLength(1));
      final trip = tiles.firstWhere((t) => t.node?.name == 'trip.mp4');
      expect(trip.topIn(top)?.name, 'Videos');
    });
  });
}
