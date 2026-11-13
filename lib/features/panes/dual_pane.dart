import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/panes/pane_settings.dart';

/// The folder a browser's [state] is about, if any.
String? pathOfState(FileExplorerState? state) => switch (state) {
      FileExplorerLoaded(:final path) => path,
      FileExplorerLoading(:final path) => path,
      FileExplorerError(:final path) => path,
      _ => null,
    };

/// The folder a browser shows or is opening, if any.
String? pathOfBrowser(FileExplorerBloc? bloc) => pathOfState(bloc?.state);

/// One tab's browsers: the first one, and a second beside it while dual
/// pane is on. Each has its own folder, selection, sort and view; the
/// active one (clicked last, or reached with Tab) gets the keyboard, the
/// sidebar and the preview pane.
class DualPaneController extends ChangeNotifier {
  DualPaneController({bool enabled = false, double ratio = 0.5, String? secondFolder})
      : _enabled = enabled,
        ratio = ValueNotifier(ratio.clamp(minRatio, maxRatio)),
        _secondFolder = secondFolder {
    PaneSettings.instance.addListener(_settingsChanged);
    FocusManager.instance.addListener(_focusChanged);
  }

  /// For a new browser: a window's first tab (and a phone's only browser)
  /// starts as the last browser was left; other tabs start with one pane.
  factory DualPaneController.forBrowser({required bool firstTab}) {
    final settings = PaneSettings.instance;
    if (!firstTab || !settings.dual) return DualPaneController(ratio: settings.ratio);
    final folder = settings.secondFolder;
    return DualPaneController(
      enabled: true,
      ratio: settings.ratio,
      secondFolder: folder != null && _stillThere(folder) ? folder : null,
    );
  }

  static bool _stillThere(String folder) {
    if (ExplorerPaths.isVirtual(folder)) return true;
    try {
      return Directory(folder).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  static const double minRatio = 0.15;
  static const double maxRatio = 0.85;

  /// How the room is shared: the first pane's part of it.
  final ValueNotifier<double> ratio;

  /// Whether two panes were asked for.
  bool get enabled => _enabled;
  bool _enabled;

  /// Whether two panes show now: asked for, and room for both.
  bool get showing => _enabled && _roomForTwo;

  /// Whether the window is wide enough for two panes, and for the preview
  /// pane (set by [DualPaneArea] after each layout).
  bool get roomForTwo => _roomForTwo;
  bool _roomForTwo = false;
  bool get roomForPreview => _roomForPreview;
  bool _roomForPreview = false;

  /// 0 for the first pane, 1 for the second.
  int get active => showing ? _active : 0;
  int _active = 0;

  /// The second pane's folder: where it opens, kept while it's closed.
  String? get secondFolder => _secondFolder;
  String? _secondFolder;

  /// The second pane's keyboard: a scope of its own, so a text field there
  /// that lets go of the keyboard leaves it in that pane.
  final secondScope = FocusScopeNode(debugLabel: 'Second pane');

  FileExplorerBloc? _first;
  FileExplorerBloc? _second;
  BuildContext? _area;

  FileExplorerBloc? get first => _first;
  FileExplorerBloc? get second => _second;

  /// The browser of pane [index] (0 or 1).
  FileExplorerBloc? blocOf(int index) => index == 1 ? _second : _first;

  /// The browser the keyboard and the preview pane follow.
  FileExplorerBloc? get activeBloc => blocOf(active) ?? _first;

  /// Whether the keyboard is in the second pane.
  bool get focusInSecond => secondScope.hasFocus;

  /// The first pane's keyboard node: the nearest one above the panes.
  FocusNode? get _firstKeys {
    final area = _area;
    if (area == null || !area.mounted) return null;
    return Focus.maybeOf(area, createDependency: false);
  }

  void attachArea(BuildContext area, FileExplorerBloc first) {
    _area = area;
    _first = first;
  }

  void detachArea(BuildContext area) {
    if (_area == area) _area = null;
  }

  void attachSecond(FileExplorerBloc bloc) => _second = bloc;

  void detachSecond(FileExplorerBloc bloc) {
    if (_second == bloc) _second = null;
  }

  /// The second pane opened another folder.
  void secondMoved(String folder) {
    _secondFolder = folder;
    _keep();
  }

  /// Told after a layout how much room there is.
  void setRoom({required bool two, required bool preview}) {
    if (two == _roomForTwo && preview == _roomForPreview) return;
    _roomForTwo = two;
    _roomForPreview = preview;
    notifyListeners();
  }

  void setRatio(double value) {
    ratio.value = value.clamp(minRatio, maxRatio);
    _keep();
  }

  void toggle() => _enabled ? close() : open();

  /// Two panes; the second opens where it was last, else on the first
  /// one's folder.
  void open() {
    if (_enabled) return;
    _enabled = true;
    _secondFolder ??= pathOfBrowser(_first);
    notifyListeners();
    _keep();
  }

  /// Back to one pane. The pane in use stays: from the second one, its
  /// folder moves into the first.
  void close() {
    if (!_enabled) return;
    final fromSecond = showing && _active == 1;
    if (fromSecond) {
      final path = pathOfBrowser(_second);
      if (path != null && path != pathOfBrowser(_first)) _first?.add(LoadDirectory(path));
    }
    final hadKeyboard = focusInSecond;
    _enabled = false;
    _active = 0;
    notifyListeners();
    _keep();
    if (hadKeyboard || fromSecond) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focus(0));
    }
  }

  /// Makes pane [index] the active one; with [focus], it gets the keyboard
  /// too (unless it has it already, a text field in it for instance).
  void activate(int index, {bool focus = true}) {
    if (!showing) index = 0;
    if (_active != index) {
      _active = index;
      notifyListeners();
    }
    if (focus) _focus(index);
  }

  void _focus(int index) {
    if (index == 1) {
      if (!secondScope.hasFocus) secondScope.requestFocus();
      return;
    }
    final keys = _firstKeys;
    if (keys == null) return;
    // The first pane's keys are round the second pane and the sidebar too.
    final focus = FocusManager.instance.primaryFocus;
    final inFirst = focus != null && (focus == keys || focus.ancestors.contains(keys)) && !focusInSecond;
    if (!inFirst) keys.requestFocus();
  }

  /// The keyboard moved (a click, Tab, a text field): the pane it's in is
  /// the active one. Menus and dialogs are elsewhere and change nothing.
  void _focusChanged() {
    if (!showing) return;
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return;
    if (focus == secondScope || focus.ancestors.contains(secondScope)) {
      activate(1, focus: false);
      return;
    }
    final keys = _firstKeys;
    if (keys != null && (focus == keys || focus.ancestors.contains(keys))) activate(0, focus: false);
  }

  /// Each pane shows the other's folder.
  void swap() {
    final a = pathOfBrowser(_first);
    final b = pathOfBrowser(_second);
    if (!showing || a == null || b == null || a == b) return;
    _first!.add(LoadDirectory(b));
    _second!.add(LoadDirectory(a));
  }

  /// The preview pane's buttons follow it; its width doesn't matter here.
  bool _preview = PaneSettings.instance.preview;

  void _settingsChanged() {
    if (_preview == PaneSettings.instance.preview) return;
    _preview = PaneSettings.instance.preview;
    notifyListeners();
  }

  void _keep() => PaneSettings.instance.keepLayout(
        dual: _enabled,
        ratio: ratio.value,
        secondFolder: _secondFolder,
      );

  @override
  void dispose() {
    PaneSettings.instance.removeListener(_settingsChanged);
    FocusManager.instance.removeListener(_focusChanged);
    secondScope.dispose();
    ratio.dispose();
    super.dispose();
  }
}

/// Gives a browser's widgets its [DualPaneController].
class DualPanes extends InheritedNotifier<DualPaneController> {
  const DualPanes({super.key, required DualPaneController controller, required super.child})
      : super(notifier: controller);

  /// The controller, rebuilding [context] when it changes.
  static DualPaneController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DualPanes>()?.notifier;

  /// The controller, for callbacks.
  static DualPaneController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DualPanes>()?.notifier;

  /// Which pane [context] is in: 1 in the second one, else 0.
  static int paneOf(BuildContext context) => PaneSlot.read(context)?.index ?? 0;

  /// Whether [context] is in the second pane.
  static bool isSecondPane(BuildContext context) => paneOf(context) == 1;

  /// Whether [context]'s pane is the active one (always, with one pane).
  static bool isActive(BuildContext context) {
    final controller = of(context);
    return controller == null || controller.active == paneOf(context);
  }

  /// [isActive], for callbacks.
  static bool activeNow(BuildContext context) {
    final controller = read(context);
    return controller == null || controller.active == paneOf(context);
  }
}

/// Where a pane is: [index] 0 or 1, its [width], whether two show, and
/// whether it [shared] the room (with another pane or the preview pane).
class PaneSlot extends InheritedWidget {
  const PaneSlot({
    super.key,
    required this.index,
    required this.width,
    required this.dual,
    required this.shared,
    required super.child,
  });

  final int index;
  final double width;
  final bool dual;
  final bool shared;

  /// Whether this pane is the one on the right (the only one, with one).
  bool get rightmost => !dual || index == 1;

  static PaneSlot? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PaneSlot>();

  static PaneSlot? read(BuildContext context) => context.getInheritedWidgetOfExactType<PaneSlot>();

  @override
  bool updateShouldNotify(PaneSlot oldWidget) =>
      oldWidget.index != index ||
      oldWidget.width != width ||
      oldWidget.dual != dual ||
      oldWidget.shared != shared;
}

/// Makes a [DualPaneController] for the browser below and keeps it.
class DualPaneScope extends StatefulWidget {
  const DualPaneScope({super.key, required this.child});

  final Widget child;

  @override
  State<DualPaneScope> createState() => _DualPaneScopeState();
}

class _DualPaneScopeState extends State<DualPaneScope> {
  DualPaneController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller ??= DualPaneController.forBrowser(firstTab: _inFirstTab());
  }

  /// Whether this browser is a window's first tab (or has no tabs).
  bool _inFirstTab() {
    final tabs = ExplorerTabs.instance;
    if (!tabs.enabled) return true;
    final navigator = context.findAncestorStateOfType<NavigatorState>();
    return navigator != null && tabs.tabs.first.navigatorKey.currentState == navigator;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DualPanes(controller: _controller!, child: widget.child);
}
