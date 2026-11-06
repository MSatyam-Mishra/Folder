import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:path/path.dart' as p;

/// Whether a name matches what was typed in the search box: anywhere in
/// the name, ignoring case; with * or ? it's a pattern for the whole name
/// ("*.pdf", "IMG_20??*").
class NameMatcher {
  NameMatcher(String query)
      : _query = query.trim().toLowerCase(),
        _pattern = query.contains('*') || query.contains('?')
            ? RegExp(
                '^${query.trim().split('').map((c) => switch (c) {
                      '*' => '.*',
                      '?' => '.',
                      _ => RegExp.escape(c),
                    }).join()}\$',
                caseSensitive: false,
              )
            : null;

  final String _query;
  final RegExp? _pattern;

  bool matches(String name) =>
      _pattern?.hasMatch(name) ?? name.toLowerCase().contains(_query);
}

/// Items inside [root]'s subfolders (not its own items, which the caller
/// already filters) whose names match [query], in batches as they're found.
/// Hidden items are skipped unless [showHidden]. On macOS packages (apps,
/// document packages) can match but aren't searched inside, as in Finder.
/// Stops after [limit] matches, or when the stream is cancelled.
Stream<List<FileSystemEntity>> searchSubfolders(
  String root,
  String query, {
  bool showHidden = false,
  int limit = 2000,
}) {
  final port = ReceivePort();
  Isolate? isolate;
  late final StreamController<List<FileSystemEntity>> controller;
  controller = StreamController(
    onListen: () async {
      isolate = await Isolate.spawn(
        _search,
        (port.sendPort, root, query, showHidden, limit),
      );
      port.listen((message) {
        if (message == null) {
          controller.close();
          port.close();
          return;
        }
        controller.add([
          for (final (path, isDirectory) in message as List<(String, bool)>)
            isDirectory ? Directory(path) : File(path),
        ]);
      });
    },
    onCancel: () {
      isolate?.kill(priority: Isolate.immediate);
      port.close();
    },
  );
  return controller.stream;
}

Future<void> _search((SendPort, String, String, bool, int) args) async {
  final (port, root, query, showHidden, limit) = args;
  final matcher = NameMatcher(query);
  // Goes by the name: no extra I/O per folder.
  final skipPackages = Platform.isMacOS;
  bool searchInside(Directory dir) =>
      !(skipPackages && FileTypes.isMacPackage(dir.path));
  var batch = <(String, bool)>[];
  var sent = DateTime.now();
  var found = 0;
  // Breadth first: nearer items come first.
  final pending = <Directory>[];
  try {
    for (final entity in Directory(root).listSync(followLinks: false)) {
      if (entity is Directory && searchInside(entity) && (showHidden || !LocalFileRepository.isHidden(entity.path))) {
        pending.add(entity);
      }
    }
  } on FileSystemException {
    // Unreadable root: nothing to search.
  }
  for (var i = 0; i < pending.length && found < limit; i++) {
    final List<FileSystemEntity> children;
    try {
      children = pending[i].listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final entity in children) {
      final name = p.basename(entity.path);
      if (!showHidden && LocalFileRepository.isHidden(entity.path)) continue;
      final isDirectory = entity is Directory;
      if (isDirectory && searchInside(entity)) pending.add(entity);
      if (matcher.matches(name)) {
        batch.add((entity.path, isDirectory));
        if (++found >= limit) break;
      }
    }
    final now = DateTime.now();
    if (batch.isNotEmpty && now.difference(sent) > const Duration(milliseconds: 150)) {
      port.send(batch);
      batch = [];
      sent = now;
    }
  }
  if (batch.isNotEmpty) port.send(batch);
  port.send(null);
}
