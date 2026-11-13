/// What a folder opened by [LoadDirectory] does to the browser's history.
enum HistoryStep {
  /// A new visit: it comes after the folder shown, and what was ahead (after
  /// going back) is dropped, as in a web browser.
  record,

  /// Back or Forward: the history stays as it is.
  keep,

  /// Takes the place of the folder shown (Back on a phone that went up a
  /// folder, past the start of the history).
  replace,
}

/// The folders one browser (a tab) showed, for Back and Forward.
class FolderHistory {
  FolderHistory({this.limit = 100});

  /// The most folders kept; the oldest go first.
  final int limit;

  final List<String> _entries = [];
  int _index = -1;

  /// Every folder kept, oldest first, and which one is shown.
  List<String> get entries => List.unmodifiable(_entries);
  int get index => _index;

  String? get current => _index < 0 ? null : _entries[_index];

  bool get canBack => _index > 0;
  bool get canForward => _index >= 0 && _index < _entries.length - 1;

  /// The folders Back goes through, the nearest first.
  List<String> get backEntries => [for (var i = _index - 1; i >= 0; i--) _entries[i]];

  /// The folders Forward goes through, the nearest first.
  List<String> get forwardEntries => [for (var i = _index + 1; i < _entries.length; i++) _entries[i]];

  void apply(String path, HistoryStep step) {
    switch (step) {
      case HistoryStep.record:
        visit(path);
      case HistoryStep.keep:
        break;
      case HistoryStep.replace:
        replace(path);
    }
  }

  /// [path] was opened: it's shown now. Opening the folder already shown (a
  /// refresh) changes nothing.
  void visit(String path) {
    if (current == path) return;
    if (_index < _entries.length - 1) _entries.removeRange(_index + 1, _entries.length);
    _entries.add(path);
    if (_entries.length > limit) _entries.removeRange(0, _entries.length - limit);
    _index = _entries.length - 1;
  }

  /// [path] takes the place of the folder shown.
  void replace(String path) {
    if (_index < 0) return visit(path);
    _entries[_index] = path;
    // Not twice in a row: Back would seem to do nothing.
    if (_index > 0 && _entries[_index - 1] == path) {
      _entries.removeAt(_index);
      _index--;
    }
  }

  /// Moves [steps] folders back (negative) or forward, and gives the folder
  /// to show; null when there's nothing that far.
  String? go(int steps) {
    final to = _index + steps;
    if (steps == 0 || _index < 0 || to < 0 || to >= _entries.length) return null;
    _index = to;
    return _entries[to];
  }

  String? back() => go(-1);
  String? forward() => go(1);
}
