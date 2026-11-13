import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:folders/features/git_status/git_porcelain.dart';
import 'package:path/path.dart' as p;

/// Finds the Git work tree a folder is in and runs `git status` there.
///
/// Costs nothing outside a repo: finding the work tree is a few checks for a
/// `.git` going up from the folder, remembered per folder (for a little
/// while, so a `git init` shows), and git itself only ever runs inside one.
abstract final class GitRepos {
  static final Map<String, ({String? root, DateTime at})> _rootOf = {};
  static const _rootKept = Duration(seconds: 20);

  /// Whether paths differing in case are the same (Windows, macOS).
  static final bool caseSensitive = !(Platform.isWindows || Platform.isMacOS);

  static String _key(String path) => caseSensitive ? path : path.toLowerCase();

  /// The top folder of the work tree [folder] is in; null when it isn't in
  /// one, when it's inside the `.git` folder, or for paths that aren't on
  /// this computer's disks (explorer://...).
  static String? rootOf(String folder) {
    if (folder.isEmpty || folder.contains('://')) return null;
    final start = p.normalize(folder);
    final now = DateTime.now();
    final walked = <String>[];
    String? found;
    var dir = start;
    while (true) {
      final known = _rootOf[_key(dir)];
      if (known != null && now.difference(known.at) < _rootKept) {
        found = known.root;
        break;
      }
      walked.add(dir);
      // A folder or, in linked work trees and submodules, a file.
      final git = FileSystemEntity.typeSync(p.join(dir, '.git'));
      if (git == FileSystemEntityType.directory || git == FileSystemEntityType.file) {
        found = dir;
        break;
      }
      final up = p.dirname(dir);
      if (up == dir) break;
      dir = up;
    }
    for (final folder in walked) {
      _rootOf[_key(folder)] = (root: found, at: now);
    }
    if (_rootOf.length > 4000) _rootOf.clear();
    if (found == null) return null;
    // Git shows nothing about its own folder.
    if (start != found && p.split(p.relative(start, from: found)).contains('.git')) return null;
    return found;
  }

  /// Forgets which folders are in a repo (tests, or after `git init`).
  static void forget() {
    _rootOf.clear();
    _statusOf.clear();
    _slowUntil.clear();
    _available = null;
  }

  static Future<bool>? _available;

  /// Whether git is on the PATH; asked once.
  static Future<bool> gitAvailable() => _available ??= () async {
        try {
          final result = await Process.run('git', ['--version']).timeout(const Duration(seconds: 10));
          return result.exitCode == 0;
        } catch (_) {
          return false;
        }
      }();

  static final Map<String, GitStatus> _statusOf = {};
  static final Map<String, DateTime> _slowUntil = {};

  /// The last status read for [root], if any.
  static GitStatus? cached(String root) => _statusOf[_key(root)];

  /// How long `git status` may take before it's stopped. A repo that took
  /// longer is left alone for a while.
  static Duration timeout = const Duration(seconds: 5);
  static const _slowPause = Duration(minutes: 2);

  /// Runs `git status` in [root], off the UI thread. Null when git is
  /// missing, fails there, or takes too long.
  static Future<GitStatus?> load(String root) async {
    final key = _key(root);
    final slow = _slowUntil[key];
    if (slow != null && DateTime.now().isBefore(slow)) return null;
    if (!await gitAvailable()) return null;
    final limit = timeout;
    final sensitive = caseSensitive;
    final (status, timedOut) = await Isolate.run(() => _status(root, limit, sensitive));
    if (timedOut) _slowUntil[key] = DateTime.now().add(_slowPause);
    if (status == null) {
      _statusOf.remove(key);
    } else {
      _statusOf[key] = status;
    }
    return status;
  }

  static Future<(GitStatus?, bool)> _status(String root, Duration limit, bool caseSensitive) async {
    final Process process;
    try {
      process = await Process.start(
        'git',
        ['status', '--porcelain=v2', '-z', '--branch', '--untracked-files=normal', '--ignored=matching'],
        workingDirectory: root,
        // Never takes the index lock, so the user's own git commands don't trip.
        environment: {'GIT_OPTIONAL_LOCKS': '0', 'GIT_TERMINAL_PROMPT': '0'},
      );
    } catch (e) {
      debugPrint('git status could not start: $e');
      return (null, false);
    }
    final output = process.stdout.fold<BytesBuilder>(BytesBuilder(copy: false), (b, chunk) => b..add(chunk));
    final errors = process.stderr.drain<void>();
    var timedOut = false;
    final code = await process.exitCode.timeout(limit, onTimeout: () {
      timedOut = true;
      process.kill();
      return -1;
    });
    if (timedOut) return (null, true);
    final bytes = (await output).takeBytes();
    await errors;
    if (code != 0) return (null, false);
    return (
      GitStatus.parse(utf8.decode(bytes, allowMalformed: true), root: root, caseSensitive: caseSensitive),
      false,
    );
  }
}
