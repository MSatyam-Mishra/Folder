import 'dart:async';
import 'dart:io';

import 'package:filesize/filesize.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:folders/core/platform/macos_files.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/services/toolbox/folder_compare.dart';
import 'package:folders/core/services/toolbox/sync_pairs.dart';
import 'package:path/path.dart' as p;

/// What a sync does with the differences.
enum SyncMode {
  copy('Copy', "Copies what's new or newer on the left to the right. Nothing is deleted."),
  mirror('Mirror', 'Makes the right an exact copy of the left. Files only on the right are deleted.'),
  twoWay('Two-way', "The newer file wins, both ways, and what's on one side only goes to the other. Nothing is deleted.");

  const SyncMode(this.label, this.description);

  final String label;
  final String description;
}

enum SyncActionKind {
  copyRight('Copy to the right'),
  copyLeft('Copy to the left'),
  replaceRight('Replace on the right'),
  replaceLeft('Replace on the left'),
  deleteRight('Delete on the right'),
  deleteLeft('Delete on the left');

  const SyncActionKind(this.label);

  final String label;

  bool get isDelete => this == deleteRight || this == deleteLeft;
  bool get isReplace => this == replaceRight || this == replaceLeft;

  /// Whether it writes to the right, or deletes there.
  bool get onRight => this == copyRight || this == replaceRight || this == deleteRight;
}

/// One thing a sync will do.
class SyncAction {
  const SyncAction(this.kind, this.item);

  final SyncActionKind kind;
  final SyncItem item;

  /// What it copies, or what it deletes.
  int get bytes => (kind.isDelete ? target : source)?.size ?? 0;

  /// The side it takes from: null for a delete.
  SyncStat? get source => kind.isDelete ? null : (kind.onRight ? item.left : item.right);

  /// What's on the side it changes, as the comparison saw it.
  SyncStat? get target => kind.onRight ? item.right : item.left;
}

/// Why two-way sync can't tell which side wins.
enum ConflictReason {
  sameDate('Same date, but they differ'),
  typeClash('A file on one side, a folder on the other'),
  bothChanged('Changed on both sides since the last sync');

  const ConflictReason(this.label);

  final String label;
}

/// Which side wins a conflict; [skip] leaves both as they are.
enum ConflictChoice { skip, left, right }

class SyncConflict {
  const SyncConflict(this.item, this.reason, this.choice);

  final SyncItem item;
  final ConflictReason reason;
  final ConflictChoice choice;
}

/// Everything a sync will do, in the order it does it, before anything is
/// done: deletes that make way for a copy, then copies and replaces, then
/// other deletes, so nothing is lost before its copy is made.
class SyncPlan {
  SyncPlan({
    required this.left,
    required this.right,
    required this.mode,
    required this.actions,
    required this.conflicts,
    required this.untouched,
  });

  final String left;
  final String right;
  final SyncMode mode;
  final List<SyncAction> actions;

  /// Two-way only: what it can't decide, and what the user chose.
  final List<SyncConflict> conflicts;

  /// Differences this mode leaves as they are (Copy: what's newer or only on
  /// the right, and what it can't tell).
  final List<SyncItem> untouched;

  bool get isEmpty => actions.isEmpty;

  List<SyncAction> of(SyncActionKind kind) => [for (final action in actions) if (action.kind == kind) action];

  int count(SyncActionKind kind) => actions.where((action) => action.kind == kind).length;

  int bytesOf(SyncActionKind kind) =>
      actions.where((action) => action.kind == kind).fold(0, (sum, action) => sum + action.bytes);

  /// What it copies, in all.
  int get copyBytes => actions.where((action) => !action.kind.isDelete).fold(0, (sum, action) => sum + action.bytes);

  int get deletes => actions.where((action) => action.kind.isDelete).length;

  int get deleteBytes => actions.where((action) => action.kind.isDelete).fold(0, (sum, action) => sum + action.bytes);

  /// Conflicts left as they are.
  int get skippedConflicts => conflicts.where((c) => c.choice == ConflictChoice.skip).length;
}

abstract final class SyncPlanner {
  /// What [mode] does with what [comparison] found. Two-way takes a file
  /// changed on both sides since [lastSync] as a conflict, and settles
  /// conflicts as [choices] say (by item path; skipped otherwise).
  static SyncPlan plan(
    FolderComparison comparison,
    SyncMode mode, {
    DateTime? lastSync,
    Map<String, ConflictChoice> choices = const {},
  }) {
    final makeWay = <SyncAction>[];
    final transfers = <SyncAction>[];
    final deletes = <SyncAction>[];
    final conflicts = <SyncConflict>[];
    final untouched = <SyncItem>[];

    void toRight(SyncItem item) {
      if (item.diff == SyncDiff.typeClash) {
        makeWay.add(SyncAction(SyncActionKind.deleteRight, item));
        transfers.add(SyncAction(SyncActionKind.copyRight, item));
      } else {
        transfers.add(SyncAction(item.right == null ? SyncActionKind.copyRight : SyncActionKind.replaceRight, item));
      }
    }

    void toLeft(SyncItem item) {
      if (item.diff == SyncDiff.typeClash) {
        makeWay.add(SyncAction(SyncActionKind.deleteLeft, item));
        transfers.add(SyncAction(SyncActionKind.copyLeft, item));
      } else {
        transfers.add(SyncAction(item.left == null ? SyncActionKind.copyLeft : SyncActionKind.replaceLeft, item));
      }
    }

    final since = lastSync?.add(FolderComparer.tolerance).millisecondsSinceEpoch;
    for (final item in comparison.items) {
      switch (mode) {
        case SyncMode.copy:
          if (item.diff == SyncDiff.onlyLeft || item.diff == SyncDiff.newerLeft) {
            toRight(item);
          } else {
            untouched.add(item);
          }
        case SyncMode.mirror:
          if (item.diff == SyncDiff.onlyRight) {
            deletes.add(SyncAction(SyncActionKind.deleteRight, item));
          } else {
            toRight(item);
          }
        case SyncMode.twoWay:
          final reason = switch (item.diff) {
            SyncDiff.differentSize || SyncDiff.differentContents => ConflictReason.sameDate,
            SyncDiff.typeClash => ConflictReason.typeClash,
            SyncDiff.newerLeft || SyncDiff.newerRight
                when since != null && item.left!.modified > since && item.right!.modified > since =>
              ConflictReason.bothChanged,
            _ => null,
          };
          if (reason != null) {
            final choice = choices[item.path] ?? ConflictChoice.skip;
            conflicts.add(SyncConflict(item, reason, choice));
            if (choice == ConflictChoice.left) toRight(item);
            if (choice == ConflictChoice.right) toLeft(item);
          } else if (item.diff == SyncDiff.onlyLeft || item.diff == SyncDiff.newerLeft) {
            toRight(item);
          } else {
            toLeft(item);
          }
      }
    }
    return SyncPlan(
      left: comparison.left,
      right: comparison.right,
      mode: mode,
      actions: [...makeWay, ...transfers, ...deletes],
      conflicts: conflicts,
      untouched: untouched,
    );
  }
}

/// How far a sync has come.
class SyncProgress {
  const SyncProgress({
    required this.doneBytes,
    required this.totalBytes,
    required this.doneActions,
    required this.totalActions,
    required this.name,
  });

  final int doneBytes;
  final int totalBytes;
  final int doneActions;
  final int totalActions;

  /// The file being copied or deleted.
  final String name;

  double get fraction {
    if (totalBytes > 0) return (doneBytes / totalBytes).clamp(0.0, 1.0);
    return totalActions == 0 ? 1 : doneActions / totalActions;
  }
}

/// Something a sync couldn't do, and why.
class SyncFailure {
  const SyncFailure(this.path, this.kind, this.reason);

  /// From the compared folders.
  final String path;
  final SyncActionKind kind;
  final String reason;
}

/// What a sync did.
class SyncOutcome {
  const SyncOutcome({
    required this.copied,
    required this.replaced,
    required this.deleted,
    required this.bytes,
    required this.failures,
    required this.cancelled,
  });

  final int copied;
  final int replaced;
  final int deleted;
  final int bytes;
  final List<SyncFailure> failures;
  final bool cancelled;

  /// "12 copied, 3 replaced, 2 deleted", or "Nothing changed".
  String get summary {
    final parts = [
      if (copied > 0) '$copied copied',
      if (replaced > 0) '$replaced replaced',
      if (deleted > 0) '$deleted deleted',
      if (failures.isNotEmpty) "${failures.length} couldn't be synced",
    ];
    return parts.isEmpty ? 'Nothing changed' : parts.join(', ');
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Carries out a [SyncPlan]. Copies stream into a temporary file beside the
/// target, which takes the target's name only once complete, so a failure or
/// Cancel never leaves a half-written file, nor destroys the copy that was
/// there. What a sync deletes, and the older copy a replace takes the place
/// of, goes through the browser's delete ([AppDelete]). Links are never
/// followed or copied.
class FolderSyncRunner {
  FolderSyncRunner(this.plan, {this.onProgress, @visibleForTesting this.tellEvery = const Duration(milliseconds: 100)});

  final SyncPlan plan;
  void Function(SyncProgress progress)? onProgress;

  /// How often [onProgress] hears how far it has come, at most.
  final Duration tellEvery;

  bool _cancelled = false;
  bool get cancelled => _cancelled;

  /// Stops at the next chunk; what's half-copied is removed.
  void cancel() => _cancelled = true;

  var _doneBytes = 0;
  var _doneActions = 0;
  var _name = '';
  final _clock = Stopwatch()..start();
  var _told = -1 << 30;

  void _tell({bool now = false}) {
    final report = onProgress;
    if (report == null) return;
    final at = _clock.elapsedMilliseconds;
    if (at - _told < tellEvery.inMilliseconds && !now) return;
    _told = at;
    report(SyncProgress(
      doneBytes: _doneBytes,
      totalBytes: plan.copyBytes,
      doneActions: _doneActions,
      totalActions: plan.actions.length,
      name: _name,
    ));
  }

  Future<SyncOutcome> run() async {
    var copied = 0;
    var replaced = 0;
    var deleted = 0;
    final failures = <SyncFailure>[];
    // Copies that couldn't make way: not tried.
    final blocked = <String>{};
    var stopped = false;
    _tell(now: true);
    for (final action in plan.actions) {
      if (_cancelled) {
        stopped = true;
        break;
      }
      final item = action.item;
      _name = item.name;
      _tell();
      final startBytes = _doneBytes;
      try {
        if (blocked.contains(item.path)) throw const FileSystemException('A file or folder is in the way');
        switch (action.kind) {
          case SyncActionKind.deleteRight || SyncActionKind.deleteLeft:
            await _delete(action);
            deleted++;
          case _:
            final wasThere = await _transfer(action, failures);
            if (wasThere) {
              replaced++;
            } else {
              copied++;
            }
        }
      } on _Cancelled {
        _doneBytes = startBytes;
        stopped = true;
        break;
      } on Object catch (error) {
        if (action.kind.isDelete) blocked.add(item.path);
        failures.add(SyncFailure(item.path, action.kind, _reason(error)));
      }
      _doneBytes = startBytes + (action.kind.isDelete ? 0 : action.bytes);
      _doneActions++;
      _tell();
    }
    _tell(now: true);
    return SyncOutcome(
      copied: copied,
      replaced: replaced,
      deleted: deleted,
      bytes: _doneBytes,
      failures: failures,
      cancelled: stopped,
    );
  }

  static String _reason(Object error) {
    if (error is FileSystemException) {
      final os = error.osError?.message.trim();
      return os == null || os.isEmpty ? error.message : os;
    }
    return '$error';
  }

  String _sidePath(bool right, String path) => p.join(right ? plan.right : plan.left, path);

  /// Whether what's at [path] is still what the comparison saw, so nothing
  /// changed since is lost.
  static Future<bool> _unchanged(String path, SyncStat? seen) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (seen == null) return type == FileSystemEntityType.notFound;
    if (seen.isFolder) return type == FileSystemEntityType.directory;
    if (type != FileSystemEntityType.file) return false;
    final stat = await File(path).stat();
    return stat.size == seen.size &&
        FolderComparer.compareTimes(stat.modified.millisecondsSinceEpoch, seen.modified) == 0;
  }

  static const _changed = FileSystemException('Changed since the comparison; compare again');

  Future<void> _delete(SyncAction action) async {
    final path = _sidePath(action.kind.onRight, action.item.path);
    if (await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.notFound) return;
    if (!await _unchanged(path, action.target)) throw _changed;
    await AppDelete.delete(path);
  }

  /// Copies the item across; true if it replaced what was there.
  Future<bool> _transfer(SyncAction action, List<SyncFailure> failures) async {
    final toRight = action.kind.onRight;
    final source = _sidePath(!toRight, action.item.path);
    final target = _sidePath(toRight, action.item.path);
    final seen = action.source!;
    if (!await _unchanged(source, seen)) throw _changed;
    final targetType = await FileSystemEntity.type(target, followLinks: false);
    final there = targetType != FileSystemEntityType.notFound;
    if (there) {
      // A replace takes the place of the copy the comparison saw, and only of
      // a file; anything else is in the way.
      if (!action.kind.isReplace || seen.isFolder || !await _unchanged(target, action.target)) throw _changed;
    }
    await Directory(p.dirname(target)).create(recursive: true);
    if (seen.isFolder) {
      await _copyFolder(source, target, action, failures);
    } else {
      await _copyFile(source, target, replace: there);
    }
    return there;
  }

  Future<void> _copyFile(String source, String target, {required bool replace}) async {
    final temporary = FolderComparer.temporaryFor(target);
    await _stream(File(source), File(temporary));
    if (replace) {
      try {
        await AppDelete.delete(target);
      } on Object {
        await _discard(temporary);
        rethrow;
      }
    }
    await File(temporary).rename(target);
  }

  /// A folder that isn't on the other side: filled under a temporary name,
  /// which becomes its own once all is copied. A file inside that can't be
  /// copied is listed, and the rest still goes.
  Future<void> _copyFolder(String source, String target, SyncAction action, List<SyncFailure> failures) async {
    final temporary = FolderComparer.temporaryFor(target);
    try {
      await _fill(Directory(source), Directory(temporary), action.item.path, action.kind, failures);
      if (_cancelled) throw const _Cancelled();
      await Directory(temporary).rename(target);
    } on Object {
      await _discard(temporary);
      rethrow;
    }
  }

  Future<void> _fill(
    Directory source,
    Directory target,
    String path,
    SyncActionKind kind,
    List<SyncFailure> failures,
  ) async {
    await target.create(recursive: true);
    await for (final entry in source.list(followLinks: false)) {
      if (_cancelled) throw const _Cancelled();
      final name = p.basename(entry.path);
      final inside = p.join(path, name);
      if (entry is Directory) {
        await _fill(entry, Directory(p.join(target.path, name)), inside, kind, failures);
      } else if (entry is File) {
        _name = name;
        try {
          await _stream(entry, File(p.join(target.path, name)));
        } on _Cancelled {
          rethrow;
        } on FileSystemException catch (error) {
          failures.add(SyncFailure(inside, kind, _reason(error)));
        }
      }
      // Links: neither followed nor copied.
    }
    MacosFiles.copyMetadata(source.path, target.path);
  }

  /// Copies [source] to [target] a chunk at a time, keeping its modified
  /// time; on Cancel or a failure [target] is removed.
  Future<void> _stream(File source, File target) async {
    final sink = target.openWrite();
    var complete = false;
    try {
      await for (final chunk in source.openRead()) {
        if (_cancelled) throw const _Cancelled();
        sink.add(chunk);
        _doneBytes += chunk.length;
        _tell();
      }
      await sink.close();
      complete = true;
    } finally {
      if (!complete) {
        try {
          await sink.close();
        } on Object {
          // It's removed anyway.
        }
        await _discard(target.path);
      }
    }
    try {
      await target.setLastModified(await source.lastModified());
    } on FileSystemException {
      // Some file systems don't allow it; the copy is still good.
    }
    MacosFiles.copyMetadata(source.path, target.path);
  }

  /// Removes what this sync was writing; never a user's own file.
  static Future<void> _discard(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else if (type != FileSystemEntityType.notFound) {
        await File(path).delete();
      }
    } on FileSystemException {
      // Left behind; the next comparison skips its name.
    }
  }
}

/// A sync going on as a background task: it shows in the progress dock and
/// the Tasks view, can be cancelled from there, and carries on when its
/// screen is left.
class SyncJob {
  SyncJob._(this.plan, this.task, this.runner);

  final SyncPlan plan;
  final BackgroundTask task;
  final FolderSyncRunner runner;
  late final Future<SyncOutcome> outcome;

  /// The sync going on, if any, so its screen can show it again.
  static SyncJob? running;

  /// Starts [plan]; with [pairId], the saved pair hears how it went.
  static SyncJob start(SyncPlan plan, {String? pairId}) {
    final runner = FolderSyncRunner(plan);
    final task = BackgroundTasks.instance.start(
      'Sync "${p.basename(plan.left)}" and "${p.basename(plan.right)}"',
      message: 'Getting ready…',
      headline: 'Sync in progress',
      kind: TaskKind.copy,
      onCancel: runner.cancel,
    );
    final job = SyncJob._(plan, task, runner);
    runner.onProgress = (progress) => task.update(
          progress: progress.fraction,
          message: progress.name.isEmpty ? 'Finishing…' : progress.name,
          detail: progress.totalBytes > 0
              ? '${filesize(progress.doneBytes, 1)}/${filesize(progress.totalBytes, 1)}'
              : '${progress.doneActions}/${progress.totalActions}',
        );
    running = job;
    job.outcome = job._run(pairId);
    return job;
  }

  Future<SyncOutcome> _run(String? pairId) async {
    final started = DateTime.now();
    try {
      final outcome = await runner.run();
      if (outcome.cancelled) {
        BackgroundTasks.instance.cancelled(task);
      } else {
        task.outputs.add(plan.mode == SyncMode.twoWay ? plan.left : plan.right);
        BackgroundTasks.instance.finish(task, message: outcome.summary);
      }
      if (pairId != null) {
        await SyncPairs.recordRun(
          pairId,
          at: started,
          summary: outcome.cancelled ? 'Stopped: ${outcome.summary}' : outcome.summary,
          complete: !outcome.cancelled && outcome.failures.isEmpty,
        );
      }
      return outcome;
    } on Object catch (error) {
      BackgroundTasks.instance.fail(task, '$error');
      rethrow;
    } finally {
      if (identical(running, this)) running = null;
    }
  }
}
