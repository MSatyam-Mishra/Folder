import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:flutter/widgets.dart';

/// One tab of a window: a browser with its own folder, history and screens
/// opened from it.
class ExplorerTab {
  ExplorerTab(this.startFolder) : folder = ValueNotifier(startFolder);

  /// Where the tab opened.
  final String startFolder;

  /// The folder it shows now.
  final ValueNotifier<String> folder;

  /// The tab's own screens: viewers open inside the tab.
  final navigatorKey = GlobalKey<NavigatorState>();

  /// Keeps where the keyboard was in the tab while another one is shown.
  final focusScope = FocusScopeNode(debugLabel: 'Explorer tab');

  String get title => ExplorerPaths.titleForPath(folder.value);

  void dispose() {
    folder.dispose();
    focusScope.dispose();
  }
}

/// The tabs of this window (desktop). Each window is its own process, so
/// there's one list; [enabled] once the window shows tabs.
class ExplorerTabs extends ChangeNotifier {
  ExplorerTabs._();

  static final instance = ExplorerTabs._();

  final List<ExplorerTab> _tabs = [];
  int _active = 0;

  /// Whether the window shows tabs ("Open in new tab" is offered then).
  bool get enabled => _tabs.isNotEmpty;

  List<ExplorerTab> get tabs => List.unmodifiable(_tabs);
  int get activeIndex => _active;
  ExplorerTab? get active => _tabs.isEmpty ? null : _tabs[_active];

  /// The window's first tab, showing [folder].
  void start(String folder) {
    if (_tabs.isEmpty) open(folder);
  }

  /// A new tab for [folder] (home when null), after the current one, or
  /// last when [atEnd]; shown unless [inBackground].
  ExplorerTab open(String? folder, {bool inBackground = false, bool atEnd = false}) {
    final tab = ExplorerTab(folder ?? ExplorerPaths.homePath);
    final index = _tabs.isEmpty || atEnd ? _tabs.length : _active + 1;
    _tabs.insert(index, tab);
    if (!inBackground || _tabs.length == 1) {
      _active = index;
    } else if (index <= _active) {
      _active++;
    }
    notifyListeners();
    return tab;
  }

  void select(int index) {
    if (index < 0 || index >= _tabs.length || index == _active) return;
    _active = index;
    notifyListeners();
  }

  /// The next tab (or the one before, [back]), going round.
  void cycle({bool back = false}) {
    if (_tabs.length < 2) return;
    select((_active + (back ? -1 : 1)) % _tabs.length);
  }

  /// Closes [tab]; false when it was the last one (the window closes then).
  bool close(ExplorerTab tab) {
    final index = _tabs.indexOf(tab);
    if (index < 0) return true;
    if (_tabs.length == 1) return false;
    _tabs.removeAt(index);
    if (index < _active || _active == _tabs.length) _active--;
    notifyListeners();
    // After the frame: the tab's widgets let go of its notifiers first.
    WidgetsBinding.instance.addPostFrameCallback((_) => tab.dispose());
    return true;
  }

  /// Moves the tab at [from] to [to] (dragged along the tab bar).
  void move(int from, int to) {
    if (from == to || from < 0 || to < 0 || from >= _tabs.length || to >= _tabs.length) return;
    final activeTab = _tabs[_active];
    _tabs.insert(to, _tabs.removeAt(from));
    _active = _tabs.indexOf(activeTab);
    notifyListeners();
  }

  /// Forgets every tab (tests).
  @visibleForTesting
  void reset() {
    _tabs.clear();
    _active = 0;
  }
}
