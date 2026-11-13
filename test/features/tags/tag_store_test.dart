import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/formats/finder_tags_plist.dart';
import 'package:folders/core/platform/system_tags.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/services/path_changes.dart';
import 'package:folders/features/clipboard/paste_task.dart';
import 'package:folders/features/tags/tag_color.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:path/path.dart' as p;

/// Records what would be written beside files for Finder or Dolphin.
class _FakeSystemTags extends SystemTags {
  final written = <String, List<FinderTag>>{};
  final onDisk = <String, List<FinderTag>>{};

  @override
  List<FinderTag>? read(String path) => onDisk[path];

  @override
  bool write(String path, List<FinderTag> tags) {
    written[path] = tags;
    return true;
  }
}

void main() {
  late Directory root;
  late String file;
  final stores = <TagStore>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tag_store_test');
    file = p.join(root.path, 'support', 'tags', 'tags.json');
  });

  tearDown(() async {
    for (final s in stores) {
      s.close();
    }
    stores.clear();
    await root.delete(recursive: true);
  });

  Future<TagStore> open({SystemTags? system, bool? caseSensitive}) async {
    final store = TagStore(file: file, systemTags: system, caseSensitive: caseSensitive);
    stores.add(store);
    await store.ensureLoaded();
    return store;
  }

  String make(String relative, {bool folder = false}) {
    final path = p.joinAll([root.path, ...relative.split('/')]);
    if (folder) {
      Directory(path).createSync(recursive: true);
    } else {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(relative);
    }
    return path;
  }

  List<String> names(TagStore store, String path) => [for (final t in store.tagsOf(path)) t.name];

  test("Finder's colours come first, and nothing is saved until something changes", () async {
    final store = await open();
    expect(store.tags.map((t) => t.name), ['Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple', 'Grey']);
    expect(store.tags.first.color, TagColor.red);
    expect(File(file).existsSync(), isFalse);
  });

  test('tags are put on and taken off, and kept for the next start', () async {
    final a = make('a.txt'), b = make('b.txt');
    final store = await open();
    store.setTag([a, b], 'Red', on: true);
    store.setTag([a], 'Work', on: true); // A new tag is made on the way.
    expect(names(store, a), ['Red', 'Work']);
    expect(store.stateOf([a, b], 'Red'), TagState.all);
    expect(store.stateOf([a, b], 'Work'), TagState.some);
    expect(store.stateOf([a, b], 'Blue'), TagState.none);

    store.toggle([a, b], 'Work'); // Some had it: all get it.
    expect(store.stateOf([a, b], 'Work'), TagState.all);
    store.toggle([a, b], 'Work'); // All had it: all lose it.
    expect(store.stateOf([a, b], 'Work'), TagState.none);
    expect(store.tagNamed('work'), isNotNull, reason: 'the tag stays, whatever its case');

    final again = await open();
    expect(names(again, a), ['Red']);
    expect(again.pathsWith('red').map(p.basename).toSet(), {'a.txt', 'b.txt'});
    expect(again.tagNamed('Work'), isNotNull);
    final json = jsonDecode(File(file).readAsStringSync()) as Map;
    expect(json['version'], 1);
  });

  test('a name must be new, short, and without commas or line breaks', () async {
    final store = await open();
    expect(store.problemWith('  '), 'Type a name.');
    expect(store.problemWith('red'), contains('already'));
    expect(store.problemWith('a,b'), contains('comma'));
    expect(store.problemWith('x' * 61), contains('too long'));
    expect(store.problemWith('Red', renaming: 'Red'), isNull, reason: 'keeping its own name');
    expect(store.problemWith('RED', renaming: 'Red'), isNull, reason: 'changing its case');
    expect(() => store.addTag('Red'), throwsArgumentError);
    final work = store.addTag(' Work ', color: TagColor.blue);
    expect(work, const TagDef('Work', TagColor.blue));
  });

  test('renaming, recolouring and deleting a tag reach everything with it', () async {
    final a = make('a.txt'), b = make('b.txt');
    final system = _FakeSystemTags();
    final store = await open(system: system);
    store.setTag([a, b], 'Red', on: true);
    expect(system.written[p.normalize(a)], const [FinderTag('Red', 6)], reason: "Finder's copy");

    store.renameTag('Red', 'Urgent');
    expect(names(store, a), ['Urgent']);
    expect(store.renamedTo('Red'), 'Urgent');
    expect(system.written[p.normalize(b)], const [FinderTag('Urgent', 6)]);

    store.recolorTag('Urgent', TagColor.purple);
    expect(store.tagsOf(a).single.color, TagColor.purple);
    expect(system.written[p.normalize(a)], const [FinderTag('Urgent', 3)]);

    store.deleteTag('Urgent');
    expect(store.tagsOf(a), isEmpty);
    expect(store.tagNamed('Urgent'), isNull);
    expect(store.renamedTo('Red'), isNull, reason: "it's gone");
    expect(system.written[p.normalize(a)], isEmpty, reason: 'taken off in Finder too');
    expect((await open()).pathsWith('Urgent'), isEmpty);
  });

  test('tags follow renames and moves, folders taking what is inside', () async {
    final folder = make('Work', folder: true);
    final inside = make('Work/plan.txt');
    final deep = make('Work/2026/q1.txt');
    final other = make('Workshop.txt'); // Starts with the same letters.
    final store = await open();
    store.setTag([folder], 'Blue', on: true);
    store.setTag([inside, deep, other], 'Red', on: true);

    final moved = p.join(root.path, 'Archive', 'Work 2026');
    PathChanges.moved(folder, moved);
    expect(names(store, moved), ['Blue']);
    expect(names(store, p.join(moved, 'plan.txt')), ['Red']);
    expect(names(store, p.join(moved, '2026', 'q1.txt')), ['Red']);
    expect(store.tagsOf(folder), isEmpty);
    expect(store.tagsOf(inside), isEmpty);
    expect(names(store, other), ['Red'], reason: 'not inside the folder');

    // Kept for the next start.
    expect(names(await open(), p.join(moved, 'plan.txt')), ['Red']);
  });

  test('copies keep the tags; deleted items lose them', () async {
    final folder = make('Photos', folder: true);
    final photo = make('Photos/beach.jpg');
    final store = await open();
    store.setTag([photo], 'Green', on: true);
    store.setTag([folder], 'Holiday', on: true);

    final copy = p.join(root.path, 'Photos - Copy');
    PathChanges.copied(folder, copy);
    expect(names(store, p.join(copy, 'beach.jpg')), ['Green']);
    expect(names(store, copy), ['Holiday']);
    expect(names(store, photo), ['Green'], reason: 'the original keeps its own');

    PathChanges.deleted(folder);
    expect(store.tagsOf(photo), isEmpty);
    expect(store.tagsOf(folder), isEmpty);
    expect(names(store, copy), ['Holiday']);
  });

  test("the file system's renames and deletions in Folders reach the tags", () async {
    final a = make('a.txt');
    final store = await open();
    store.setTag([a], 'Yellow', on: true);
    final b = p.join(root.path, 'b.txt');
    await LocalFileRepository().rename(a, b);
    expect(names(store, b), ['Yellow']);
    await LocalFileRepository().delete(b);
    expect(store.pathsWith('Yellow'), isEmpty);
  });

  test("the copy engine's moves and copies say where items went", () async {
    final a = make('docs/a.txt');
    final target = make('target', folder: true);
    final store = await open();
    store.setTag([a], 'Orange', on: true);
    final placed = <(String, String)>[];
    await pasteEntities([a], target, move: true, onPlaced: (from, to) {
      placed.add((from, to));
      PathChanges.moved(from, to);
    });
    expect(placed, [(a, p.join(target, 'a.txt'))]);
    expect(names(store, p.join(target, 'a.txt')), ['Orange']);

    // A copy into its own folder: "a - Copy.txt" keeps the tag.
    await pasteEntities([p.join(target, 'a.txt')], target, move: false, onPlaced: PathChanges.copied);
    expect(names(store, p.join(target, 'a - Copy.txt')), ['Orange']);
  });

  test("on Windows a path's case doesn't matter", () async {
    final store = await open(caseSensitive: false);
    final a = p.join(root.path, 'Report.PDF');
    store.setTag([a], 'Red', on: true);
    expect(names(store, a.toLowerCase()), ['Red']);
    PathChanges.moved(a.toLowerCase(), p.join(root.path, 'Final.pdf'));
    expect(names(store, p.join(root.path, 'FINAL.pdf')), ['Red']);
    expect(store.pathsWith('Red').single, p.join(root.path, 'Final.pdf'), reason: 'with the case it was given');
  });

  test("a tag's folder lists what's still there and drops what's gone", () async {
    final kept = make('kept.txt');
    final folder = make('Folder', folder: true);
    final gone = make('gone.txt');
    final store = await open();
    store.setTag([kept, folder, gone], 'Red', on: true);
    File(gone).deleteSync();

    final listed = await store.entitiesWith('Red');
    expect(listed.map((e) => p.basename(e.path)).toSet(), {'kept.txt', 'Folder'});
    expect(listed.whereType<Directory>().single.path, p.normalize(folder));
    expect(store.pathsWith('Red').map(p.basename).toSet(), {'kept.txt', 'Folder'}, reason: 'dropped from the list');
  });

  test("prune drops what's gone, but not what's on a drive that's out", () async {
    final kept = make('kept.txt');
    final gone = make('gone/deep/file.txt');
    final store = await open();
    final unplugged = Platform.isWindows
        ? '${_freeDriveLetter()}:\\Photos\\beach.jpg'
        : '/media/someone/USB/beach.jpg';
    store.setTag([kept, gone, unplugged], 'Red', on: true);
    Directory(p.join(root.path, 'gone')).deleteSync(recursive: true);

    expect(store.prune(), 1);
    expect(store.pathsWith('Red').map(p.basename).toSet(), {'kept.txt', 'beach.jpg'});
    expect(TagStore.goneForGood(gone), isTrue);
    expect(TagStore.goneForGood(unplugged), isFalse);
  });

  test("another window's changes are read before changing anything", () async {
    final a = make('a.txt'), b = make('b.txt');
    final one = await open();
    final two = await open();
    one.setTag([a], 'Red', on: true);
    // The file's time can be the same for two quick writes; its size isn't.
    two.setTag([b], 'Blue', on: true);
    expect(names(two, a), ['Red'], reason: 'two read what one saved first');
    one.setTag([a], 'Green', on: true);
    expect(names(one, b), ['Blue']);
    expect(names(await open(), a), ['Red', 'Green']);
  });

  test("tags set in Finder or Dolphin are taken in, with Finder's colours", () async {
    final a = make('a.txt');
    final system = _FakeSystemTags();
    final store = await open(system: system);
    store.takeInSystemTags({
      a: const [FinderTag('Red', 6), FinderTag('Clients', 4), FinderTag('bad,name')],
    });
    expect(names(store, a), ['Red', 'Clients']);
    expect(store.tagNamed('Clients')!.color, TagColor.blue);
    expect(system.written, isEmpty, reason: 'nothing written back');
  });

  test('explorer:// places get no tags', () async {
    final store = await open();
    store.setTag(['explorer://remote/nas/report.pdf'], 'Red', on: true);
    expect(store.pathsWith('Red'), isEmpty);
    expect(TagStore.canTag('explorer://trash'), isFalse);
  });

  test('tag folder paths', () {
    expect(TagPaths.of('Work / Home'), 'explorer://tag/Work%20%2F%20Home');
    expect(TagPaths.nameOf(TagPaths.of('Work / Home')), 'Work / Home');
    expect(TagPaths.isTag('explorer://tag/Red'), isTrue);
    expect(TagPaths.nameOf('/home/me'), isNull);
  });
}

/// A drive letter with no drive behind it.
String _freeDriveLetter() {
  for (final letter in 'QRSTUVWXYZ'.split('')) {
    if (!Directory('$letter:\\').existsSync()) return letter;
  }
  return 'Q';
}
