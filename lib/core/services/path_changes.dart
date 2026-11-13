/// Items Folders itself moved, copied or deleted, for what's kept by path
/// (tags): renames, the copy engine's moves and copies, and deletions report
/// here, and whoever keeps something by path listens.
abstract final class PathChanges {
  static final _listeners = <void Function(PathChange change)>[];

  static void addListener(void Function(PathChange change) listener) => _listeners.add(listener);

  static void removeListener(void Function(PathChange change) listener) => _listeners.remove(listener);

  /// [from] is now at [to] (a rename or a move); a folder takes what's inside.
  static void moved(String from, String to) {
    if (from != to) _tell(PathMoved(from, to));
  }

  /// [to] is a copy of [from]; a folder's copy holds copies of what's inside.
  static void copied(String from, String to) {
    if (from != to) _tell(PathCopied(from, to));
  }

  /// [path], and anything inside it, is gone.
  static void deleted(String path) => _tell(PathDeleted(path));

  static void _tell(PathChange change) {
    for (final listener in List.of(_listeners)) {
      try {
        listener(change);
      } catch (_) {
        // One listener's trouble doesn't stop the move being told to others.
      }
    }
  }
}

sealed class PathChange {
  const PathChange();
}

final class PathMoved extends PathChange {
  const PathMoved(this.from, this.to);

  final String from;
  final String to;
}

final class PathCopied extends PathChange {
  const PathCopied(this.from, this.to);

  final String from;
  final String to;
}

final class PathDeleted extends PathChange {
  const PathDeleted(this.path);

  final String path;
}
