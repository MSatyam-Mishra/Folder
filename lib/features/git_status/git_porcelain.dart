/// What Git says about an item in a work tree.
enum GitMark {
  conflicted('!', 'Conflict: both sides changed it', 4),
  modified('M', 'Changed, not staged', 3),
  added('A', 'New, staged', 2),
  renamed('R', 'Renamed, staged', 2),
  staged('S', 'Changed, staged', 2),
  untracked('U', 'New, not tracked by Git', 1),
  ignored('', 'Ignored by Git', 0);

  const GitMark(this.letter, this.label, this.weight);

  /// Shown on the item; ignored items are dimmed instead.
  final String letter;
  final String label;

  /// For a folder's dot, the weightiest change inside wins.
  final int weight;
}

/// One `git status` of a work tree: the branch, and what's changed, new,
/// conflicted or ignored, read from `git status --porcelain=v2 -z --branch`
/// (with `--ignored`). Paths are kept relative to [root], `/`-separated.
class GitStatus {
  GitStatus({
    required this.root,
    required this.caseSensitive,
    this.branch,
    this.commit,
    this.upstream,
    this.ahead = 0,
    this.behind = 0,
    Map<String, GitMark> marks = const {},
    Set<String> ignored = const {},
    Map<String, GitMark> inside = const {},
  })  : _marks = marks,
        _ignored = ignored,
        _inside = inside;

  /// The work tree's top folder.
  final String root;

  /// Whether paths differing in case are different (not on Windows or macOS).
  final bool caseSensitive;

  /// The branch checked out; null when detached (or in an unborn repo
  /// without a name, which Git always gives).
  final String? branch;

  /// The commit checked out; null before the first one.
  final String? commit;
  final String? upstream;

  /// Commits not pushed to [upstream], and not pulled from it.
  final int ahead;
  final int behind;

  final Map<String, GitMark> _marks;
  final Set<String> _ignored;
  final Map<String, GitMark> _inside;

  /// The branch, or the commit's short id when detached.
  String? get label {
    final commit = this.commit;
    return branch ?? (commit == null || commit.length <= 7 ? commit : commit.substring(0, 7));
  }

  /// How many items have a change (ignored ones don't count).
  int get changeCount => _marks.values.where((m) => m != GitMark.ignored).length;

  /// The mark of the item at [path]: its own change, or new or ignored as
  /// part of a new or ignored folder. Null when it's unchanged or outside.
  GitMark? markFor(String path) {
    final rel = relativeKey(path);
    if (rel == null || rel.isEmpty) return null;
    final own = _marks[rel];
    if (own != null) return own;
    if (_ignored.contains(rel)) return GitMark.ignored;
    for (var cut = rel.lastIndexOf('/'); cut > 0; cut = rel.lastIndexOf('/', cut - 1)) {
      final folder = rel.substring(0, cut);
      if (_marks[folder] == GitMark.untracked) return GitMark.untracked;
      if (_ignored.contains(folder)) return GitMark.ignored;
    }
    return null;
  }

  /// The weightiest change inside the folder at [path] (for its dot); null
  /// when nothing inside changed.
  GitMark? insideOf(String path) {
    final rel = relativeKey(path);
    return rel == null ? null : _inside[rel];
  }

  /// [path] relative to [root], `/`-separated (lower case where case doesn't
  /// matter); '' for the root, null outside it.
  String? relativeKey(String path) {
    final top = _fold(_trimEnd(root));
    final full = _fold(_trimEnd(path));
    if (full == top) return '';
    if (full.length <= top.length + 1 || !full.startsWith(top)) return null;
    final sep = full[top.length];
    if (sep != '/' && sep != r'\') return null;
    return full.substring(top.length + 1).replaceAll(r'\', '/');
  }

  String _fold(String path) => caseSensitive ? path : path.toLowerCase();

  static String _trimEnd(String path) {
    var end = path.length;
    // Not a root's own slash ("/" or "C:\").
    while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\') && !(end == 3 && path[1] == ':')) {
      end--;
    }
    return path.substring(0, end);
  }

  /// Reads `git status --porcelain=v2 -z --branch [--ignored]` output.
  static GitStatus parse(String output, {required String root, required bool caseSensitive}) {
    String? branch, commit, upstream;
    var ahead = 0, behind = 0;
    final marks = <String, GitMark>{};
    final ignored = <String>{};
    final inside = <String, GitMark>{};
    String key(String path) {
      var rel = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
      if (!caseSensitive) rel = rel.toLowerCase();
      return rel;
    }

    void note(String rel, GitMark mark) {
      // Every folder above gets a dot.
      for (var cut = rel.lastIndexOf('/'); cut > 0; cut = rel.lastIndexOf('/', cut - 1)) {
        final folder = rel.substring(0, cut);
        final was = inside[folder];
        if (was == null || was.weight < mark.weight) inside[folder] = mark;
      }
    }

    final records = output.split('\x00');
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.isEmpty) continue;
      switch (record[0]) {
        case '#':
          final parts = record.split(' ');
          if (parts.length < 3) break;
          final value = parts.sublist(2).join(' ');
          switch (parts[1]) {
            case 'branch.oid':
              commit = value == '(initial)' ? null : value;
            case 'branch.head':
              branch = value == '(detached)' ? null : value;
            case 'branch.upstream':
              upstream = value;
            case 'branch.ab':
              ahead = int.tryParse(parts[2].replaceFirst('+', '')) ?? 0;
              behind = parts.length > 3 ? int.tryParse(parts[3].replaceFirst('-', '')) ?? 0 : 0;
          }
        case '1':
          final path = _field(record, 8);
          if (path == null) break;
          final mark = _markOf(record.substring(2, 4));
          marks[key(path)] = mark;
          note(key(path), mark);
        case '2':
          final path = _field(record, 9);
          // The path it had before follows as a record of its own.
          final before = i + 1 < records.length ? records[++i] : '';
          if (path == null) break;
          final mark = _markOf(record.substring(2, 4), renamed: true);
          marks[key(path)] = mark;
          note(key(path), mark);
          if (before.isNotEmpty) note(key(before), mark);
        case 'u':
          final path = _field(record, 10);
          if (path == null) break;
          marks[key(path)] = GitMark.conflicted;
          note(key(path), GitMark.conflicted);
        case '?':
          if (record.length < 3) break;
          final rel = key(record.substring(2));
          marks[rel] = GitMark.untracked;
          note(rel, GitMark.untracked);
        case '!':
          if (record.length < 3) break;
          ignored.add(key(record.substring(2)));
      }
    }
    return GitStatus(
      root: root,
      caseSensitive: caseSensitive,
      branch: branch,
      commit: commit,
      upstream: upstream,
      ahead: ahead,
      behind: behind,
      marks: marks,
      ignored: ignored,
      inside: inside,
    );
  }

  /// What's after the first [count] space-separated fields: the path, which
  /// may have spaces of its own.
  static String? _field(String record, int count) {
    var at = 0;
    for (var n = 0; n < count; n++) {
      at = record.indexOf(' ', at);
      if (at < 0) return null;
      at++;
    }
    return at < record.length ? record.substring(at) : null;
  }

  /// From the XY status letters (index, then work tree; '.' unchanged).
  static GitMark _markOf(String xy, {bool renamed = false}) {
    final x = xy[0], y = xy.length > 1 ? xy[1] : '.';
    if (x == 'A') return GitMark.added;
    if (y != '.') return GitMark.modified;
    if (renamed || x == 'R' || x == 'C') return GitMark.renamed;
    return GitMark.staged;
  }
}
