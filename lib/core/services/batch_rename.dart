import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

/// How names change case in a batch rename.
enum NameCase { keep, lower, upper, title }

/// What a batch rename does to each name, in this order: the [pattern]
/// (`{name}`, `{ext}`, `{n}`, `{date}`), then find and replace, then the
/// case, then [prefix] and [suffix]. With [keepExtension] all of it applies
/// to the name before its extension, which stays as it was; without, to the
/// whole name.
@immutable
class BatchRenameOptions {
  const BatchRenameOptions({
    this.pattern = '{name}',
    this.find = '',
    this.replace = '',
    this.regex = false,
    this.matchCase = false,
    this.nameCase = NameCase.keep,
    this.prefix = '',
    this.suffix = '',
    this.keepExtension = true,
    this.start = 1,
    this.step = 1,
    this.digits = 1,
    this.dateFormat = 'yyyy-MM-dd',
  });

  final String pattern;
  final String find;
  final String replace;
  final bool regex;
  final bool matchCase;
  final NameCase nameCase;
  final String prefix;
  final String suffix;
  final bool keepExtension;

  /// `{n}`: the first number, the step to the next, and at least this many
  /// digits (zeros in front).
  final int start;
  final int step;
  final int digits;

  /// `{date}`: the modified date, written this way (`yyyy-MM-dd`...).
  final String dateFormat;

  BatchRenameOptions copyWith({
    String? pattern,
    String? find,
    String? replace,
    bool? regex,
    bool? matchCase,
    NameCase? nameCase,
    String? prefix,
    String? suffix,
    bool? keepExtension,
    int? start,
    int? step,
    int? digits,
    String? dateFormat,
  }) =>
      BatchRenameOptions(
        pattern: pattern ?? this.pattern,
        find: find ?? this.find,
        replace: replace ?? this.replace,
        regex: regex ?? this.regex,
        matchCase: matchCase ?? this.matchCase,
        nameCase: nameCase ?? this.nameCase,
        prefix: prefix ?? this.prefix,
        suffix: suffix ?? this.suffix,
        keepExtension: keepExtension ?? this.keepExtension,
        start: start ?? this.start,
        step: step ?? this.step,
        digits: digits ?? this.digits,
        dateFormat: dateFormat ?? this.dateFormat,
      );
}

/// Something to rename.
@immutable
class RenameSource {
  RenameSource(this.path, {this.isDirectory = false, DateTime? modified})
      : modified = modified ?? DateTime.fromMillisecondsSinceEpoch(0);

  final String path;
  final bool isDirectory;
  final DateTime modified;

  String get name => p.basename(path);
  String get folder => p.dirname(path);

  static RenameSource of(FileSystemEntity entity) {
    DateTime? modified;
    try {
      modified = entity.statSync().modified;
    } catch (_) {}
    return RenameSource(entity.path, isDirectory: entity is Directory, modified: modified);
  }
}

/// Why a new name can't be used.
enum RenameProblem { empty, forbidden, reserved, tooLong, duplicate, exists, badPattern }

/// One item's new name, and what's wrong with it, if anything.
@immutable
class RenamePlan {
  const RenamePlan(this.source, this.newName, {this.problem, this.message});

  final RenameSource source;
  final String newName;
  final RenameProblem? problem;

  /// What [problem] means, in a few words.
  final String? message;

  bool get changed => newName != source.name;
  bool get ok => problem == null;
  String get from => source.path;
  String get to => p.join(source.folder, newName);
}

/// What a batch rename did.
class BatchRenameResult {
  const BatchRenameResult({this.done = const [], this.failed = const {}});

  /// (old path, new path) of each item renamed.
  final List<(String, String)> done;

  /// Old path: why it couldn't be renamed.
  final Map<String, String> failed;
}

/// Renames many items at once: new names from [BatchRenameOptions], checked
/// before anything is renamed, then renamed through temporary names so two
/// items can swap names.
abstract final class BatchRename {
  static const forbiddenCharacters = r'\ / : * ? " < > |';
  static final _forbidden = RegExp(r'[\\/:*?"<>|\x00-\x1f]');
  static final _reserved = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$', caseSensitive: false);
  static final _token = RegExp(r'\{(name|ext|n|date)(?::([^}]*))?\}');

  /// Whether names that differ only in case are the same here.
  static bool get caseInsensitive => !Platform.isLinux;

  /// The last batch rename, for Undo.
  static BatchRenameResult? last;

  /// The new name of [source], the [index]th of the batch.
  /// Throws a [FormatException] if the find pattern isn't a valid regular
  /// expression, or the date format can't be used.
  static String newName(RenameSource source, int index, BatchRenameOptions o) {
    final full = source.name;
    final ext = source.isDirectory ? '' : p.extension(full);
    final base = ext.isEmpty || ext == full ? full : full.substring(0, full.length - ext.length);
    final extension = ext.startsWith('.') ? ext.substring(1) : ext;
    final keepExt = o.keepExtension && extension.isNotEmpty;
    final subject = keepExt ? base : full;

    // The pattern.
    var name = o.pattern.replaceAllMapped(_token, (m) {
      final arg = m[2];
      switch (m[1]) {
        case 'name':
          return subject;
        case 'ext':
          return extension;
        case 'n':
          final digits = int.tryParse(arg ?? '') ?? o.digits;
          final n = o.start + index * o.step;
          final text = n.abs().toString().padLeft(digits.clamp(1, 12), '0');
          return n < 0 ? '-$text' : text;
        case 'date':
          final format = arg == null || arg.isEmpty ? o.dateFormat : arg;
          try {
            return DateFormat(format).format(source.modified);
          } catch (_) {
            throw FormatException('"$format" isn\'t a date format');
          }
      }
      return m[0]!;
    });

    // Find and replace.
    if (o.find.isNotEmpty) {
      if (o.regex) {
        final RegExp find;
        try {
          find = RegExp(o.find, caseSensitive: o.matchCase, unicode: true);
        } on FormatException {
          throw const FormatException("The find pattern isn't a valid regular expression");
        }
        name = name.replaceAllMapped(find, (m) => _expand(o.replace, m));
      } else if (o.matchCase) {
        name = name.replaceAll(o.find, o.replace);
      } else {
        name = name.replaceAll(RegExp(RegExp.escape(o.find), caseSensitive: false), o.replace);
      }
    }

    name = switch (o.nameCase) {
      NameCase.keep => name,
      NameCase.lower => name.toLowerCase(),
      NameCase.upper => name.toUpperCase(),
      NameCase.title => titleCase(name),
    };
    name = '${o.prefix}$name${o.suffix}';
    return keepExt ? '$name.$extension' : name;
  }

  /// `$1`, `$2`… in [replacement] become what the groups matched; `$0` the
  /// whole match.
  static String _expand(String replacement, Match m) =>
      replacement.replaceAllMapped(RegExp(r'\$(\d)'), (g) {
        final n = int.parse(g[1]!);
        return n <= m.groupCount ? (m.group(n) ?? '') : g[0]!;
      });

  /// "my holiday_photo-01" → "My Holiday_Photo-01".
  static String titleCase(String text) => text
      .toLowerCase()
      .replaceAllMapped(RegExp(r'(^|[\s_\-.,()\[\]])(\p{L})', unicode: true), (m) => '${m[1]}${m[2]!.toUpperCase()}');

  /// The new names for [sources], each checked: characters the system
  /// forbids, names given twice, names already taken in the folder by
  /// something that isn't being renamed. [namesIn] lists a folder's names;
  /// it reads the disk unless given.
  static List<RenamePlan> plan(
    List<RenameSource> sources,
    BatchRenameOptions options, {
    Set<String> Function(String folder)? namesIn,
    bool? caseInsensitive,
    bool? windowsRules,
  }) {
    final insensitive = caseInsensitive ?? BatchRename.caseInsensitive;
    final windows = windowsRules ?? Platform.isWindows;
    String key(String name) => insensitive ? name.toLowerCase() : name;
    final list = namesIn ?? _namesIn;

    final names = <String>[];
    try {
      for (var i = 0; i < sources.length; i++) {
        names.add(newName(sources[i], i, options));
      }
    } on FormatException catch (e) {
      return [
        for (final s in sources) RenamePlan(s, s.name, problem: RenameProblem.badPattern, message: e.message),
      ];
    }

    // Per folder: what's there that isn't being renamed, and how often each
    // new name comes up.
    final taken = <String, Set<String>>{};
    final counts = <String, Map<String, int>>{};
    final leaving = <String, Set<String>>{};
    for (var i = 0; i < sources.length; i++) {
      final s = sources[i];
      if (names[i] != s.name) leaving.putIfAbsent(s.folder, () => {}).add(key(s.name));
    }
    for (var i = 0; i < sources.length; i++) {
      final folder = sources[i].folder;
      taken.putIfAbsent(folder, () {
        final away = leaving[folder] ?? const {};
        return {for (final n in list(folder)) if (!away.contains(key(n))) key(n)};
      });
      final c = counts.putIfAbsent(folder, () => {});
      c[key(names[i])] = (c[key(names[i])] ?? 0) + 1;
    }

    return [
      for (var i = 0; i < sources.length; i++) _check(sources[i], names[i], taken, counts, key, windows),
    ];
  }

  static RenamePlan _check(
    RenameSource s,
    String name,
    Map<String, Set<String>> taken,
    Map<String, Map<String, int>> counts,
    String Function(String) key,
    bool windows,
  ) {
    RenamePlan problem(RenameProblem kind, String message) => RenamePlan(s, name, problem: kind, message: message);
    if (name.trim().isEmpty || name == '.' || name == '..') return problem(RenameProblem.empty, 'No name');
    if (_forbidden.hasMatch(name)) return problem(RenameProblem.forbidden, "Can't contain $forbiddenCharacters");
    if (windows && _reserved.hasMatch(name)) return problem(RenameProblem.reserved, 'Windows keeps this name for itself');
    if (windows && (name.endsWith('.') || name.endsWith(' '))) {
      return problem(RenameProblem.forbidden, "Can't end with a dot or a space");
    }
    if ((windows ? name.length : utf8.encode(name).length) > 255) return problem(RenameProblem.tooLong, 'Too long');
    if ((counts[s.folder]?[key(name)] ?? 0) > 1) return problem(RenameProblem.duplicate, 'Same name as another');
    // Its own name, unchanged or in another case, isn't in the way.
    if (name != s.name && (taken[s.folder]?.contains(key(name)) ?? false) && key(name) != key(s.name)) {
      return problem(RenameProblem.exists, 'Already in the folder');
    }
    return RenamePlan(s, name);
  }

  static Set<String> _namesIn(String folder) {
    try {
      return {for (final e in Directory(folder).listSync(followLinks: false)) p.basename(e.path)};
    } catch (_) {
      return const {};
    }
  }

  /// Renames what [plans] change: first each to a temporary name, then to
  /// its new one, so swaps and case changes work. Plans with a problem are
  /// left alone. Kept in [last] for Undo.
  static Future<BatchRenameResult> apply(List<RenamePlan> plans) async {
    final moves = [for (final plan in plans) if (plan.ok && plan.changed) (plan.from, plan.to)];
    final result = await _move(moves);
    last = result;
    return result;
  }

  /// Puts [result]'s names back.
  static Future<BatchRenameResult> undo(BatchRenameResult result) async {
    final back = await _move([for (final (from, to) in result.done) (to, from)]);
    if (identical(last, result)) last = null;
    return back;
  }

  static Future<BatchRenameResult> _move(List<(String, String)> moves) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final failed = <String, String>{};
    final parked = <(String, String, String)>[];
    for (var i = 0; i < moves.length; i++) {
      final (from, to) = moves[i];
      final temp = p.join(p.dirname(from), '.folders-rename-$stamp-$i');
      try {
        await _rename(from, temp);
        parked.add((from, temp, to));
      } catch (e) {
        failed[from] = _reason(e);
      }
    }
    final done = <(String, String)>[];
    for (final (from, temp, to) in parked) {
      try {
        if (FileSystemEntity.typeSync(to, followLinks: false) != FileSystemEntityType.notFound) {
          throw FileSystemException('Already in the folder', to);
        }
        await _rename(temp, to);
        done.add((from, to));
      } catch (e) {
        failed[from] = _reason(e);
        try {
          await _rename(temp, from);
        } catch (_) {}
      }
    }
    return BatchRenameResult(done: done, failed: failed);
  }

  static Future<void> _rename(String from, String to) async {
    final type = FileSystemEntity.typeSync(from, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(from).rename(to);
      case FileSystemEntityType.link:
        await Link(from).rename(to);
      case FileSystemEntityType.notFound:
        throw FileSystemException('Not found', from);
      default:
        await File(from).rename(to);
    }
  }

  static String _reason(Object error) => switch (error) {
        FileSystemException(:final osError?) => osError.message,
        FileSystemException(:final message) => message,
        _ => '$error',
      };
}
