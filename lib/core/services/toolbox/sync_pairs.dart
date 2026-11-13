import 'dart:convert';

import 'package:folders/core/services/toolbox/folder_compare.dart';
import 'package:folders/core/services/toolbox/folder_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Two folders the user syncs now and then, and how.
class SyncPair {
  const SyncPair({
    required this.id,
    required this.name,
    required this.left,
    required this.right,
    this.mode = SyncMode.copy,
    this.options = const CompareOptions(),
    this.lastRun,
    this.lastSummary,
    this.lastSync,
  });

  final String id;
  final String name;
  final String left;
  final String right;
  final SyncMode mode;
  final CompareOptions options;

  /// When it last ran, and what it did then.
  final DateTime? lastRun;
  final String? lastSummary;

  /// When it last ran to the end with nothing left over: two-way takes files
  /// changed on both sides since then as conflicts.
  final DateTime? lastSync;

  /// "Photos → Backup".
  static String defaultName(String left, String right) => '${p.basename(left)} → ${p.basename(right)}';

  SyncPair copyWith({
    String? name,
    String? left,
    String? right,
    SyncMode? mode,
    CompareOptions? options,
    DateTime? lastRun,
    String? lastSummary,
    DateTime? lastSync,
  }) =>
      SyncPair(
        id: id,
        name: name ?? this.name,
        left: left ?? this.left,
        right: right ?? this.right,
        mode: mode ?? this.mode,
        options: options ?? this.options,
        lastRun: lastRun ?? this.lastRun,
        lastSummary: lastSummary ?? this.lastSummary,
        lastSync: lastSync ?? this.lastSync,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'left': left,
        'right': right,
        'mode': mode.name,
        'contents': options.contents,
        'hourShift': options.ignoreHourShift,
        if (lastRun != null) 'lastRun': lastRun!.millisecondsSinceEpoch,
        if (lastSummary != null) 'lastSummary': lastSummary,
        if (lastSync != null) 'lastSync': lastSync!.millisecondsSinceEpoch,
      };

  static SyncPair? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final left = json['left'];
    final right = json['right'];
    if (id is! String || left is! String || right is! String) return null;
    DateTime? time(Object? ms) => ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    final name = json['name'];
    return SyncPair(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : defaultName(left, right),
      left: left,
      right: right,
      mode: SyncMode.values.asNameMap()[json['mode']] ?? SyncMode.copy,
      options: CompareOptions(contents: json['contents'] == true, ignoreHourShift: json['hourShift'] == true),
      lastRun: time(json['lastRun']),
      lastSummary: json['lastSummary'] is String ? json['lastSummary'] as String : null,
      lastSync: time(json['lastSync']),
    );
  }
}

/// The saved [SyncPair]s, newest first, in the app's preferences.
abstract final class SyncPairs {
  static const key = 'folder_sync_pairs';

  static Future<List<SyncPair>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(key);
    if (text == null) return [];
    try {
      final list = jsonDecode(text);
      if (list is! List) return [];
      return [for (final json in list) ?SyncPair.fromJson(json)];
    } on FormatException {
      return [];
    }
  }

  static Future<void> _save(List<SyncPair> pairs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode([for (final pair in pairs) pair.toJson()]));
  }

  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// Adds [pair], or puts it in the place of the one with its id.
  static Future<void> put(SyncPair pair) async {
    final pairs = await load();
    final at = pairs.indexWhere((old) => old.id == pair.id);
    if (at < 0) {
      pairs.insert(0, pair);
    } else {
      pairs[at] = pair;
    }
    await _save(pairs);
  }

  static Future<void> remove(String id) async {
    final pairs = await load();
    pairs.removeWhere((pair) => pair.id == id);
    await _save(pairs);
  }

  static Future<void> rename(String id, String name) => _change(id, (pair) => pair.copyWith(name: name));

  /// What the pair's last run did; [complete] if it went to the end with
  /// nothing left over.
  static Future<void> recordRun(String id, {required DateTime at, required String summary, required bool complete}) =>
      _change(id, (pair) => pair.copyWith(lastRun: at, lastSummary: summary, lastSync: complete ? at : null));

  static Future<void> _change(String id, SyncPair Function(SyncPair pair) change) async {
    final pairs = await load();
    final at = pairs.indexWhere((pair) => pair.id == id);
    if (at < 0) return;
    pairs[at] = change(pairs[at]);
    await _save(pairs);
  }
}
