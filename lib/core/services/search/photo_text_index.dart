import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/image_text.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Reads the text in a photo; null when it has none or can't be read.
typedef PhotoOcr = Future<String?> Function(String path);

/// The text found in photos, kept so each one is read once: by path, read
/// again when its size or date changes. Saved as JSON in the app's support
/// folder (search/photo_text.json). Photos are only read for a search, in
/// the folders it looks through.
class PhotoTextIndex {
  PhotoTextIndex({
    required this.folder,
    required this.ocr,
    this.maxEntries = 20000,
    this.maxText = 4000,
  });

  /// Where the index is kept.
  final Future<String> Function() folder;
  final PhotoOcr ocr;

  /// The most photos kept (the oldest read go first), and the most text
  /// kept per photo.
  final int maxEntries;
  final int maxText;

  /// The app's index; null where photos can't be read (no OCR on this
  /// system, or in tests).
  static PhotoTextIndex? get shared {
    final test = override;
    if (test != null) return test;
    if (!ImageTextReader.enabled) return null;
    return _shared ??= PhotoTextIndex(
      folder: () async => p.join((await getApplicationSupportDirectory()).path, 'search'),
      ocr: (path) async => (await ImageTextReader.read(File(path)))?.text,
    );
  }

  static PhotoTextIndex? _shared;

  @visibleForTesting
  static PhotoTextIndex? override;

  /// Pictures the system's text recognition takes, up to this size.
  static const maxPhotoBytes = 40 << 20;
  static const _readable = {'jpg', 'jpeg', 'jfif', 'png', 'webp', 'bmp', 'heic', 'heif', 'tif', 'tiff'};

  /// Whether [path] is a picture whose text can be read, by its name.
  static bool canRead(String path) => _readable.contains(FileTypes.extensionOf(path));

  /// Path → size, modified (ms) and text, oldest first.
  final _entries = <String, (int, int, String)>{};
  Future<void>? _loading;
  final _reading = <String, Future<String>>{};
  var _unsaved = 0;
  Future<void> _saving = Future.value();

  /// How many photos it knows.
  int get length => _entries.length;

  /// Reads the saved index (once).
  Future<void> load() => _loading ??= _load();

  Future<String> get _file async => p.join(await folder(), 'photo_text.json');

  Future<void> _load() async {
    try {
      final file = File(await _file);
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['v'] != 1 || data['photos'] is! Map) return;
      for (final MapEntry(:key, :value) in (data['photos'] as Map).entries) {
        if (key is String && value is List && value.length == 3) {
          final [size, modified, text] = value;
          if (size is int && modified is int && text is String) _entries[key] = (size, modified, text);
        }
      }
    } catch (_) {
      // A damaged index starts again.
    }
  }

  /// The text known for [path] as it is now ([size], [modified] in ms); null
  /// when it hasn't been read since it last changed, empty when it has no
  /// text.
  String? known(String path, int size, int modified) {
    final entry = _entries[path];
    if (entry == null || entry.$1 != size || entry.$2 != modified) return null;
    return entry.$3;
  }

  /// [path]'s text, read (once, even when asked for twice) and kept.
  Future<String> read(String path, int size, int modified) {
    final cached = known(path, size, modified);
    if (cached != null) return Future.value(cached);
    return _reading[path] ??= _read(path, size, modified);
  }

  Future<String> _read(String path, int size, int modified) async {
    try {
      String? text;
      try {
        text = await ocr(path);
      } catch (_) {
        text = null;
      }
      var kept = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (kept.length > maxText) kept = kept.substring(0, maxText);
      _entries.remove(path);
      _entries[path] = (size, modified, kept);
      while (_entries.length > maxEntries) {
        _entries.remove(_entries.keys.first);
      }
      if (++_unsaved >= 10) unawaited(save());
      return kept;
    } finally {
      _reading.remove(path);
    }
  }

  /// Writes what's new to disk (also every ten photos by itself).
  Future<void> save() {
    if (_unsaved == 0) return _saving;
    _unsaved = 0;
    return _saving = _saving.then((_) => _write());
  }

  Future<void> _write() async {
    try {
      final path = await _file;
      await Directory(p.dirname(path)).create(recursive: true);
      final temp = File('$path.tmp');
      await temp.writeAsString(jsonEncode({
        'v': 1,
        'photos': {
          for (final MapEntry(:key, :value) in _entries.entries) key: [value.$1, value.$2, value.$3],
        },
      }));
      await temp.rename(path);
    } catch (_) {
      _unsaved++;
    }
  }
}
