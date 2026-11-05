import 'dart:convert';
import 'dart:io';

import 'package:explorer/core/services/device_files.dart';
import 'package:explorer/features/category_view/home_media.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A folder holding videos, wherever it is on the device.
class VideoFolder {
  const VideoFolder(this.path, this.videos);

  final String path;

  /// Newest first.
  final List<DeviceFile> videos;

  String get name {
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }
}

/// All the videos on the device, by folder.
abstract final class VideoLibrary {
  /// Instead of searching the device, in tests.
  @visibleForTesting
  static Future<List<DeviceFile>> Function()? findOverride;

  /// Newest first: Android's media index on a phone, the usual home folders on
  /// a computer.
  static Future<List<DeviceFile>> find() {
    final override = findOverride;
    if (override != null) return override();
    return Platform.isAndroid ? DeviceFiles.findAndroidVideo() : HomeMedia.find(RequestType.video);
  }

  /// [videos] by folder, the folders by name.
  static List<VideoFolder> foldersOf(List<DeviceFile> videos) {
    final byFolder = <String, List<DeviceFile>>{};
    for (final video in videos) {
      byFolder.putIfAbsent(p.dirname(video.path), () => []).add(video);
    }
    final folders = [for (final entry in byFolder.entries) VideoFolder(entry.key, entry.value)];
    folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return folders;
  }
}

/// How far a video has been watched.
class VideoProgress {
  const VideoProgress(this.position, this.duration, this.at);

  factory VideoProgress.fromJson(Map<String, Object?> json) => VideoProgress(
        Duration(milliseconds: (json['p'] as num?)?.toInt() ?? 0),
        Duration(milliseconds: (json['d'] as num?)?.toInt() ?? 0),
        DateTime.fromMillisecondsSinceEpoch((json['t'] as num?)?.toInt() ?? 0),
      );

  final Duration position;
  final Duration duration;

  /// When it was last played.
  final DateTime at;

  /// 0 to 1.
  double get fraction =>
      duration > Duration.zero ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) : 0;

  /// Near the end counts as seen: it starts over next time.
  bool get finished => duration > Duration.zero && fraction > 0.95;

  Map<String, Object?> toJson() => {
        'p': position.inMilliseconds,
        'd': duration.inMilliseconds,
        't': at.millisecondsSinceEpoch,
      };
}

/// What has been played and where it stopped, and the stream addresses used.
class VideoHistory extends ChangeNotifier {
  VideoHistory._();

  static final instance = VideoHistory._();

  static const _key = 'video_history';
  static const _streamsKey = 'video_streams';
  static const _maxStreams = 20;

  /// A video nobody played is new for this long.
  static const newFor = Duration(days: 7);

  final _played = <String, VideoProgress>{};
  final _streams = <String>[];
  Future<void>? _loading;

  List<String> get streams => List.unmodifiable(_streams);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null) {
      try {
        final map = jsonDecode(saved) as Map<String, Object?>;
        map.forEach((path, value) {
          _played[path] = VideoProgress.fromJson(value! as Map<String, Object?>);
        });
      } on FormatException {
        // Start over, rather than not at all.
      }
    }
    _streams.addAll(prefs.getStringList(_streamsKey) ?? const []);
    notifyListeners();
  }

  VideoProgress? progressOf(String path) => _played[path];

  /// Not played yet, and recent.
  bool isNew(DeviceFile video, {DateTime? now}) =>
      !_played.containsKey(video.path) && (now ?? DateTime.now()).difference(video.modified) < newFor;

  /// What's been played, newest first.
  List<String> get recent {
    final paths = _played.keys.where((path) => !isStream(path)).toList();
    paths.sort((a, b) => _played[b]!.at.compareTo(_played[a]!.at));
    return paths;
  }

  /// The video played last, if any.
  String? get lastPlayed {
    String? last;
    DateTime? at;
    _played.forEach((path, progress) {
      if (at == null || progress.at.isAfter(at!)) {
        last = path;
        at = progress.at;
      }
    });
    return last;
  }

  /// The folder of what's been played last, which the library marks.
  String? get lastFolder {
    final last = lastPlayed;
    return last == null || isStream(last) ? null : p.dirname(last);
  }

  static bool isStream(String path) => RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+://').hasMatch(path);

  Future<void> record(String path, Duration position, Duration duration) async {
    _played[path] = VideoProgress(position, duration, DateTime.now());
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode({
      for (final entry in _played.entries) entry.key: entry.value.toJson(),
    }));
  }

  Future<void> addStream(String url) async {
    _streams
      ..remove(url)
      ..insert(0, url);
    if (_streams.length > _maxStreams) _streams.removeRange(_maxStreams, _streams.length);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_streamsKey, _streams);
  }

  @visibleForTesting
  void reset() {
    _played.clear();
    _streams.clear();
    _loading = null;
  }
}

/// The user's own lists of videos.
class VideoPlaylists extends ChangeNotifier {
  VideoPlaylists._();

  static final instance = VideoPlaylists._();

  static const _key = 'video_playlists';

  final _lists = <String, List<String>>{};
  Future<void>? _loading;

  List<String> get names {
    final names = _lists.keys.toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  List<String> videosOf(String name) => List.unmodifiable(_lists[name] ?? const <String>[]);

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null) {
      try {
        (jsonDecode(saved) as Map<String, Object?>).forEach((name, paths) {
          _lists[name] = (paths! as List<Object?>).cast<String>();
        });
      } on FormatException {
        // Start over, rather than not at all.
      }
    }
    notifyListeners();
  }

  Future<void> _changed() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_lists));
  }

  Future<void> create(String name) {
    _lists.putIfAbsent(name, () => []);
    return _changed();
  }

  Future<void> delete(String name) {
    _lists.remove(name);
    return _changed();
  }

  /// At the end, and only once.
  Future<void> add(String name, String path) {
    final list = _lists.putIfAbsent(name, () => []);
    if (!list.contains(path)) list.add(path);
    return _changed();
  }

  Future<void> remove(String name, String path) {
    _lists[name]?.remove(path);
    return _changed();
  }

  @visibleForTesting
  void reset() {
    _lists.clear();
    _loading = null;
  }
}
