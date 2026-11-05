import 'dart:io';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'dart:isolate';

import 'package:explorer/core/files/file_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A file found by [DeviceFiles].
@immutable
class DeviceFile {
  const DeviceFile(this.path, this.size, this.modified);

  final String path;
  final int size;
  final DateTime modified;

  String get name => p.basename(path);
}

/// The groups of files the sidebar shows outside the media library.
enum DeviceFileGroup {
  documents,
  archives;

  Set<String> get extensions => switch (this) {
    documents => DeviceFiles.documentExtensions,
    archives => DeviceFiles.archiveExtensions,
  };
}

/// Finds files by type across the device: on Android from the MediaStore
/// index (fast, like the media library), elsewhere by walking the user's
/// Documents, Downloads and Desktop folders.
///
/// Results are cached, so a screen can show the last list at once while
/// [find] refreshes it.
abstract final class DeviceFiles {
  static const _channel = MethodChannel('explorer/device');

  static final Set<String> documentExtensions = {
    ...FileTypes.pdf,
    ...FileTypes.word,
    ...FileTypes.legacyWord,
    ...FileTypes.richText,
    ...FileTypes.openDocumentText,
    ...FileTypes.spreadsheet,
    ...FileTypes.legacySpreadsheet,
    ...FileTypes.delimited,
    ...FileTypes.openDocumentSpreadsheet,
    ...FileTypes.presentation,
    ...FileTypes.legacyPresentation,
    ...FileTypes.openDocumentPresentation,
    ...FileTypes.epub,
    ...FileTypes.ebook,
    ...FileTypes.comic,
    ...FileTypes.markdown,
    'txt',
  };

  static final Set<String> archiveExtensions = {
    ...FileTypes.archive,
    ...FileTypes.diskImage,
  };

  static final _cache = <DeviceFileGroup, List<DeviceFile>>{};
  static final _pending = <DeviceFileGroup, Future<List<DeviceFile>>>{};

  /// The last result of [find] for [group], if any.
  static List<DeviceFile>? cached(DeviceFileGroup group) => _cache[group];

  /// Files in [group], newest first. Concurrent calls share one search.
  static Future<List<DeviceFile>> find(DeviceFileGroup group) =>
      _pending[group] ??= _find(group.extensions)
          .then((files) {
            _cache[group] = files;
            return files;
          })
          .whenComplete(() => _pending.remove(group));

  /// All the music on an Android device, from the MediaStore index.
  static Future<List<DeviceFile>> findAndroidAudio() => _find(FileTypes.audio);

  /// A picture from a video on Android: JPEG, [size] pixels on the long side.
  /// Null if it has none, or Android can't read it.
  static Future<Uint8List?> videoFrame(String path, int size) async {
    try {
      return await _channel.invokeMethod<Uint8List>('videoFrame', {'path': path, 'size': size});
    } on PlatformException {
      return null;
    }
  }

  /// All the videos on an Android device, from the MediaStore index.
  static Future<List<DeviceFile>> findAndroidVideo() => _find(FileTypes.video);

  static Future<List<DeviceFile>> _find(Set<String> extensions) async {
    if (Platform.isAndroid) {
      final rows = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'queryFiles',
        {'extensions': extensions.toList()},
      );
      return [
        for (final row in rows ?? const <Map<Object?, Object?>>[])
          DeviceFile(
            row['path']! as String,
            (row['size'] as num?)?.toInt() ?? 0,
            DateTime.fromMillisecondsSinceEpoch(
              (row['modified'] as num?)?.toInt() ?? 0,
            ),
          ),
      ];
    }
    final roots = _desktopRoots();
    return Isolate.run(() => walk(roots, extensions));
  }

  /// Files with [extensions] under the user's home [folders] ("Pictures",
  /// "Downloads"...), newest first: the media categories on Windows and
  /// Linux, which have no media library.
  static Future<List<DeviceFile>> findInHome(
    List<String> folders,
    Set<String> extensions,
  ) {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null) return Future.value(const []);
    final roots = [
      for (final name in folders)
        if (Directory(p.join(home, name)).existsSync()) p.join(home, name),
    ];
    return Isolate.run(() => walk(roots, extensions));
  }

  static List<String> _desktopRoots() {
    final home =
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null) return const [];
    return [
      for (final name in const ['Documents', 'Downloads', 'Desktop'])
        p.join(home, name),
    ];
  }

  /// Files with [extensions] under [roots], newest first. Skips hidden
  /// items and node_modules, and on macOS what's inside packages (apps,
  /// document packages), as Finder does. It blocks: callers run it in an
  /// isolate.
  @visibleForTesting
  static List<DeviceFile> walk(List<String> roots, Set<String> extensions) {
    const limit = 50000;
    final skipPackages = Platform.isMacOS;
    final found = <DeviceFile>[];
    var seen = 0;
    final pending = [for (final r in roots) Directory(r)];
    while (pending.isNotEmpty && seen < limit) {
      final dir = pending.removeLast();
      final List<FileSystemEntity> children;
      try {
        children = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in children) {
        seen++;
        final name = p.basename(entity.path);
        if (name.startsWith('.') || name == 'node_modules') continue;
        if (entity is Directory) {
          // Goes by the name: no extra I/O per folder.
          if (!(skipPackages && FileTypes.isMacPackage(name))) {
            pending.add(entity);
          }
        } else if (entity is File &&
            extensions.contains(FileTypes.extensionOf(name))) {
          try {
            final stat = entity.statSync();
            found.add(DeviceFile(entity.path, stat.size, stat.modified));
          } on FileSystemException {
            // Gone or unreadable.
          }
        }
      }
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return found;
  }

  /// Forgets cached results, e.g. after files were moved or deleted.
  static void invalidate() => _cache.clear();

  /// Keeps the screen on and Wi-Fi awake while sharing; on computers,
  /// keeps them from going to sleep.
  static Future<void> keepAwake(bool on) async {
    if (!Platform.isAndroid) {
      try {
        await WakelockPlus.toggle(enable: on);
      } catch (e) {
        debugPrint('keepAwake failed: $e');
      }
      return;
    }
    try {
      await _channel.invokeMethod<void>('keepAwake', {'on': on});
    } on PlatformException catch (e) {
      debugPrint('keepAwake failed: $e');
    } on MissingPluginException {
      // Tests and older builds.
    }
  }
}
