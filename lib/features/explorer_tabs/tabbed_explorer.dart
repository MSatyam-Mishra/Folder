import 'dart:async';
import 'dart:io';

import 'package:explorer/shared/file_icons/place_icon.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:explorer/features/file_explorere/widgets/file_drag_drop.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:window_manager/window_manager.dart';

final bool _testing = Platform.environment.containsKey('FLUTTER_TEST');

/// The window (desktop): a bar of tabs, each a browser of its own. On
/// Windows the bar is the title bar, with the window's buttons.
class TabbedExplorer extends StatefulWidget {
  const TabbedExplorer({super.key, required this.startFolder});

  /// What the first tab shows.
  final String startFolder;

  /// Whether the window draws its own title bar: Windows, once
  /// [prepareWindow] hid the system's.
  static bool customTitleBar = false;

  /// Hides the system title bar on Windows (before the window shows), so
  /// the tabs take its place.
  static Future<void> prepareWindow() async {
    if (!Platform.isWindows || _testing) return;
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    customTitleBar = true;
  }

  @override
  State<TabbedExplorer> createState() => _TabbedExplorerState();
}

class _TabbedExplorerState extends State<TabbedExplorer> {
  final _tabs = ExplorerTabs.instance;
  ExplorerTab? _titled;

  @override
  void initState() {
    super.initState();
    _tabs.start(widget.startFolder);
    _tabs.addListener(_changed);
    _followTitle();
  }

  @override
  void dispose() {
    _tabs.removeListener(_changed);
    _titled?.folder.removeListener(_setTitle);
    super.dispose();
  }

  void _changed() {
    setState(() {});
    _followTitle();
    // The keyboard goes where it was in the tab now shown.
    final tab = _tabs.active;
    if (tab != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabs.active == tab) tab.focusScope.requestFocus();
      });
    }
  }

  /// The window's title (taskbar, Alt+Tab) is the shown tab's folder.
  void _followTitle() {
    final tab = _tabs.active;
    if (tab == _titled) return;
    _titled?.folder.removeListener(_setTitle);
    _titled = tab?..folder.addListener(_setTitle);
    _setTitle();
  }

  void _setTitle() {
    final tab = _titled;
    if (tab == null || _testing) return;
    unawaited(windowManager.setTitle(Platform.isMacOS ? tab.title : '${tab.title} - Explorer'));
  }

  /// Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+1…9 (Cmd on macOS), wherever the
  /// keyboard is in the tab.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final command = Platform.isMacOS ? keys.isMetaPressed : keys.isControlPressed;
    final key = event.logicalKey;
    if (keys.isControlPressed && key == LogicalKeyboardKey.tab) {
      _tabs.cycle(back: keys.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (!command || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.keyT) {
      _tabs.open(null);
    } else if (key == LogicalKeyboardKey.keyW) {
      closeTab(_tabs.active!);
    } else if (_digits.contains(key)) {
      final n = _digits.indexOf(key) + 1;
      _tabs.select(n == 9 ? _tabs.tabs.length - 1 : n - 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static const _digits = [
    LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
  ];

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs.tabs;
    final active = _tabs.active;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      // The app's text style for the tab names; the tabs' pages have their
      // own Material.
      child: Material(
        color: context.colors.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TabBar(tabs: _tabs),
            Expanded(
              child: IndexedStack(
                index: _tabs.activeIndex,
                sizing: StackFit.expand,
                children: [
                  for (final tab in tabs) _TabPage(key: ObjectKey(tab), tab: tab, shown: tab == active),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Closes [tab], or the window with its last tab.
void closeTab(ExplorerTab tab) {
  if (!ExplorerTabs.instance.close(tab) && !_testing) unawaited(windowManager.close());
}

/// A tab's browser, with its own navigator: what's opened from it stays in
/// the tab.
class _TabPage extends StatefulWidget {
  const _TabPage({super.key, required this.tab, required this.shown});

  final ExplorerTab tab;
  final bool shown;

  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage> {
  final _heroes = MaterialApp.createMaterialHeroController();

  @override
  void initState() {
    super.initState();
    widget.tab.focusScope.descendantsAreTraversable = widget.shown;
  }

  @override
  void didUpdateWidget(_TabPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Tab and Shift+Tab stay in the tab shown.
    widget.tab.focusScope.descendantsAreTraversable = widget.shown;
  }

  @override
  void dispose() {
    _heroes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    return TickerMode(
      enabled: widget.shown,
      child: FocusScope(
        node: tab.focusScope,
        child: HeroControllerScope(
          controller: _heroes,
          child: Navigator(
            key: tab.navigatorKey,
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              settings: settings,
              builder: (_) => FileExplorerScreen(
                initialPath: tab.startFolder,
                onFolderChanged: (folder) => tab.folder.value = folder,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The tabs, a button for a new one and, on Windows, the window's own
/// title bar: room to drag it and its buttons.
class _TabBar extends StatelessWidget {
  const _TabBar({required this.tabs});

  final ExplorerTabs tabs;

  static const double _minTab = 80;
  static const double _maxTab = 240;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final custom = TabbedExplorer.customTitleBar;
    final height = custom ? 40.0 : 36.0;
    final list = tabs.tabs;
    return SizedBox(
      height: height,
      child: ColoredBox(
        color: Color.alphaBlend(colors.muted.withValues(alpha: 0.7), colors.background),
        child: Stack(
          children: [
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Room for the + button and, on Windows, a place to drag
                  // the window by and its three buttons.
                  final reserved = 40 + (custom ? 96 + _buttonsWidth(_buttonsFor(context)) : 8) + 8;
                  final room = (constraints.maxWidth - reserved).clamp(0.0, double.infinity);
                  final width = (room / list.length).clamp(_minTab, _maxTab);
                  final strip = Row(
                    children: [
                      for (final (i, tab) in list.indexed)
                        _TabButton(
                          key: ObjectKey(tab),
                          tab: tab,
                          index: i,
                          width: width,
                          active: i == tabs.activeIndex,
                        ),
                    ],
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (custom && _buttonsFor(context) == _Buttons.mac)
                        const _WindowButtons(leading: true)
                      else
                        const SizedBox(width: 8),
                      SizedBox(
                        width: list.length * width > room ? room : list.length * width,
                        child: list.length * width > room
                            ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: strip)
                            : strip,
                      ),
                      Padding(
                        padding: EdgeInsets.only(top: custom ? 6 : 4, left: 2),
                        child: Align(
                          alignment: Alignment.center,
                          child: AppIconButton(
                            icon: const Icon(LucideIcons.plus, size: 16),
                            tooltip: Platform.isMacOS ? 'New tab (⌘T)' : 'New tab (Ctrl+T)',
                            onPressed: () => tabs.open(null),
                          ),
                        ),
                      ),
                      Expanded(child: custom ? const _DragArea() : const SizedBox.shrink()),
                      if (custom) const _WindowButtons(leading: false),
                    ],
                  );
                },
              ),
            ),
            if (custom) const _TopResizeEdge(),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  const _TabButton({
    super.key,
    required this.tab,
    required this.index,
    required this.width,
    required this.active,
  });

  final ExplorerTab tab;
  final int index;
  final double width;
  final bool active;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hovered = false;
  Timer? _dragHover;

  @override
  void dispose() {
    _dragHover?.cancel();
    super.dispose();
  }

  ExplorerTabs get _tabs => ExplorerTabs.instance;

  /// Dragged along the bar: the tab moves to where the pointer is.
  void _drag(DragUpdateDetails details) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final x = box.globalToLocal(details.globalPosition).dx;
    final steps = x < 0 ? (x / widget.width).floor() : x > widget.width ? (x / widget.width).floor() : 0;
    if (steps == 0) return;
    final to = (widget.index + steps).clamp(0, _tabs.tabs.length - 1);
    _tabs.move(widget.index, to);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = widget.tab;
    final active = widget.active;
    final top = TabbedExplorer.customTitleBar ? 6.0 : 4.0;
    Widget button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        // Pressed, not released: as in File Explorer. The middle button
        // closes.
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton) _tabs.select(widget.index);
          if (event.buttons == kMiddleMouseButton) closeTab(tab);
        },
        child: GestureDetector(
          onHorizontalDragUpdate: _drag,
          child: ValueListenableBuilder<String>(
            valueListenable: tab.folder,
            builder: (context, folder, _) => Tooltip(
              message: ExplorerPaths.isWindowsRoots(folder) ? tab.title : folder,
              waitDuration: const Duration(milliseconds: 600),
              child: Container(
                // The gap to the next tab is part of the width.
                width: widget.width - 2,
                margin: EdgeInsets.only(top: top, right: 2),
                padding: const EdgeInsets.only(left: 10, right: 4),
                decoration: BoxDecoration(
                  color: active
                      ? colors.background
                      : _hovered
                          ? colors.foreground.withValues(alpha: 0.06)
                          : null,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                ),
                child: Row(
                  children: [
                    PlaceIcon(
                      place: Place.of(folder),
                      path: folder,
                      icon: _iconFor(folder),
                      size: 15,
                      color: active ? colors.primary : colors.mutedForeground,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tab.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                          color: active ? colors.foreground : colors.mutedForeground,
                        ),
                      ),
                    ),
                    if (active || _hovered)
                      _TabCloseButton(onPressed: () => closeTab(tab))
                    else
                      const SizedBox(width: 24),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Files dragged over a tab for a moment show it, so they can be
    // dropped in its folder.
    if (nativeDragAndDrop) {
      button = DropRegion(
        formats: const [Formats.fileUri],
        onDropOver: (_) => DropOperation.none,
        onDropEnter: (_) => _dragHover = Timer(
          const Duration(milliseconds: 600),
          () => _tabs.select(_tabs.tabs.indexOf(tab)),
        ),
        onDropLeave: (_) => _dragHover?.cancel(),
        onPerformDrop: (_) async {},
        child: button,
      );
    }
    return button;
  }

  static IconData _iconFor(String folder) {
    if (ExplorerPaths.isWindowsRoots(folder)) return LucideIcons.monitor;
    if (ExplorerPaths.isDriveRoot(folder)) return LucideIcons.hardDrive;
    return LucideIcons.folder;
  }
}

class _TabCloseButton extends StatefulWidget {
  const _TabCloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<_TabCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: Platform.isMacOS ? 'Close tab (⌘W)' : 'Close tab (Ctrl+W)',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: _hovered ? colors.foreground.withValues(alpha: 0.1) : null,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(LucideIcons.x, size: 13, color: colors.mutedForeground),
          ),
        ),
      ),
    );
  }
}

/// A title bar without tabs, for what the window shows instead of them
/// (the Tasks view) when it draws its own ([TabbedExplorer.customTitleBar]).
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!TabbedExplorer.customTitleBar) return const SizedBox.shrink();
    return SizedBox(
      height: 32,
      child: Stack(
        children: [
          const Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _WindowButtons(leading: true),
                Expanded(child: _DragArea()),
                _WindowButtons(leading: false),
              ],
            ),
          ),
          const _TopResizeEdge(),
        ],
      ),
    );
  }
}

/// Empty title bar: drags the window, a double-click maximizes it, a
/// right-click shows the window menu.
class _DragArea extends StatelessWidget {
  const _DragArea();

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTap: () => windowManager.popUpWindowMenu(),
        child: const DragToMoveArea(child: SizedBox.expand()),
      );
}

/// Which window buttons the style draws: Windows 11's, macOS's traffic
/// lights (left), or Ubuntu's round ones (Sweet, Dracula).
enum _Buttons { windows, mac, ubuntu }

_Buttons _buttonsFor(BuildContext context) => switch (context.look.style) {
      AppStyle.macos => _Buttons.mac,
      AppStyle.sweet || AppStyle.dracula => _Buttons.ubuntu,
      _ => _Buttons.windows,
    };

/// Room the buttons take on the bar.
double _buttonsWidth(_Buttons buttons) => switch (buttons) {
      _Buttons.windows => 46.0 * 3,
      _Buttons.mac => 76,
      _Buttons.ubuntu => 24.0 * 3 + 10 * 2 + 16,
    };

/// Whether the window is maximized and has the focus, kept up to date.
class _WindowState extends StatefulWidget {
  const _WindowState({required this.builder});

  final Widget Function(BuildContext context, bool maximized, bool focused) builder;

  @override
  State<_WindowState> createState() => _WindowStateState();
}

class _WindowStateState extends State<_WindowState> with WindowListener {
  bool _maximized = false;
  bool _focused = true;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  void onWindowFocus() => setState(() => _focused = true);

  @override
  void onWindowBlur() => setState(() => _focused = false);

  @override
  Widget build(BuildContext context) => widget.builder(context, _maximized, _focused);
}

// Closing goes through BackgroundMode: work still running keeps going in
// the tray.
Future<void> _toggleMaximize(bool maximized) =>
    maximized ? windowManager.unmaximize() : windowManager.maximize();

/// Minimize, maximize (or restore) and close, drawn as Windows 11 does.
class _CaptionButtons extends StatelessWidget {
  const _CaptionButtons();

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return _WindowState(
      builder: (context, maximized, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WindowCaptionButton.minimize(brightness: brightness, onPressed: windowManager.minimize),
          maximized
              ? WindowCaptionButton.unmaximize(brightness: brightness, onPressed: windowManager.unmaximize)
              : WindowCaptionButton.maximize(brightness: brightness, onPressed: windowManager.maximize),
          WindowCaptionButton.close(brightness: brightness, onPressed: windowManager.close),
        ],
      ),
    );
  }
}

/// macOS's traffic lights: close, minimize, zoom. Grey while the window
/// isn't the active one; their symbols show when the pointer is over them.
class _TrafficLights extends StatefulWidget {
  const _TrafficLights();

  @override
  State<_TrafficLights> createState() => _TrafficLightsState();
}

class _TrafficLightsState extends State<_TrafficLights> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final idle = dark ? const Color(0xFF4D4D4D) : const Color(0xFFD1D1D1);
    Widget light(Color fill, Color edge, Color glyph, IconData icon, VoidCallback onPressed, bool focused) {
      final active = focused || _hovered;
      return GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? fill : idle,
            border: Border.all(color: active ? edge : idle, width: 0.5),
          ),
          child: _hovered ? Icon(icon, size: 8, color: glyph) : null,
        ),
      );
    }

    return _WindowState(
      builder: (context, maximized, focused) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              light(const Color(0xFFFF5F57), const Color(0xFFE2463F), const Color(0xFF4D0000), LucideIcons.x,
                  windowManager.close, focused),
              const SizedBox(width: 8),
              light(const Color(0xFFFEBC2E), const Color(0xFFE1A116), const Color(0xFF995700), LucideIcons.minus,
                  windowManager.minimize, focused),
              const SizedBox(width: 8),
              light(const Color(0xFF28C840), const Color(0xFF12AC28), const Color(0xFF006500),
                  maximized ? LucideIcons.minimize2 : LucideIcons.maximize2, () => _toggleMaximize(maximized), focused),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ubuntu's window buttons (Files, Yaru): round, the close one orange.
class _UbuntuButtons extends StatelessWidget {
  const _UbuntuButtons();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget button(IconData icon, VoidCallback onPressed, {bool close = false}) => _RoundButton(
          icon: icon,
          onPressed: onPressed,
          fill: close ? const Color(0xFFE95420) : colors.foreground.withValues(alpha: 0.1),
          hover: close ? const Color(0xFFF26B3A) : colors.foreground.withValues(alpha: 0.18),
          glyph: close ? Colors.white : colors.foreground,
        );
    return _WindowState(
      builder: (context, maximized, _) => Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button(LucideIcons.minus, windowManager.minimize),
            const SizedBox(width: 10),
            button(maximized ? LucideIcons.copy : LucideIcons.square, () => _toggleMaximize(maximized)),
            const SizedBox(width: 10),
            button(LucideIcons.x, windowManager.close, close: true),
          ],
        ),
      ),
    );
  }
}

class _RoundButton extends StatefulWidget {
  const _RoundButton({
    required this.icon,
    required this.onPressed,
    required this.fill,
    required this.hover,
    required this.glyph,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final Color fill;
  final Color hover;
  final Color glyph;

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: _hovered ? widget.hover : widget.fill),
            child: Icon(widget.icon, size: 12, color: widget.glyph),
          ),
        ),
      );
}

/// The style's window buttons: on the left for macOS's (with [leading]
/// true), on the right for the others.
class _WindowButtons extends StatelessWidget {
  const _WindowButtons({required this.leading});

  final bool leading;

  @override
  Widget build(BuildContext context) {
    final buttons = _buttonsFor(context);
    if (leading != (buttons == _Buttons.mac)) return const SizedBox.shrink();
    return switch (buttons) {
      _Buttons.windows => const _CaptionButtons(),
      _Buttons.mac => const Center(child: _TrafficLights()),
      _Buttons.ubuntu => const Center(child: _UbuntuButtons()),
    };
  }
}

/// The window's top edge resizes it: without the system title bar, its
/// border there is part of the bar.
class _TopResizeEdge extends StatefulWidget {
  const _TopResizeEdge();

  @override
  State<_TopResizeEdge> createState() => _TopResizeEdgeState();
}

class _TopResizeEdgeState extends State<_TopResizeEdge> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Widget _edge(MouseCursor cursor, ResizeEdge edge) => MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => windowManager.startResizing(edge),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_maximized) return const SizedBox.shrink();
    const size = 5.0;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: size,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 12, child: _edge(SystemMouseCursors.resizeUpLeftDownRight, ResizeEdge.topLeft)),
          Expanded(child: _edge(SystemMouseCursors.resizeUpDown, ResizeEdge.top)),
          SizedBox(width: 12, child: _edge(SystemMouseCursors.resizeUpRightDownLeft, ResizeEdge.topRight)),
        ],
      ),
    );
  }
}
