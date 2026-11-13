import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:folders/core/formats/finder_tags_plist.dart';
import 'package:folders/core/platform/system_tags.dart';
import 'package:folders/core/services/path_changes.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/tags/tag_color.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A tag: a name, and a colour or none. Finder's colour labels are tags
/// named after their colour.
@immutable
class TagDef {
  const TagDef(this.name, [this.color = TagColor.none]);

  final String name;
  final TagColor color;

  /// Tags are told apart by name, whatever its case.
  String get key => TagStore.keyOf(name);

  TagDef copyWith({String? name, TagColor? color}) => TagDef(name ?? this.name, color ?? this.color);

  @override
  bool operator ==(Object other) => other is TagDef && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(name, color);

  @override
  String toString() => 'TagDef($name, ${color.name})';
}

/// Whether items have a tag: all of them, some, or none.
enum TagState { all, some, none }

/// The tags and what has them, kept by path in `tags/tags.json` in the app's
/// support folder, and shared by its windows (each window is its own
/// process: the file is read again when another one changes it).
///
/// Paths follow renames, moves and copies made in Folders ([PathChanges]);
/// deleted items lose their tags. Items gone some other way are dropped when
/// their tag's folder is listed ([entitiesWith]), unless their drive looks
/// unplugged. On macOS and Linux each change is also written beside the
/// file for Finder or Dolphin ([SystemTags]), and tags set there are taken
/// in when the item shows ([lookAtSystemTags]).
class TagStore extends ChangeNotifier {
  /// A store kept in [file]; none keeps it in memory only.
  TagStore({String? file, bool? caseSensitive, SystemTags? systemTags, bool watch = false})
      : this._(() async => file, caseSensitive: caseSensitive, systemTags: systemTags, watch: watch);

  TagStore._(
    this._locate, {
    bool? caseSensitive,
    SystemTags? systemTags,
    bool watch = false,
  })  : caseSensitive = caseSensitive ?? !Platform.isWindows,
        _system = systemTags,
        _watch = watch {
    PathChanges.addListener(_onPathChange);
  }

  static TagStore? _instance;

  /// The app's store. Tests get one in memory.
  static TagStore get instance => _instance ??= Platform.environment.containsKey('FLUTTER_TEST')
      ? TagStore()
      : TagStore._(
          () async => p.join((await getApplicationSupportDirectory()).path, 'tags', 'tags.json'),
          systemTags: SystemTags.forPlatform(),
          watch: true,
        );

  @visibleForTesting
  static set instance(TagStore? store) => _instance = store;

  /// Whether paths differing only in case are different items (not on
  /// Windows).
  final bool caseSensitive;
  final Future<String?> Function() _locate;
  final SystemTags? _system;
  final bool _watch;

  String? _file;
  final List<TagDef> _tags = [];
  final Map<String, _Item> _items = {};
  bool _loaded = false;
  Future<void>? _loading;
  final List<PathChange> _waiting = [];
  ({DateTime modified, int size})? _seen;
  StreamSubscription<FileSystemEvent>? _watcher;

  /// Paths whose system tags are to be written after a change.
  final Set<String> _touched = {};

  /// Counts changes, for cheap "anything new?" checks.
  int get revision => _revision;
  int _revision = 0;

  static String keyOf(String tagName) => tagName.trim().toLowerCase();

  /// Whether [path] can have tags: paths on this computer's disks, not
  /// explorer://... places (other machines, the Trash...).
  static bool canTag(String path) => path.isNotEmpty && !path.contains('://');

  static const defaults = [
    TagDef('Red', TagColor.red),
    TagDef('Orange', TagColor.orange),
    TagDef('Yellow', TagColor.yellow),
    TagDef('Green', TagColor.green),
    TagDef('Blue', TagColor.blue),
    TagDef('Purple', TagColor.purple),
    TagDef('Grey', TagColor.grey),
  ];

  bool get loaded => _loaded;

  Future<void> ensureLoaded() => _loaded ? Future.value() : (_loading ??= _load());

  Future<void> _load() async {
    try {
      _file = await _locate();
    } catch (_) {
      _file = null; // No support folder: in memory only.
    }
    _readFile();
    _loaded = true;
    final waiting = List.of(_waiting);
    _waiting.clear();
    if (waiting.isNotEmpty) _change(() => waiting.map(_apply).fold(false, (a, b) => a || b));
    _startWatching();
    _revision++;
    notifyListeners();
  }

  void _startWatching() {
    final file = _file;
    if (!_watch || file == null) return;
    try {
      final dir = Directory(p.dirname(file))..createSync(recursive: true);
      _watcher = dir.watch().listen(
        (event) {
          if (p.basename(event.path) != p.basename(file)) return;
          if (_syncFromDisk()) {
            _revision++;
            notifyListeners();
          }
        },
        onError: (Object _) {},
      );
    } catch (_) {
      // Not watchable: changes from other windows show on the next change here.
    }
  }

  /// Stops listening for moves and for the file.
  void close() {
    PathChanges.removeListener(_onPathChange);
    _watcher?.cancel();
    _watcher = null;
  }

  // ---- Reading and writing the file -------------------------------------

  void _readFile() {
    final path = _file;
    final file = path == null ? null : File(path);
    if (file == null || !file.existsSync()) {
      if (_tags.isEmpty) _tags.addAll(defaults);
      _seen = null;
      return;
    }
    try {
      final stat = file.statSync();
      _fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>);
      _seen = (modified: stat.modified, size: stat.size);
    } catch (e) {
      debugPrint("Couldn't read the tags: $e");
      if (_tags.isEmpty) _tags.addAll(defaults);
    }
  }

  /// Reads the file again if another window changed it; true if it did.
  bool _syncFromDisk() {
    final path = _file;
    if (path == null) return false;
    final FileStat stat;
    try {
      stat = File(path).statSync();
    } catch (_) {
      return false;
    }
    if (stat.type == FileSystemEntityType.notFound) return false;
    final seen = _seen;
    if (seen != null && seen.modified == stat.modified && seen.size == stat.size) return false;
    _readFile();
    return true;
  }

  void _save() {
    final path = _file;
    if (path == null) return;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      // Whole or not at all: another window may read it at any moment.
      final temp = File('$path.$pid.tmp');
      temp.writeAsStringSync(jsonEncode(_toJson()), flush: true);
      temp.renameSync(path);
      final stat = file.statSync();
      _seen = (modified: stat.modified, size: stat.size);
    } catch (e) {
      debugPrint("Couldn't save the tags: $e");
    }
  }

  Map<String, dynamic> _toJson() => {
        'version': 1,
        'tags': [
          for (final t in _tags) {'name': t.name, if (t.color != TagColor.none) 'color': t.color.name},
        ],
        'items': {
          for (final item in _items.values)
            if (item.tags.isNotEmpty) item.path: [for (final t in _tags) if (item.tags.contains(t.key)) t.name],
        },
      };

  void _fromJson(Map<String, dynamic> json) {
    _tags.clear();
    _items.clear();
    for (final raw in (json['tags'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final name = (raw['name'] as String? ?? '').trim();
      if (name.isEmpty || _tags.any((t) => t.key == keyOf(name))) continue;
      _tags.add(TagDef(name, TagColor.byName(raw['color'] as String?)));
    }
    final items = json['items'];
    if (items is Map) {
      for (final MapEntry(:key, :value) in items.entries) {
        if (key is! String || value is! List) continue;
        final tags = <String>{};
        for (final name in value.whereType<String>()) {
          if (name.trim().isEmpty) continue;
          _defineIfMissing(name.trim());
          tags.add(keyOf(name));
        }
        if (tags.isNotEmpty) _items[_pathKey(key)] = _Item(p.normalize(key), tags);
      }
    }
  }

  TagDef _defineIfMissing(String name, [TagColor color = TagColor.none]) {
    final existing = tagNamed(name);
    if (existing != null) return existing;
    final tag = TagDef(name, color);
    _tags.add(tag);
    return tag;
  }

  // ---- Looking things up ------------------------------------------------

  List<TagDef> get tags => List.unmodifiable(_tags);

  TagDef? tagNamed(String name) {
    final key = keyOf(name);
    for (final t in _tags) {
      if (t.key == key) return t;
    }
    return null;
  }

  /// [path]'s tags, in the tags' order.
  List<TagDef> tagsOf(String path) {
    final item = _items[_pathKey(path)];
    if (item == null || item.tags.isEmpty) return const [];
    return [for (final t in _tags) if (item.tags.contains(t.key)) t];
  }

  bool has(String path, String tag) => _items[_pathKey(path)]?.tags.contains(keyOf(tag)) ?? false;

  TagState stateOf(Iterable<String> paths, String tag) {
    var any = false, all = true;
    for (final path in paths) {
      if (has(path, tag)) {
        any = true;
      } else {
        all = false;
      }
    }
    return !any ? TagState.none : (all ? TagState.all : TagState.some);
  }

  /// The paths with [tag], whether they're still there or not.
  List<String> pathsWith(String tag) {
    final key = keyOf(tag);
    return [for (final item in _items.values) if (item.tags.contains(key)) item.path];
  }

  int countOf(String tag) {
    final key = keyOf(tag);
    return _items.values.where((item) => item.tags.contains(key)).length;
  }

  /// Whether any item has [tag].
  bool isUsed(String tag) {
    final key = keyOf(tag);
    return _items.values.any((item) => item.tags.contains(key));
  }

  /// What has [tag] and is still there, for its folder. What's gone for
  /// good is dropped from the list on the way.
  Future<List<FileSystemEntity>> entitiesWith(String tag) async {
    await ensureLoaded();
    if (_syncFromDisk()) {
      _revision++;
      notifyListeners();
    }
    final found = <FileSystemEntity>[];
    final gone = <String>[];
    for (final path in pathsWith(tag)) {
      final type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) {
        if (goneForGood(path)) gone.add(path);
        continue;
      }
      // In the Trash: kept, so its tags come back with it, but not shown.
      if (Trash.instance.contains(path)) continue;
      found.add(type == FileSystemEntityType.directory ? Directory(path) : File(path));
    }
    if (gone.isNotEmpty) {
      _change(() {
        for (final path in gone) {
          _items.remove(_pathKey(path));
        }
        return true;
      });
    }
    return found;
  }

  // ---- Changing tags ----------------------------------------------------

  /// Why [name] can't be a tag's name, or null if it can. [renaming] is the
  /// tag being renamed, which may keep its name or change its case.
  String? problemWith(String name, {String? renaming}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Type a name.';
    if (trimmed.contains('\n') || trimmed.contains(',')) return "A tag's name can't have a comma or a line break.";
    if (trimmed.length > 60) return 'That name is too long.';
    final clash = tagNamed(trimmed);
    if (clash != null && (renaming == null || clash.key != keyOf(renaming))) return 'There is a tag with this name already.';
    return null;
  }

  /// Makes a tag; throws an [ArgumentError] saying why when [name] can't be
  /// one ([problemWith]).
  TagDef addTag(String name, {TagColor color = TagColor.none}) {
    final problem = problemWith(name);
    if (problem != null) throw ArgumentError(problem);
    final tag = TagDef(name.trim(), color);
    _change(() {
      _tags.add(tag);
      return true;
    });
    return tag;
  }

  void renameTag(String from, String to) {
    final tag = tagNamed(from);
    if (tag == null) return;
    final problem = problemWith(to, renaming: from);
    if (problem != null) throw ArgumentError(problem);
    if (tag.copyWith(name: to.trim()) == tag) return;
    _change(() {
      // As it is now: another window may have changed it.
      final tag = tagNamed(from);
      if (tag == null || problemWith(to, renaming: from) != null) return false;
      final renamed = tag.copyWith(name: to.trim());
      _renamedTo[tag.key] = renamed.name;
      _tags[_tags.indexOf(tag)] = renamed;
      for (final item in _items.values) {
        if (item.tags.remove(tag.key)) {
          item.tags.add(renamed.key);
          _touched.add(item.path);
        }
      }
      return true;
    });
  }

  void recolorTag(String name, TagColor color) {
    final tag = tagNamed(name);
    if (tag == null || tag.color == color) return;
    _change(() {
      final tag = tagNamed(name);
      if (tag == null || tag.color == color) return false;
      _tags[_tags.indexOf(tag)] = tag.copyWith(color: color);
      for (final item in _items.values) {
        if (item.tags.contains(tag.key)) _touched.add(item.path);
      }
      return true;
    });
  }

  final Map<String, String> _renamedTo = {};

  /// What the tag once named [name] is called now, if it was renamed here.
  String? renamedTo(String name) {
    String? now;
    var key = keyOf(name);
    for (var hops = 0; hops < 16 && _renamedTo.containsKey(key); hops++) {
      now = _renamedTo[key];
      key = keyOf(now!);
    }
    return now == null || tagNamed(now) == null ? null : tagNamed(now)!.name;
  }

  /// Whether [tag] is one of Finder's colour labels as they come.
  static bool isBuiltIn(TagDef tag) => defaults.any((d) => d.key == tag.key);

  /// Removes the tag, from everything that had it too.
  void deleteTag(String name) {
    if (tagNamed(name) == null) return;
    _change(() {
      final tag = tagNamed(name);
      if (tag == null) return false;
      _tags.remove(tag);
      for (final entry in _items.entries.toList()) {
        if (entry.value.tags.remove(tag.key)) {
          _touched.add(entry.value.path);
          if (entry.value.tags.isEmpty) _items.remove(entry.key);
        }
      }
      return true;
    });
  }

  /// Puts [tag] on [paths], or takes it off. A tag that isn't there yet is
  /// made, with no colour.
  void setTag(Iterable<String> paths, String tag, {required bool on}) {
    final list = paths.where(canTag).toList();
    if (list.isEmpty) return;
    _change(() {
      final def = on ? _defineIfMissing(tag.trim()) : tagNamed(tag);
      if (def == null) return false;
      var changed = false;
      for (final path in list) {
        final key = _pathKey(path);
        if (on) {
          final item = _items.putIfAbsent(key, () => _Item(p.normalize(path), {}));
          if (item.tags.add(def.key)) {
            changed = true;
            _touched.add(item.path);
          }
        } else {
          final item = _items[key];
          if (item != null && item.tags.remove(def.key)) {
            changed = true;
            _touched.add(item.path);
            if (item.tags.isEmpty) _items.remove(key);
          }
        }
      }
      return changed;
    });
  }

  /// Takes [tag] off [paths] if they all have it, else puts it on them all.
  void toggle(Iterable<String> paths, String tag) {
    final list = paths.toList();
    setTag(list, tag, on: stateOf(list, tag) != TagState.all);
  }

  /// Applies [change] (which says whether it changed anything) on top of
  /// what other windows saved, then saves and tells listeners.
  void _change(bool Function() change) {
    _syncFromDisk();
    _touched.clear();
    if (!change()) return;
    _save();
    final system = _system;
    if (system != null) {
      for (final path in _touched) {
        try {
          system.write(path, [for (final t in tagsOf(path)) FinderTag(t.name, t.color.finderIndex)]);
        } catch (_) {
          // The system's copy is a courtesy; Folders' own list has it.
        }
      }
    }
    _touched.clear();
    _revision++;
    notifyListeners();
  }

  // ---- Paths that change ------------------------------------------------

  void _onPathChange(PathChange change) {
    if (!_loaded) {
      _waiting.add(change);
      ensureLoaded();
      return;
    }
    _change(() => _apply(change));
  }

  /// Applies a move, copy or deletion; true if a tagged item was involved.
  bool _apply(PathChange change) => switch (change) {
        PathMoved(:final from, :final to) => _carry(from, to, keep: false),
        PathCopied(:final from, :final to) => _carry(from, to, keep: true),
        PathDeleted(:final path) => _forget(path),
      };

  /// The items at or inside [base].
  List<MapEntry<String, _Item>> _within(String base) {
    final key = _pathKey(base);
    final sep = p.separator;
    final prefix = key.endsWith(sep) ? key : '$key$sep';
    return [for (final e in _items.entries) if (e.key == key || e.key.startsWith(prefix)) e];
  }

  bool _carry(String from, String to, {required bool keep}) {
    final moving = _within(from);
    if (moving.isEmpty) return false;
    final base = p.normalize(from);
    final target = p.normalize(to);
    for (final MapEntry(:key, value: item) in moving) {
      if (!keep) _items.remove(key);
      final rest = item.path.length > base.length ? item.path.substring(base.length).replaceFirst(RegExp(r'^[\\/]+'), '') : '';
      final path = rest.isEmpty ? target : p.join(target, rest);
      _items.putIfAbsent(_pathKey(path), () => _Item(path, {})).tags.addAll(item.tags);
    }
    return true;
  }

  bool _forget(String path) {
    final gone = _within(path);
    for (final e in gone) {
      _items.remove(e.key);
    }
    return gone.isNotEmpty;
  }

  /// Drops every item that's gone for good ([goneForGood]); returns how many.
  int prune() {
    final gone = [
      for (final e in _items.entries)
        if (FileSystemEntity.typeSync(e.value.path, followLinks: false) == FileSystemEntityType.notFound &&
            goneForGood(e.value.path))
          e.key,
    ];
    if (gone.isEmpty) return 0;
    _change(() {
      gone.forEach(_items.remove);
      return true;
    });
    return gone.length;
  }

  /// Whether [path], which isn't there, is gone rather than on a drive that's
  /// unplugged: on Windows its drive is there; elsewhere the nearest folder
  /// still there isn't a place drives are mounted in (`/`, `/media/user`,
  /// `/Volumes`, `/mnt/disk`, `/storage`…).
  static bool goneForGood(String path) {
    if (Platform.isWindows) {
      final root = p.rootPrefix(path);
      return root.isNotEmpty && Directory(root).existsSync();
    }
    var dir = p.dirname(path);
    while (!Directory(dir).existsSync()) {
      final up = p.dirname(dir);
      if (up == dir) return false;
      dir = up;
    }
    return !_mountPlace.hasMatch(dir);
  }

  static final _mountPlace = RegExp(r'^/((media|mnt|Volumes|storage|run/media)(/[^/]+)?)?$');

  // ---- Tags set in Finder or Dolphin -----------------------------------

  final Set<String> _looked = {};
  final Set<String> _toLook = {};

  /// Takes in the tags Finder (macOS) or Dolphin (Linux) put on [path],
  /// once a session, soon after. Does nothing elsewhere.
  void lookAtSystemTags(String path) {
    if (_system == null || !_loaded) return;
    final key = _pathKey(path);
    if (!_looked.add(key)) return;
    if (_toLook.isEmpty) scheduleMicrotask(_lookNow);
    _toLook.add(path);
  }

  void _lookNow() {
    final system = _system;
    final paths = List.of(_toLook);
    _toLook.clear();
    if (system == null) return;
    final found = <String, List<FinderTag>>{};
    for (final path in paths) {
      try {
        final tags = system.read(path);
        if (tags != null && tags.isNotEmpty) found[path] = tags;
      } catch (_) {}
    }
    if (found.isEmpty) return;
    takeInSystemTags(found);
  }

  /// Adds tags another app put on items: unknown tags are made, with the
  /// colour they came with. Nothing is written back.
  @visibleForTesting
  void takeInSystemTags(Map<String, List<FinderTag>> found) {
    _syncFromDisk();
    var changed = false;
    for (final MapEntry(key: path, value: tags) in found.entries) {
      for (final tag in tags) {
        if (problemWith(tag.name) case final problem? when tagNamed(tag.name) == null) {
          debugPrint('Skipped the tag "${tag.name}": $problem');
          continue;
        }
        final def = _defineIfMissing(tag.name.trim(), TagColor.fromFinder(tag.color));
        changed |= _items.putIfAbsent(_pathKey(path), () => _Item(p.normalize(path), {})).tags.add(def.key);
      }
    }
    if (!changed) return;
    _save();
    _revision++;
    notifyListeners();
  }

  String _pathKey(String path) {
    final normal = p.normalize(path);
    return caseSensitive ? normal : normal.toLowerCase();
  }
}

class _Item {
  _Item(this.path, this.tags);

  final String path;

  /// Tag keys ([TagStore.keyOf]).
  final Set<String> tags;
}
