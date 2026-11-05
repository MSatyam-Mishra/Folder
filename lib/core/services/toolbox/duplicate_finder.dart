import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class DuplicateFile {
  const DuplicateFile(this.path, this.modified);

  final String path;
  final DateTime modified;
}

/// Files with the same contents; [files] has the oldest first, the one kept
/// to begin with.
class DuplicateGroup {
  const DuplicateGroup(this.size, this.files);

  final int size;
  final List<DuplicateFile> files;

  /// What deleting all but one would free.
  int get wasted => size * (files.length - 1);
}

/// How far a search has come.
class DuplicateProgress {
  const DuplicateProgress(this.phase, this.done, this.total);

  final String phase;
  final int done;
  final int total;
}

/// Files are compared by size, then by a hash of their start, and only then
/// by a hash of everything, so most are never read in full.
abstract final class DuplicateFinder {
  static const _startBytes = 64 * 1024;

  static const _skippedFolders = {
    'node_modules',
    r'$Recycle.Bin',
    'System Volume Information',
    'Windows',
    'Program Files',
    'Program Files (x86)',
    'ProgramData',
  };

  /// Finds the duplicates under [root], the biggest savings first. Runs where
  /// it's called; use [DuplicateSearch] to keep the app moving.
  static Future<List<DuplicateGroup>> find(
    String root, {
    void Function(DuplicateProgress progress)? onProgress,
  }) async {
    final bySize = <int, List<File>>{};
    var seen = 0;

    void walk(Directory dir, int depth) {
      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      for (final entry in entries) {
        final name = p.basename(entry.path);
        if (name.startsWith('.')) continue;
        if (entry is Directory) {
          // Android's app folders aren't the user's to tidy.
          final appFolder = depth == 0 && name == 'Android';
          if (!appFolder && !_skippedFolders.contains(name)) walk(entry, depth + 1);
        } else if (entry is File) {
          try {
            final size = entry.lengthSync();
            if (size > 0) (bySize[size] ??= []).add(entry);
          } on FileSystemException {
            continue;
          }
          seen++;
          if (seen % 500 == 0) onProgress?.call(DuplicateProgress('Looking through files', seen, 0));
        }
      }
    }

    walk(Directory(root), 0);

    final candidates = bySize.values.where((files) => files.length > 1).toList();
    final total = candidates.fold<int>(0, (sum, files) => sum + files.length);
    var done = 0;
    final groups = <DuplicateGroup>[];
    for (final sameSize in candidates) {
      final size = sameSize.first.lengthSync();
      final byStart = <String, List<File>>{};
      for (final file in sameSize) {
        final hash = await _hash(file, _startBytes);
        done++;
        if (done % 20 == 0) onProgress?.call(DuplicateProgress('Comparing files', done, total));
        if (hash != null) (byStart[hash] ??= []).add(file);
      }
      for (final sameStart in byStart.values.where((files) => files.length > 1)) {
        // A small file's start was all of it.
        final Map<String, List<File>> byContents;
        if (size <= _startBytes) {
          byContents = {'': sameStart};
        } else {
          byContents = {};
          for (final file in sameStart) {
            final hash = await _hash(file, null);
            if (hash != null) (byContents[hash] ??= []).add(file);
          }
        }
        for (final same in byContents.values.where((files) => files.length > 1)) {
          final files = [for (final file in same) DuplicateFile(file.path, file.lastModifiedSync())]
            ..sort((a, b) => a.modified.compareTo(b.modified));
          groups.add(DuplicateGroup(size, files));
        }
      }
    }
    return groups..sort((a, b) => b.wasted.compareTo(a.wasted));
  }

  static Future<String?> _hash(File file, int? bytes) async {
    try {
      final digest = await sha1.bind(file.openRead(0, bytes)).first;
      return digest.toString();
    } on FileSystemException {
      return null;
    }
  }
}

/// A search in the background, which can be stopped.
class DuplicateSearch {
  DuplicateSearch(this.root, {required this.onProgress});

  final String root;
  final void Function(DuplicateProgress progress) onProgress;

  Isolate? _isolate;
  ReceivePort? _port;
  final _done = Completer<List<DuplicateGroup>?>();

  Future<List<DuplicateGroup>?> start() async {
    final port = _port = ReceivePort();
    port.listen((message) {
      if (message is DuplicateProgress) {
        onProgress(message);
      } else if (message is List<DuplicateGroup>) {
        if (!_done.isCompleted) _done.complete(message);
        port.close();
      } else if (message == null) {
        // It ended without an answer: it failed.
        if (!_done.isCompleted) _done.complete(const []);
        port.close();
      }
    });
    final send = port.sendPort;
    _isolate = await Isolate.spawn(_run, (send, root), onExit: send, onError: send);
    return _done.future;
  }

  static Future<void> _run((SendPort, String) job) async {
    final (send, root) = job;
    Isolate.exit(send, await DuplicateFinder.find(root, onProgress: send.send));
  }

  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    _port?.close();
    if (!_done.isCompleted) _done.complete(null);
  }
}
