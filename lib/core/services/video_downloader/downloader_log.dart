import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum LogLevel { info, warning, error }

/// What a log entry is about.
enum LogCategory {
  download('Download'),
  link('Link'),
  engine('Engine'),
  cookies('Cookies'),
  maintenance('Maintenance');

  const LogCategory(this.label);

  final String label;

  static LogCategory fromName(String? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => LogCategory.download);
}

/// One thing the downloader did, e.g. a finished download with what yt-dlp
/// printed.
class LogEntry {
  const LogEntry({
    required this.time,
    required this.level,
    required this.category,
    required this.title,
    this.details,
    this.ref,
  });

  final DateTime time;
  final LogLevel level;
  final LogCategory category;
  final String title;

  /// More lines: a job's yt-dlp output, an error message.
  final String? details;

  /// What it's about (e.g. a job and when it ended), so it's logged once.
  final String? ref;

  /// The entry as plain text, for copying and exporting.
  String toText() {
    final out = StringBuffer(
      '${DownloaderLog.stamp(time)}  ${level.name.toUpperCase().padRight(7)} '
      '[${category.label}] $title',
    );
    final more = details?.trimRight();
    if (more != null && more.isNotEmpty) {
      for (final line in more.split('\n')) {
        out.write('\n    $line');
      }
    }
    return out.toString();
  }

  Map<String, Object?> toJson() => {
        't': time.millisecondsSinceEpoch,
        'l': level.name,
        'c': category.name,
        'title': title,
        if (details != null) 'd': details,
        if (ref != null) 'r': ref,
      };

  static LogEntry? fromJson(Object? json) {
    if (json is! Map || json['t'] is! int || json['title'] is! String) return null;
    return LogEntry(
      time: DateTime.fromMillisecondsSinceEpoch(json['t'] as int),
      level: LogLevel.values.firstWhere((l) => l.name == json['l'], orElse: () => LogLevel.info),
      category: LogCategory.fromName(json['c'] as String?),
      title: json['title'] as String,
      details: json['d'] is String ? json['d'] as String : null,
      ref: json['r'] is String ? json['r'] as String : null,
    );
  }
}

/// The downloader's activity log, kept in app storage and capped at
/// [maxBytes] (the oldest entries go first). Everything added passes
/// through [redact], so cookie values never reach it.
class DownloaderLog extends ChangeNotifier {
  DownloaderLog({this.redact, this.maxBytes = 512 * 1024, this.maxDetails = 48 * 1024});

  final String Function(String text)? redact;
  final int maxBytes;

  /// Longer details keep their end, where errors are.
  final int maxDetails;

  File? _file;
  final _entries = <LogEntry>[];

  /// Each entry's size in the saved file, alongside [_entries].
  final _sizes = <int>[];
  Future<void> _writing = Future.value();
  Timer? _saveTimer;

  /// Oldest first.
  List<LogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  /// Loads the saved log from [file] (null: memory only).
  Future<void> open(File? file) async {
    _file = file;
    if (file == null) return;
    try {
      if (await file.exists()) {
        final saved = jsonDecode(await file.readAsString());
        if (saved is List) {
          _entries
            ..clear()
            ..addAll([for (final e in saved) ?LogEntry.fromJson(e)]);
          _sizes
            ..clear()
            ..addAll(_entries.map(_size));
          _trim();
        }
      }
    } catch (e) {
      debugPrint('Video downloader: the log could not be read ($e)');
    }
    notifyListeners();
  }

  bool hasRef(String ref) => _entries.any((e) => e.ref == ref);

  void add(
    String title, {
    LogLevel level = LogLevel.info,
    LogCategory category = LogCategory.download,
    String? details,
    String? ref,
    DateTime? time,
  }) {
    final clean = redact ?? (String s) => s;
    var more = details == null ? null : clean(details).trimRight();
    if (more != null && more.length > maxDetails) {
      final cut = more.indexOf('\n', more.length - maxDetails);
      more = '(earlier lines left out)\n${more.substring(cut < 0 ? more.length - maxDetails : cut + 1)}';
    }
    final entry = LogEntry(
      time: time ?? DateTime.now(),
      level: level,
      category: category,
      title: clean(title),
      details: more == null || more.isEmpty ? null : more,
      ref: ref,
    );
    _entries.add(entry);
    _sizes.add(_size(entry));
    _trim();
    notifyListeners();
    _scheduleSave();
  }

  Future<void> clear() async {
    _entries.clear();
    _sizes.clear();
    notifyListeners();
    await save();
  }

  static int _size(LogEntry e) => utf8.encode(jsonEncode(e.toJson())).length + 1;

  /// Drops the oldest entries until the saved log fits [maxBytes].
  void _trim() {
    var total = 2;
    for (final s in _sizes) {
      total += s;
    }
    var drop = 0;
    while (total > maxBytes && drop < _entries.length - 1) {
      total -= _sizes[drop];
      drop++;
    }
    if (drop > 0) {
      _entries.removeRange(0, drop);
      _sizes.removeRange(0, drop);
    }
  }

  void _scheduleSave() {
    if (_file == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () => unawaited(save()));
  }

  /// Writes the log now.
  Future<void> save() {
    _saveTimer?.cancel();
    final file = _file;
    if (file == null) return Future.value();
    final json = jsonEncode([for (final e in _entries) e.toJson()]);
    return _writing = _writing.catchError((Object _) {}).then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(json, flush: true);
        await temp.rename(file.path);
      } catch (e) {
        debugPrint('Video downloader: the log could not be saved ($e)');
      }
    });
  }

  /// [only] (or every entry), oldest first, as plain text.
  String toText([Iterable<LogEntry>? only]) {
    final list = (only ?? _entries).toList();
    return [
      'Folders video downloader log, ${stamp(DateTime.now())}',
      '',
      for (final e in list) e.toText(),
    ].join('\n');
  }

  /// "2026-11-12 14:03:22".
  static String stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${clock(t)}';

  /// "14:03:22".
  static String clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _two(int n) => n.toString().padLeft(2, '0');

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
