import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:folders/shared/layout/sidebar_width.dart';
import 'package:folders/features/file_explorere/widgets/this_pc_view.dart';
import 'package:folders/features/file_explorere/explorer_zoom.dart';
import 'package:folders/shared/widgets/scrollbar_scroll_view.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/archive_service.dart';
import 'package:folders/core/services/file_action_service.dart';
import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/bloc/grouping.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/features/file_explorere/widgets/explorer_header.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/file_explorere/widgets/file_drag_drop.dart';
import 'package:folders/features/file_explorere/widgets/file_grid_item.dart';
import 'package:folders/features/file_explorere/widgets/file_list_item.dart';
import 'package:folders/features/file_explorere/widgets/file_peek.dart';
import 'package:folders/features/file_explorere/widgets/history_buttons.dart';
import 'package:folders/features/file_explorere/widgets/selection_band.dart';
import 'package:folders/features/file_explorere/widgets/social_tabs.dart';
import 'package:folders/features/file_explorere/widgets/image_actions.dart';
import 'package:folders/features/file_explorere/widgets/inline_rename.dart';
import 'package:folders/features/file_explorere/widgets/item_marks.dart';
import 'package:folders/features/git_status/git_status_controller.dart';
import 'package:folders/features/git_status/git_widgets.dart';
import 'package:folders/features/tags/tag_actions.dart';
import 'package:folders/features/tags/tag_folder_bar.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:folders/features/file_explorere/widgets/new_file_button.dart';
import 'package:folders/features/file_explorere/widgets/paste_bar.dart';
import 'package:folders/features/localsend/screens/localsend_screen.dart';
import 'package:folders/features/network/screens/file_server_screen.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/pane_actions.dart';
import 'package:folders/features/panes/pane_area.dart';
import 'package:folders/features/panes/pane_menu.dart';
import 'package:folders/features/sidebar/bloc/bloc/sidebar_bloc.dart';
import 'package:folders/features/tasks/bloc/task_progress_bloc.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/trash/trash_actions.dart';
import 'package:folders/features/trash/trash_view.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_options_sheet.dart';
import 'package:folders/shared/widgets/main_drawer.dart';
import 'package:folders/shared/widgets/progress_dock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

FileActionsService fileActionsService = FileActionsService();

/// Mouse clicks in the file list (shared by a window's tabs, which are used
/// one at a time): the kind of the last pointer, and what was clicked last,
/// for double-clicks and Shift ranges.
final _clicks = _Clicks();

class _Clicks {
  PointerDeviceKind kind = PointerDeviceKind.touch;

  /// Where the last pointer went down, for menus opened by Control-click.
  Offset position = Offset.zero;
  String? lastPath;
  DateTime lastTime = DateTime(0);

  /// Where a Shift selection starts from.
  String? anchorPath;

  /// The item the arrow keys move on from.
  String? cursorPath;

  void mark(String path) {
    anchorPath = path;
    cursorPath = path;
  }

  /// A mouse clicks like on a desktop (click selects, double-click opens);
  /// touch taps like on a phone (tap opens).
  bool get mouse => kind == PointerDeviceKind.mouse;
}

/// Each browser's items on screen (tabs each have a browser).
final _shownItems = Expando<ShownItems>();

ShownItems _shownIn(FileExplorerBloc bloc) => _shownItems[bloc] ??= ShownItems();

/// Whether the keyboard is in a text field, whose keys are its own.
bool get _typing {
  final context = FocusManager.instance.primaryFocus?.context;
  return context != null &&
      (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
}

/// Ctrl, or Cmd on macOS.
bool get _commandPressed => Platform.isMacOS
    ? HardwareKeyboard.instance.isMetaPressed
    : HardwareKeyboard.instance.isControlPressed;

/// A Control-click on macOS, which right-clicks there (one-button mice,
/// trackpads without secondary click).
bool get _controlClick =>
    Platform.isMacOS && _clicks.mouse && HardwareKeyboard.instance.isControlPressed;

/// Holds the keyboard for the browser's shortcuts. A text field that lets go
/// of the keyboard (a click outside the search box) leaves it with the page's
/// focus scope, above [onKey], where every shortcut would be dead: it's taken
/// back from there.
class _BrowserKeys extends StatefulWidget {
  const _BrowserKeys({required this.onKey, required this.child, this.autofocus = true, this.onPointerDown});

  final KeyEventResult Function(KeyEvent event) onKey;
  final Widget child;

  /// Any button pressed over the browser (the mouse's back and forward).
  final PointerDownEventListener? onPointerDown;

  /// Off for a second pane, which gets the keyboard when it's used.
  final bool autofocus;

  @override
  State<_BrowserKeys> createState() => _BrowserKeysState();
}

class _BrowserKeysState extends State<_BrowserKeys> {
  final _node = FocusNode(debugLabel: 'Browser keys');

  void _takeBack() {
    final scope = _node.enclosingScope;
    if (scope != null && identical(FocusManager.instance.primaryFocus, scope)) {
      _node.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_takeBack);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_takeBack);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        onKeyEvent: (_, event) => widget.onKey(event),
        child: Listener(onPointerDown: widget.onPointerDown == null ? null : _pointerDown, child: widget.child),
      );

  /// The pointer last handled by any browser: with two panes, the second
  /// pane's keys sit inside the first's, and the innermost one (told first)
  /// is the pane the button was pressed in.
  static int? _handledPointer;

  void _pointerDown(PointerDownEvent event) {
    if (_handledPointer == event.pointer) return;
    _handledPointer = event.pointer;
    widget.onPointerDown!(event);
  }
}

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({super.key, this.initialPath, this.onFolderChanged});

  /// The folder to show first; else [ExplorerPaths.initialPath].
  final String? initialPath;

  /// The folder shown changed (a tab's title follows it).
  final ValueChanged<String>? onFolderChanged;

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen>
    with WidgetsBindingObserver {
  // Created once: building the FutureBuilder with a fresh future on every
  // rebuild re-ran the permission check each time.
  late Future<PermissionStatus> _permission = _checkAndRequestPermission();
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from system settings: pick up a newly granted permission.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Computers need no storage permission (and permission_handler has no
    // Linux version).
    if (ExplorerPaths.isDesktop) return;
    if (state == AppLifecycleState.resumed && !_granted) {
      setState(() => _permission = Permission.manageExternalStorage.status);
    }
  }

  @override
  Widget build(BuildContext context) {
    // We use a FutureBuilder to handle the initial permission check.
    return FutureBuilder<PermissionStatus>(
      future: _permission,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(
            backgroundColor: context.colors.background,
            body: const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final status = snapshot.data!;
        _granted = status.isGranted;
        // Handle both standard usage and "manage external storage" scenarios
        if (status.isGranted) {
          return _FileExplorerWithProviders(
            initialPath: widget.initialPath,
            onFolderChanged: widget.onFolderChanged,
          );
        } else {
          return _PermissionDeniedScreen(
            onRequest: () => setState(
              () => _permission = Permission.manageExternalStorage.request(),
            ),
          );
        }
      },
    );
  }

  Future<PermissionStatus> _checkAndRequestPermission() async {
    if (ExplorerPaths.isDesktop) {
      return PermissionStatus.granted;
    }

    var status = await Permission.manageExternalStorage.status;

    // If not granted, request it immediately
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }

    return status;
  }
}

// This widget holds all our BLoCs at the very top.
class _FileExplorerWithProviders extends StatelessWidget {
  const _FileExplorerWithProviders({this.initialPath, this.onFolderChanged});

  final String? initialPath;
  final ValueChanged<String>? onFolderChanged;

  @override
  Widget build(BuildContext context) {
    // Two panes side by side, while asked for (each tab its own).
    return DualPaneScope(child: MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) =>
              FileExplorerBloc(repository: LocalFileRepository())
                ..add(LoadDirectory(initialPath ?? ExplorerPaths.initialPath)),
        ),
        BlocProvider(
          create: (context) => SidebarBloc()..add(LoadSidebarData()),
        ),
        BlocProvider(create: (context) => TaskProgressBloc()),
        BlocProvider(
          create: (context) =>
              ClipboardBloc(taskProgressBloc: context.read<TaskProgressBloc>()),
        ),
      ],
      child: onFolderChanged == null
          ? const _FileExplorerUI()
          : BlocListener<FileExplorerBloc, FileExplorerState>(
              listenWhen: (before, now) => _pathOf(now) != null && _pathOf(now) != _pathOf(before),
              listener: (context, state) => onFolderChanged!(_pathOf(state)!),
              child: const _FileExplorerUI(),
            ),
    ));
  }
}

/// The folder a state is about, if any.
String? _pathOf(FileExplorerState state) => switch (state) {
  FileExplorerLoaded(:final path) => path,
  FileExplorerLoading(:final path) => path,
  FileExplorerError(:final path) => path,
  _ => null,
};

// This is the actual UI, which is now guaranteed to be under all the providers.
class _FileExplorerUI extends StatelessWidget {
  const _FileExplorerUI();

  @override
  Widget build(BuildContext context) {
    // We listen to multiple BLoCs to build the final UI
    final fileExplorerState = context.watch<FileExplorerBloc>().state;
    final clipboardState = context.watch<ClipboardBloc>().state;
    final taskState = context.watch<TaskProgressBloc>().state;

    final path = _pathOf(fileExplorerState);
    final loaded = fileExplorerState is FileExplorerLoaded
        ? fileExplorerState
        : null;
    final bool isSelectionMode = loaded?.isSelectionMode ?? false;
    final String? parentPath = path == null
        ? null
        : ExplorerPaths.parentOf(path);
    // Back walks the history first, then goes up; at the top it leaves.
    final bool canPop = !isSelectionMode && !context.read<FileExplorerBloc>().history.canBack && parentPath == null;

    // Tablets, unfolded foldables and desktops keep navigation docked.
    final bool docked = AdaptiveSplitView.isSplit(context);
    // The second of two panes: its page alone, beside the first one's.
    final second = DualPanes.isSecondPane(context);
    final bool busy = taskState is TaskInProgress;
    final pasteState =
        clipboardState is ClipboardReadyToPaste && !clipboardState.pasted && !busy
        ? clipboardState
        : null;
    final bool canCreate =
        loaded != null && !ExplorerPaths.isVirtual(loaded.path);
    final bool showFab =
        !docked &&
        canCreate &&
        loaded.entities.isNotEmpty &&
        !isSelectionMode &&
        pasteState == null &&
        !busy &&
        // It would float over the name, above the keyboard.
        loaded.renamingPath == null;

    final bottomInset =
        (pasteState != null ? PasteBar.reservedHeight : 0.0) +
        (showFab ? 72.0 : 0) +
        (busy ? 120.0 : 0);

    final body = Stack(
      children: [
        Positioned.fill(
          child: ValueListenableBuilder<double>(
            valueListenable: ExplorerZoom.instance,
            builder: (context, _, _) => _buildFileList(
              context,
              fileExplorerState,
              bottomInset: bottomInset,
              canCreate: canCreate,
            ),
          ),
        ),
        if (pasteState != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
            child: Center(
              child: PasteBar(
                clipboard: pasteState,
                onCancel: () =>
                    context.read<ClipboardBloc>().add(ClearClipboard()),
                onPaste: loaded == null || ExplorerPaths.isVirtual(path!)
                    ? null
                    : () => context.read<ClipboardBloc>().add(
                        PasteFromClipboard(loaded.path),
                      ),
              ),
            ),
          ),
        // Copying, moving and video downloads; can be tucked away.
        // Copies, conversions and downloads (all background tasks).
        const PaneDock(child: ProgressDock()),
      ],
    );

    final page = DockedTopBarScaffold(
      drawer: docked || second ? null : const MainDrawer(),
      topBarBuilder: (scaffoldContext) => _buildDockedTopBar(
        scaffoldContext,
        fileExplorerState: fileExplorerState,
        isSelectionMode: isSelectionMode,
        docked: docked,
        canCreate: canCreate,
      ),
      // Show pasted items, and say why a paste failed.
      body: BlocListener<ClipboardBloc, ClipboardState>(
        listener: (context, state) {
          final current = context.read<FileExplorerBloc>().state;
          if (state is ClipboardPasteSuccess && current is FileExplorerLoaded) {
            context.read<FileExplorerBloc>().add(LoadDirectory(current.path));
          } else if (state is ClipboardPasteFailure && DualPanes.activeNow(context)) {
            // Said once, in the active pane.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text("Couldn't paste: ${state.error}")),
            );
          }
        },
        child: body,
      ),
      floatingActionButton: showFab
          ? AppFab(
              tooltip: 'New',
              icon: LucideIcons.plus,
              onPressed: () => showNewItemSheet(
                context,
                onNewFolder: () => fileActionsService.createFolder(context, loaded.path),
                onNewFile: (kind) => fileActionsService.startNewFile(context, loaded.path, kind),
              ),
            )
          : null,
    );

    // Beside the page: a second pane while dual pane is on, and the preview
    // pane while that's on.
    final panes = second ? page : DualPaneArea(first: page, second: (_) => const _FileExplorerUI());

    // With two panes, Back is for the active one.
    return PanePopScope(
      canPop: canPop,
      onBack: () {
        if (isSelectionMode) {
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
          return;
        }
        final bloc = context.read<FileExplorerBloc>();
        if (!bloc.goBack()) bloc.goUp(replace: true);
      },
      child: _BrowserKeys(
        autofocus: !second,
        onKey: (event) => _onKey(context, event),
        onPointerDown: (event) => context.read<FileExplorerBloc>().sideButton(event.buttons),
        child: docked && !second
            // Its border can be dragged. Each pane paints its own background.
            ? ValueListenableBuilder<double>(
                valueListenable: SidebarWidth.instance,
                builder: (context, width, _) => AdaptiveSplitView(
                  secondaryWidth: math.min(
                    width,
                    math.max(SidebarWidth.min, MediaQuery.sizeOf(context).width / 2),
                  ),
                  // The sidebar draws its own, along its rounded corners.
                  divider: false,
                  onResize: SidebarWidth.instance.set,
                  onResizeReset: () => SidebarWidth.instance.set(SidebarWidth.usual),
                  primary: panes,
                  // What it opens shows in the active pane.
                  secondary: const ActivePaneBloc(child: DockedSidebar(child: MainDrawerContent())),
                ),
              )
            : panes,
      ),
    );
  }

  /// Keyboard shortcuts of desktop file managers.
  KeyEventResult _onKey(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // Typing in a text field: the keys are the field's.
    if (_typing) return KeyEventResult.ignored;
    // The panes' keys (Tab, Shift+F5, Alt+P...), before the others.
    final paneKey = PaneActions.onKey(context, event);
    if (paneKey != null) return paneKey;
    final bloc = context.read<FileExplorerBloc>();
    final state = bloc.state;
    if (state is! FileExplorerLoaded) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final command = _commandPressed;
    final selected = state.selectedItems.toList();
    final single = selected.length == 1 ? selected.single : null;
    final inFolder = !ExplorerPaths.isVirtual(state.path);
    final clipboard = context.read<ClipboardBloc>();
    // This PC's drives and libraries aren't for moving, renaming or deleting.
    final thisPc = ExplorerPaths.isWindowsRoots(state.path);
    // Nor what's in the Trash, which is restored or deleted for good.
    final trash = ExplorerPaths.isTrash(state.path);

    if (command && key == LogicalKeyboardKey.keyA) {
      if (thisPc) return KeyEventResult.ignored;
      bloc.add(SelectAll());
    } else if (command && key == LogicalKeyboardKey.keyC && selected.isNotEmpty) {
      if (trash) return KeyEventResult.ignored;
      clipboard.add(CopyToClipboard(selected));
    } else if (command && key == LogicalKeyboardKey.keyX && selected.isNotEmpty) {
      if (thisPc || trash) return KeyEventResult.ignored;
      clipboard.add(CutToClipboard(selected));
    } else if (command && key == LogicalKeyboardKey.keyV) {
      // On macOS files another app copied are looked at only now.
      if ((clipboard.canPaste || Platform.isMacOS) && inFolder) {
        clipboard.add(PasteFromClipboard(state.path));
      }
    } else if (command && keys.isShiftPressed && key == LogicalKeyboardKey.keyN) {
      if (inFolder) {
        fileActionsService.createFolder(context, state.path);
      }
    } else if (command && key == LogicalKeyboardKey.keyN && Desktop.isDesktop) {
      Desktop.openWindow(folder: state.path);
    } else if ((command && key == LogicalKeyboardKey.keyF) || key == LogicalKeyboardKey.f3) {
      bloc.add(OpenSearch());
    } else if (command &&
        (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd)) {
      ExplorerZoom.instance.step(1);
    } else if (command && (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract)) {
      ExplorerZoom.instance.step(-1);
    } else if (command && (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0)) {
      ExplorerZoom.instance.reset();
    } else if (key == LogicalKeyboardKey.f5 ||
        (command && key == LogicalKeyboardKey.keyR)) {
      bloc.add(LoadDirectory(state.path));
    } else if (key == LogicalKeyboardKey.space && single is File) {
      _peek(context, state, single);
    } else if (key == LogicalKeyboardKey.enter && single != null) {
      if (keys.isAltPressed) {
        fileActionsService.showInfoSheet(single, context);
      } else {
        _open(context, state, single);
      }
    } else if (command && key == LogicalKeyboardKey.keyI && single != null) {
      if (trash) return KeyEventResult.ignored;
      fileActionsService.showInfoSheet(single, context);
    } else if ((key == LogicalKeyboardKey.delete ||
            // ⌘⌫ on macOS, where the delete key is backspace.
            (Platform.isMacOS && command && key == LogicalKeyboardKey.backspace)) &&
        selected.isNotEmpty) {
      if (thisPc) return KeyEventResult.ignored;
      if (trash) {
        TrashActions.deleteForGood(context, TrashListing.itemsOf(selected));
      } else {
        // Shift+Delete, or ⌥⌘⌫ on a Mac: for good, past the Trash.
        fileActionsService.deleteFiles(context, selected,
            permanent: Platform.isMacOS ? keys.isAltPressed : keys.isShiftPressed);
      }
    } else if (key == LogicalKeyboardKey.f2 && single != null) {
      if (thisPc || trash) return KeyEventResult.ignored;
      fileActionsService.showRenameDialog(context, single);
    } else if (key == LogicalKeyboardKey.escape && selected.isNotEmpty) {
      bloc.add(ToggleSelectionMode(enable: false));
    } else if (key == LogicalKeyboardKey.escape && state.searchOpen) {
      bloc.add(CloseSearch());
    } else if ((keys.isAltPressed && key == LogicalKeyboardKey.arrowLeft) ||
        key == LogicalKeyboardKey.browserBack ||
        (Platform.isMacOS && command && key == LogicalKeyboardKey.bracketLeft)) {
      bloc.goBack();
    } else if ((keys.isAltPressed && key == LogicalKeyboardKey.arrowRight) ||
        key == LogicalKeyboardKey.browserForward ||
        (Platform.isMacOS && command && key == LogicalKeyboardKey.bracketRight)) {
      bloc.goForward();
    } else if ((key == LogicalKeyboardKey.backspace && !Platform.isMacOS) ||
        (keys.isAltPressed && key == LogicalKeyboardKey.arrowUp) ||
        // Backspace is the delete key on a Mac.
        (command && key == LogicalKeyboardKey.arrowUp)) {
      final parent = ExplorerPaths.parentOf(state.path);
      if (parent == null) return KeyEventResult.ignored;
      bloc.add(LoadDirectory(parent));
    } else if (thisPc || command || keys.isAltPressed || !_moveCursor(bloc, state, key)) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// The arrow keys, Home, End, Page Up and Page Down go through the items;
  /// with Shift the selection stretches from where it started.
  bool _moveCursor(FileExplorerBloc bloc, FileExplorerLoaded state, LogicalKeyboardKey key) {
    final items = state.displayEntities;
    if (items.isEmpty) return false;
    final shown = _shownIn(bloc);
    final grid = state.viewMode == ViewMode.grid || state.viewMode == ViewMode.gallery;
    final columns = grid ? shown.columns : 1;
    final last = items.length - 1;
    final paths = [for (final e in items) e.path];
    var at = paths.indexOf(_clicks.cursorPath ?? '');
    // Last moved in the other pane: on from what's selected in this one.
    if (at < 0) at = items.indexWhere(state.selectedItems.contains);
    final int? wanted;
    if (key == LogicalKeyboardKey.arrowDown) {
      // On the last row a grid stays put, as there's nothing under it.
      wanted = at < 0 ? 0 : (at + columns > last && at ~/ columns == last ~/ columns ? at : at + columns);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      wanted = at < 0 ? last : (at - columns < 0 ? at : at - columns);
    } else if (grid && key == LogicalKeyboardKey.arrowRight) {
      wanted = at + 1;
    } else if (grid && key == LogicalKeyboardKey.arrowLeft) {
      wanted = at < 0 ? 0 : at - 1;
    } else if (key == LogicalKeyboardKey.home) {
      wanted = 0;
    } else if (key == LogicalKeyboardKey.end) {
      wanted = last;
    } else if (key == LogicalKeyboardKey.pageDown) {
      wanted = at < 0 ? 0 : at + columns * shown.rowsOnPage;
    } else if (key == LogicalKeyboardKey.pageUp) {
      wanted = at < 0 ? 0 : at - columns * shown.rowsOnPage;
    } else {
      wanted = null;
    }
    if (wanted == null) return false;
    final to = wanted.clamp(0, last);
    final target = items[to];
    if (HardwareKeyboard.instance.isShiftPressed) {
      var from = paths.indexOf(_clicks.anchorPath ?? '');
      if (from < 0) {
        from = at < 0 ? to : at;
        _clicks.anchorPath = paths[from];
      }
      _clicks.cursorPath = target.path;
      final range = items.sublist(math.min(from, to), math.max(from, to) + 1).toSet();
      bloc.add(SetSelection(range, selectionMode: range.length > 1));
    } else {
      _clicks.mark(target.path);
      bloc.add(SetSelection({target}));
    }
    shown.reveal(target.path, to, items.length);
    return true;
  }

  Widget _buildDockedTopBar(
    BuildContext context, {
    required FileExplorerState fileExplorerState,
    required bool isSelectionMode,
    required bool docked,
    required bool canCreate,
  }) {
    final bloc = context.read<FileExplorerBloc>();

    if (isSelectionMode && fileExplorerState is FileExplorerLoaded && ExplorerPaths.isTrash(fileExplorerState.path)) {
      final items = TrashListing.itemsOf(fileExplorerState.selectedItems);
      return TrashSelectionHeader(
        count: items.length,
        total: fileExplorerState.visibleEntities.length,
        wide: docked,
        onClose: () => bloc.add(ToggleSelectionMode(enable: false)),
        onSelectAll: () => bloc.add(SelectAll()),
        onRestore: () => TrashActions.restore(context, items),
        onDelete: () => TrashActions.deleteForGood(context, items),
      );
    }
    if (isSelectionMode && fileExplorerState is FileExplorerLoaded) {
      final selected = fileExplorerState.selectedItems.toList();
      void exitSelection() => bloc.add(ToggleSelectionMode(enable: false));
      final images = ImageActions.imagesIn(selected);
      return ExplorerSelectionHeader(
        hasImages: images.isNotEmpty,
        otherPane: PaneActions.canTransfer(context),
        count: selected.length,
        total: fileExplorerState.visibleEntities.length,
        wide: docked,
        onClose: exitSelection,
        onShare: () => fileActionsService.shareMany(context, selected),
        onSendNearby: () {
          exitSelection();
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LocalSendScreen(initialItems: selected),
            ),
          );
        },
        onCompress: () => _handleCompress(context, fileExplorerState),
        onDelete: () => fileActionsService.deleteFiles(context, selected),
        onMenuAction: (action) {
          switch (action) {
            case SelectionMenuAction.selectAll:
              bloc.add(SelectAll());
            case SelectionMenuAction.clear:
              bloc.add(ClearSelection());
            case SelectionMenuAction.copy:
              exitSelection();
              context.read<ClipboardBloc>().add(CopyToClipboard(selected));
            case SelectionMenuAction.cut:
              exitSelection();
              context.read<ClipboardBloc>().add(CutToClipboard(selected));
            case SelectionMenuAction.copyToOtherPane:
              PaneActions.transfer(context, move: false, items: selected);
            case SelectionMenuAction.moveToOtherPane:
              PaneActions.transfer(context, move: true, items: selected);
            case SelectionMenuAction.rename:
              exitSelection();
              fileActionsService.showRenameDialog(context, selected.first);
            case SelectionMenuAction.properties:
              exitSelection();
              fileActionsService.showInfoSheet(selected.first, context);
            case SelectionMenuAction.allActions:
              exitSelection();
              fileActionsService.showFileOptionsMenu(context, selected.first);
            case SelectionMenuAction.convert:
              exitSelection();
              ImageActions.chooseFormat(context, images);
            case SelectionMenuAction.resize:
              exitSelection();
              ImageActions.resize(context, images);
            case SelectionMenuAction.tags:
              TagActions.showPicker(context, [for (final e in selected) e.path]);
          }
        },
      );
    }

    final path = _pathOf(fileExplorerState);
    final loaded = fileExplorerState is FileExplorerLoaded
        ? fileExplorerState
        : null;
    // This PC has one layout: nothing to arrange.
    final thisPc = path != null && ExplorerPaths.isWindowsRoots(path);
    return ExplorerHeader(
      leading: Desktop.isDesktop && docked
          ? HistoryButtons(
              history: bloc.history,
              onGo: bloc.goInHistory,
              onUp: path == null || ExplorerPaths.parentOf(path) == null ? null : () => bloc.goUp(),
            )
          : null,
      crumbs: path == null
          ? const []
          : explorerCrumbs(path, labels: loaded?.pathLabels ?? const {}),
      // A narrow pane beside another one or the preview: the compact one.
      wide: docked && PaneActions.roomyHeader(context),
      statusChip: GitBranchChip(git: GitStatusController.of(bloc)),
      onNavigate: (target) => bloc.add(LoadDirectory(target)),
      onMenuPressed: docked || DualPanes.isSecondPane(context) ? null : () => Scaffold.of(context).openDrawer(),
      toggles: PaneActions.toggles(context),
      viewMode: thisPc ? null : loaded?.viewMode,
      sortOption: thisPc ? null : loaded?.sortOption,
      sortOrder: thisPc ? null : loaded?.sortOrder,
      groupBy: loaded?.groupBy,
      onGroupByChanged: loaded == null ? null : (g) => bloc.add(ChangeGroupBy(g)),
      searchOpen: loaded?.searchOpen ?? false,
      query: loaded?.query ?? '',
      onSearch: loaded == null ? null : () => bloc.add(OpenSearch()),
      onSearchChanged: (q) => bloc.add(SearchChanged(q)),
      onSearchClosed: () => bloc.add(CloseSearch()),
      onViewModeChanged: loaded == null
          ? null
          : (mode) => bloc.add(ChangeViewMode(mode)),
      onSortChanged: loaded == null
          ? null
          : (option, order) => bloc.add(ChangeSortOrder(option, order)),
      onNewFile: canCreate && loaded != null
          ? (kind) => fileActionsService.startNewFile(context, loaded.path, kind)
          : null,
      onNewFolder: canCreate && loaded != null
          ? () =>
                fileActionsService.createFolder(context, loaded.path)
          : null,
      onNewWindow: Desktop.isDesktop && loaded != null
          ? () => Desktop.openWindow(folder: loaded.path)
          : null,
      onOptionsPressed: loaded == null
          ? null
          : () {
              ExplorerOptionsSheet.show(
                context,
                fileState: loaded,
                onHttpShare: () => _handleHttpShare(context, loaded),
                onSortChanged: (SortOption option, SortOrder order) {
                  bloc.add(ChangeSortOrder(option, order));
                },
                onViewModeChanged: (ViewMode mode) {
                  bloc.add(ChangeViewMode(mode));
                },
                onShowHiddenChanged: () => bloc.add(LoadDirectory(loaded.path)),
              );
            },
    );
  }

  Widget _buildFileList(
    BuildContext context,
    FileExplorerState state, {
    required double bottomInset,
    required bool canCreate,
  }) {
    final path = switch (state) {
      FileExplorerLoaded(:final path) => path,
      FileExplorerLoading(:final path) => path,
      FileExplorerError(:final path) => path,
      _ => null,
    };
    if (path != null && (TagPaths.isTag(path) || ExplorerPaths.isTrash(path))) {
      // A tag's items, under the tag with its Rename and Delete; or the
      // Trash, with how long things stay and Empty above what's in it.
      final tag = TagPaths.isTag(path);
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildFolder(
            context,
            state,
            bottomInset: bottomInset,
            canCreate: canCreate,
            extraTop: tag ? TagFolderBar.height : TrashBar.height,
          ),
          Positioned(
            top: DockedGlossyTopBar.contentTopInset(context),
            left: 0,
            right: 0,
            child: tag
                ? TagFolderBar(path: path)
                : TrashBar(count: state is FileExplorerLoaded ? state.entities.length : 0),
          ),
        ],
      );
    }
    if (path == null || !ExplorerPaths.isSocial(path)) {
      return _buildFolder(context, state, bottomInset: bottomInset, canCreate: canCreate);
    }
    // An app's files (WhatsApp...): its tabs stay above them.
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildFolder(context, state, bottomInset: bottomInset, canCreate: canCreate, extraTop: SocialTabs.height),
        Positioned(
          top: DockedGlossyTopBar.contentTopInset(context),
          left: 0,
          right: 0,
          child: SocialTabs(path: path),
        ),
      ],
    );
  }

  Widget _buildFolder(
    BuildContext context,
    FileExplorerState state, {
    required double bottomInset,
    required bool canCreate,
    double extraTop = 0,
  }) {
    final topInset = DockedGlossyTopBar.contentTopInset(context) + extraTop;
    final bottom = MediaQuery.paddingOf(context).bottom + 16 + bottomInset;
    final statePadding = EdgeInsets.fromLTRB(24, topInset + 24, 24, bottom);

    if (state is FileExplorerLoading || state is FileExplorerInitial) {
      return _DelayedReveal(child: _ListSkeleton(top: topInset + 8));
    }
    if (state is FileExplorerError) {
      final parent = state.path == null
          ? null
          : ExplorerPaths.parentOf(state.path!);
      final bloc = context.read<FileExplorerBloc>();
      return ExplorerEmptyState(
        padding: statePadding,
        destructive: true,
        icon: LucideIcons.folderX,
        title: "Can't open this folder",
        description: _friendlyError(state.message),
        actions: [
          if (parent != null)
            OutlinedButton.icon(
              onPressed: () => bloc.add(LoadDirectory(parent)),
              icon: const Icon(LucideIcons.arrowLeft, size: 16),
              label: const Text('Go back'),
            ),
          FilledButton.icon(
            onPressed: () => bloc.add(
              LoadDirectory(state.path ?? ExplorerPaths.initialPath),
            ),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('Try again'),
          ),
        ],
      );
    }
    if (state is FileExplorerLoaded) {
      if (state.query.isNotEmpty && state.searchResults.isEmpty) {
        return state.searching
            ? Padding(
                padding: EdgeInsets.only(top: topInset),
                child: const _Searching(),
              )
            : ExplorerEmptyState(
                padding: statePadding,
                icon: LucideIcons.searchX,
                title: 'Nothing matches “${state.query}”',
                description: 'Nothing here or in the folders inside has that '
                    'name. Use * for any text, as in *.pdf.',
              );
      }
      if (state.entities.isEmpty) {
        if (ExplorerPaths.isTrash(state.path)) {
          final open = Trash.instance.openInSystem;
          return ExplorerEmptyState(
            padding: statePadding,
            icon: LucideIcons.trash2,
            title: 'The ${ExplorerPaths.titleForPath(state.path)} is empty',
            description: Platform.isMacOS
                ? 'What Folders moves to the Trash shows here. Finder shows the rest.'
                : 'What you delete goes here first, so you can get it back.',
            actions: [
              if (open != null)
                OutlinedButton.icon(
                  onPressed: open,
                  icon: const Icon(LucideIcons.squareArrowOutUpRight, size: 16),
                  label: Text(Platform.isMacOS ? 'Open in Finder' : 'Open in File Explorer'),
                ),
            ],
          );
        }
        if (ExplorerPaths.isSocial(state.path)) {
          return ExplorerEmptyState(
            padding: statePadding,
            icon: LucideIcons.folderOpen,
            title: 'No files here yet',
            description: 'Photos, videos and documents this app saves on this device show up here.',
          );
        }
        return ExplorerEmptyState(
          padding: statePadding,
          icon: LucideIcons.folderOpen,
          title: 'This folder is empty',
          description: canCreate
              ? 'Create a folder or a file, or copy files here from another folder.'
              : 'There is nothing to show here.',
          actions: [
            if (canCreate)
              OutlinedButton.icon(
                onPressed: () => fileActionsService.createFolder(
                  context,
                  state.path,
                ),
                icon: const Icon(LucideIcons.folderPlus, size: 16),
                label: const Text('New folder'),
              ),
            // A docked layout has the + in its header.
            if (canCreate && !AdaptiveSplitView.isSplit(context))
              OutlinedButton.icon(
                onPressed: () => showNewItemSheet(
                  context,
                  onNewFile: (kind) => fileActionsService.startNewFile(context, state.path, kind),
                ),
                icon: const Icon(LucideIcons.filePlus, size: 16),
                label: const Text('New file'),
              ),
          ],
        );
      }

      return LayoutBuilder(
        builder: (context, constraints) => _buildEntries(
          context,
          state,
          width: constraints.maxWidth,
          top: topInset,
          bottom: bottom,
        ),
      );
    }
    return ExplorerEmptyState(
      padding: statePadding,
      icon: LucideIcons.circleAlert,
      title: 'Something went wrong',
    );
  }

  Widget _buildEntries(
    BuildContext context,
    FileExplorerLoaded state, {
    required double width,
    required double top,
    required double bottom,
  }) {
    final wide = width >= 720;
    final entities = state.visibleEntities;
    final groups = state.groups.isEmpty ? [EntityGroup('', entities)] : state.groups;
    final bloc = context.read<FileExplorerBloc>();
    final searching = state.query.isNotEmpty;
    // Git's marks on the items, in a work tree (computers).
    final git = GitStatusController.of(bloc);

    /// Where a search result from a subfolder is, from here.
    String? locationOf(FileSystemEntity e) {
      final dir = p.dirname(e.path);
      if (ExplorerPaths.isTrash(state.path)) return TrashListing.itemAt(e.path)?.originalFolder;
      if (ExplorerPaths.isCategory(state.path) || ExplorerPaths.isSocial(state.path) || TagPaths.isTag(state.path)) {
        return p.basename(dir);
      }
      if (!searching) return null;
      return p.equals(dir, state.path) ? null : p.relative(dir, from: state.path);
    }

    void onTap(FileSystemEntity e) {
      if (e.path == state.renamingPath) return;
      if (_controlClick) {
        _showItemMenu(context, state, e, _clicks.position);
      } else if (_clicks.mouse) {
        _handleClick(context, state, e);
      } else {
        _handleTap(context, state, e);
      }
    }
    void onLongPress(FileSystemEntity e) {
      if (e.path != state.renamingPath) _handleLongPress(context, state, e);
    }

    /// Phones: a double tap on a file's picture is a quick look at it.
    VoidCallback? onPeek(FileSystemEntity e) => !Desktop.isDesktop && e is File && !state.isSelectionMode
        ? () => _peek(context, state, e)
        : null;

    /// The name's editor, on the item being renamed.
    Widget? nameEditor(FileSystemEntity e, {bool centered = false}) => e.path == state.renamingPath
        ? InlineRename(
            key: ValueKey(e.path),
            name: p.basename(e.path),
            centered: centered,
            onDone: (name) => fileActionsService.finishRename(context, e, name),
          )
        : null;
    GestureTapUpCallback? onSecondaryTap(FileSystemEntity e) {
      if (Desktop.isDesktop) {
        return (details) =>
            _showItemMenu(context, state, e, details.globalPosition);
      }
      return state.isSelectionMode
          ? null
          : (_) => ExplorerPaths.isTrash(state.path)
              ? _open(context, state, e)
              : fileActionsService.showFileOptionsMenu(context, e);
    }

    final footer = SliverToBoxAdapter(
      child: searching
          ? (state.searching
              ? const _Searching()
              : _SearchSummary(count: entities.length))
          : _FolderSummary(entities: entities),
    );
    Widget heading(EntityGroup group, double side) => SliverToBoxAdapter(
          child: _GroupHeading(group: group, side: side),
        );

    void drop(List<String> paths, String folder, bool move) =>
        context.read<ClipboardBloc>().add(TransferFiles(paths, folder, move: move));

    final shown = _shownIn(bloc)
      ..top = top
      ..bottom = bottom;
    // A new folder may have landed out of view.
    final renaming = state.renamingPath;
    if (renaming != shown.revealedRename) {
      shown.revealedRename = renaming;
      if (renaming != null) {
        _clicks.mark(renaming);
        final index = state.displayEntities.indexWhere((e) => e.path == renaming);
        if (index >= 0) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => shown.reveal(renaming, index, state.displayEntities.length),
          );
        }
      }
    }

    // Every item can be dragged (with the rest of the selection); folders
    // take drops, but not macOS packages (apps), which would be damaged.
    // With tabs, the middle button opens a folder in a new one, behind.
    Widget dragAndDrop(FileSystemEntity entity, Widget item) {
      // Nothing is dragged out of the Trash or dropped into it.
      final inTrash = ExplorerPaths.isTrash(state.path);
      final folder = entity is Directory && !FileActionsService.isPackage(entity) && !inTrash;
      final target = folder
          ? FileDropTarget(
              folder: entity.path,
              onDrop: (paths, move) => drop(paths, entity.path, move),
              builder: (context, hovering) => Listener(
                onPointerDown: (event) {
                  if (event.buttons == kMiddleMouseButton && ExplorerTabs.instance.enabled) {
                    ExplorerTabs.instance.open(entity.path, inBackground: true);
                  }
                },
                child: DropHighlight(active: hovering, child: item),
              ),
            )
          : item;
      return ShownItem(
        items: shown,
        entity: entity,
        child: GitDim(git: git, path: entity.path, child: FileDragSource(
          entity: entity,
          draggable: entity.path != state.renamingPath && !inTrash,
          selection: () => state.selectedItems.contains(entity)
              ? [for (final e in state.displayEntities) if (state.selectedItems.contains(e)) e]
              : const [],
          child: target,
        )),
      );
    }

    final zoom = ExplorerZoom.instance.value;
    final List<Widget> slivers;
    if (ExplorerPaths.isWindowsRoots(state.path)) {
      slivers = [
        ...thisPcSlivers(
          entities: entities,
          labelOf: state.labelFor,
          isSelected: state.selectedItems.contains,
          top: top,
          zoom: zoom,
          onTap: onTap,
          onSecondaryTap: onSecondaryTap,
          // Files can be dropped on them; they aren't dragged away.
          wrap: (entity, item) => FileDropTarget(
            folder: entity.path,
            onDrop: (paths, move) => drop(paths, entity.path, move),
            builder: (context, hovering) => DropHighlight(active: hovering, child: item),
          ),
        ),
        if (searching) footer,
      ];
    } else if (state.viewMode == ViewMode.grid || state.viewMode == ViewMode.gallery) {
      final gallery = state.viewMode == ViewMode.gallery;
      final pad = wide ? 24.0 : 16.0;
      final spacing = wide ? 12.0 : 10.0;
      slivers = [
        SliverToBoxAdapter(child: SizedBox(height: top + pad - 4)),
        for (final group in groups) ...[
        if (group.label.isNotEmpty) heading(group, pad),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, group.label.isEmpty ? 0 : 12),
          sliver: SliverGrid(
            // Column count follows the window width (phones ≈3, tablets 6+).
            gridDelegate: ZoomedGridDelegate(
              maxTile: gallery ? (wide ? 200 : 180) : (wide ? 144 : 128),
              aspectRatio: 0.84,
              spacing: spacing,
              zoom: zoom,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final entity = group.entities[index];
              return dragAndDrop(entity, FileGridItem(
                entity: entity,
                displayName: state.labelFor(entity),
                gallery: gallery,
                zoom: zoom,
                isSelectionMode: state.isSelectionMode,
                isSelected: state.selectedItems.contains(entity),
                onTap: () => onTap(entity),
                onLongPress: () => onLongPress(entity),
                onSecondaryTapUp: onSecondaryTap(entity),
                nameEditor: nameEditor(entity, centered: true),
                onPeek: onPeek(entity),
                marks: ItemMarks(path: entity.path, git: git, gap: 0),
              ));
            }, childCount: group.entities.length),
          ),
        ),
        ],
        footer,
      ];
    } else {
      final style = state.viewMode == ViewMode.compact
          ? FileRowStyle.compact
          : wide
          ? FileRowStyle.table
          : FileRowStyle.comfortable;
      final sidePad = wide ? 8.0 : 0.0;
      slivers = [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(sidePad, top + 8, sidePad, 0),
          sliver: SliverList.list(
            children: [
              if (style == FileRowStyle.table)
                FileTableHeader(
                  sortOption: state.sortOption,
                  sortOrder: state.sortOrder,
                  showSelectionColumn: state.isSelectionMode,
                  onSort: (option, order) =>
                      bloc.add(ChangeSortOrder(option, order)),
                ),
            ],
          ),
        ),
        for (final group in groups) ...[
        if (group.label.isNotEmpty) heading(group, sidePad + 8),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: sidePad),
          sliver: SliverFixedExtentList(
            itemExtent: FileListItem.heightFor(style, zoom) + 2,
            delegate: SliverChildBuilderDelegate((context, index) {
              final entity = group.entities[index];
              return dragAndDrop(entity, FileListItem(
                entity: entity,
                displayName: state.labelFor(entity),
                location: locationOf(entity),
                style: style,
                zoom: zoom,
                isSelectionMode: state.isSelectionMode,
                isSelected: state.selectedItems.contains(entity),
                onTap: () => onTap(entity),
                onLongPress: () => onLongPress(entity),
                onSecondaryTapUp: onSecondaryTap(entity),
                nameEditor: nameEditor(entity),
                onPeek: onPeek(entity),
                marks: ItemMarks(path: entity.path, git: git),
              ));
            }, childCount: group.entities.length),
          ),
        ),
        ],
        footer,
      ];
    }

    final scroller = ScrollbarScrollView(
      // Remembers each folder's scroll position when coming back up.
      storageKey: 'explorer:${state.path}',
      // Ctrl+wheel zooms instead (ZoomGestures below).
      physics: const ZoomKeyScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      ),
      slivers: [
        ...slivers,
        SliverToBoxAdapter(child: SizedBox(height: bottom)),
      ],
    );
    // Dropped on the space around the items: into this folder.
    final list = ExplorerPaths.isVirtual(state.path)
        ? scroller
        : FileDropTarget(
            folder: state.path,
            onDrop: (paths, move) => drop(paths, state.path, move),
            builder: (context, hovering) =>
                DropHighlight(active: hovering, radius: 0, child: scroller),
          );
    return ZoomGestures(child: Builder(builder: (context) => Listener(
      // Before the item's tap fires: was it a mouse or a finger, and where?
      // A click also gives the list the keyboard (Ctrl+A, the arrow keys).
      onPointerDown: (event) {
        _clicks
          ..kind = event.kind
          ..position = event.position;
        Focus.maybeOf(context)?.requestFocus();
      },
      child: GestureDetector(
        // Only where no item took the click: the space around them.
        onTap: () {
          if (_controlClick) {
            _showFolderMenu(context, state, _clicks.position);
          } else if (_clicks.mouse && state.selectedItems.isNotEmpty) {
            bloc.add(ToggleSelectionMode(enable: false));
          }
        },
        onSecondaryTapUp: Desktop.isDesktop
            ? (details) =>
                _showFolderMenu(context, state, details.globalPosition)
            : null,
        child: Desktop.isDesktop && !ExplorerPaths.isWindowsRoots(state.path)
            ? SelectionBand(
                items: shown,
                selected: () => state.selectedItems,
                onChanged: (items, {required done}) {
                  if (done) {
                    final first = state.displayEntities.where(items.contains).firstOrNull;
                    if (first != null) _clicks.mark(first.path);
                  }
                  bloc.add(SetSelection(
                    items,
                    // The checkboxes come in afterwards, not under the band.
                    selectionMode: done ? items.length > 1 : state.isSelectionMode,
                  ));
                },
                child: list,
              )
            : list,
      ),
    )));
  }

  /// Opens a folder or file, as a tap does. macOS packages (apps, document
  /// packages) and installers open with the system, as in Finder.
  Future<void> _open(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) async {
    final bloc = context.read<FileExplorerBloc>();
    // In the Trash: its details, to restore or delete for good.
    if (ExplorerPaths.isTrash(state.path)) {
      final item = TrashListing.itemAt(entity.path);
      if (item != null) await TrashActions.showItemSheet(context, item);
      return;
    }
    if (entity is Directory && !FileActionsService.isPackage(entity)) {
      bloc.add(LoadDirectory(entity.path));
      return;
    }
    if (state.selectedItems.isNotEmpty) {
      bloc.add(ToggleSelectionMode(enable: false));
    }
    if (FileActionsService.opensWithMac(entity)) {
      return fileActionsService.openPackage(context, entity);
    }
    final result = await FileOpener.open(context, entity as File);
    // Only re-list when the viewer changed the folder (saved a copy...).
    if (result == true && !bloc.isClosed) {
      bloc.add(LoadDirectory(state.path));
    }
  }

  void _peek(BuildContext context, FileExplorerLoaded state, File file) {
    showFilePeek(
      context,
      file,
      onOpen: () => _open(context, state, file),
      onShare: () => fileActionsService.shareMany(context, [file]),
    );
  }

  /// A mouse click, as desktop file managers handle it: click selects,
  /// double-click opens, Ctrl (Cmd) adds or removes, Shift selects a range.
  void _handleClick(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) {
    final bloc = context.read<FileExplorerBloc>();
    final keys = HardwareKeyboard.instance;
    final now = DateTime.now();
    final isDouble = _clicks.lastPath == entity.path &&
        now.difference(_clicks.lastTime) <= kDoubleTapTimeout;
    _clicks
      ..lastPath = entity.path
      ..lastTime = now;

    if (isDouble && !_commandPressed && !keys.isShiftPressed) {
      _clicks.lastPath = null;
      _open(context, state, entity);
      return;
    }
    if (ExplorerPaths.isWindowsRoots(state.path)) {
      bloc.add(SetSelection({entity}));
      return;
    }
    if (_commandPressed) {
      final items = {...state.selectedItems};
      if (!items.remove(entity)) items.add(entity);
      _clicks.mark(entity.path);
      bloc.add(SetSelection(items, selectionMode: items.length > 1));
      return;
    }
    // The checkboxes are showing: a click ticks or unticks, the others stay.
    if (state.isSelectionMode && !keys.isShiftPressed) {
      final items = {...state.selectedItems};
      if (!items.remove(entity)) items.add(entity);
      _clicks.mark(entity.path);
      bloc.add(SetSelection(items, selectionMode: items.isNotEmpty));
      return;
    }
    final anchor = _clicks.anchorPath;
    if (keys.isShiftPressed && anchor != null) {
      final shown = state.displayEntities;
      final paths = [for (final e in shown) e.path];
      final from = paths.indexOf(anchor);
      final to = paths.indexOf(entity.path);
      if (from >= 0 && to >= 0) {
        final range = shown
            .sublist(math.min(from, to), math.max(from, to) + 1)
            .toSet();
        _clicks.cursorPath = entity.path;
        bloc.add(SetSelection(range, selectionMode: range.length > 1));
        return;
      }
    }
    _clicks.mark(entity.path);
    bloc.add(SetSelection({entity}));
  }

  /// Right-click on an item: its menu, or the selection's when it's part of
  /// a selection of several.
  void _showItemMenu(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
    Offset position,
  ) {
    final selected = state.selectedItems;
    final ofSelection = selected.length > 1 && selected.any((e) => e.path == entity.path);
    if (ExplorerPaths.isTrash(state.path)) {
      if (!ofSelection) {
        _clicks.mark(entity.path);
        context.read<FileExplorerBloc>().add(SetSelection({entity}));
      }
      TrashActions.showItemMenu(context, TrashListing.itemsOf(ofSelection ? selected : {entity}), position);
      return;
    }
    if (ofSelection) {
      _showSelectionMenu(context, state, position);
      return;
    }
    _clicks.mark(entity.path);
    context.read<FileExplorerBloc>().add(SetSelection({entity}));
    final bloc = context.read<FileExplorerBloc>();
    final thisPc = ExplorerPaths.isWindowsRoots(state.path);
    fileActionsService.showContextMenu(
      context,
      entity,
      position,
      protected: thisPc,
      // From a category or a search of subfolders: where it really is.
      onShowInFolder: !thisPc && !p.equals(p.dirname(entity.path), state.path)
          ? () => bloc.add(LoadDirectory(p.dirname(entity.path)))
          : null,
      onOpen: () => _open(context, state, entity),
      onShowContents: () =>
          context.read<FileExplorerBloc>().add(LoadDirectory(entity.path)),
      extras: thisPc ? const [] : PaneActions.menuActions(context, [entity]),
    );
  }

  Future<void> _showSelectionMenu(
    BuildContext context,
    FileExplorerLoaded state,
    Offset position,
  ) async {
    final bloc = context.read<FileExplorerBloc>();
    final selected = state.selectedItems.toList();
    final images = ImageActions.imagesIn(selected);
    final imageEntries = images.isEmpty ? const <PopupMenuEntry<Object>>[] : await ImageActions.menuEntries(context, images);
    if (!context.mounted) return;
    final paths = [for (final e in selected) e.path];
    final tagEntry = await TagActions.menuEntry(context, paths);
    if (!context.mounted) return;
    final action = await ExplorerMenu.showAt<Object>(
      context,
      position,
      items: [
        ExplorerMenu.label(context, '${selected.length} selected'),
        ExplorerMenu.item(context,
            value: 'copy',
            label: 'Copy',
            icon: LucideIcons.copy,
            shortcut: FileActionsService.shortcut('C')),
        ExplorerMenu.item(context,
            value: 'cut',
            label: 'Cut',
            icon: LucideIcons.scissors,
            shortcut: FileActionsService.shortcut('X')),
        ...PaneActions.menuEntries(context, selected),
        ExplorerMenu.divider(),
        if (imageEntries.isNotEmpty) ...[
          ...imageEntries,
          ExplorerMenu.divider(),
        ],
        ?tagEntry,
        fileActionsService.shareSubmenu(context, selected),
        ExplorerMenu.item(context,
            value: 'zip',
            label: 'Compress to ZIP',
            icon: LucideIcons.fileArchive),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'all',
            label: 'Select all',
            icon: LucideIcons.listChecks,
            shortcut: FileActionsService.shortcut('A')),
        ExplorerMenu.item(context,
            value: 'none', label: 'Clear selection', icon: LucideIcons.x),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'delete',
            label: 'Delete',
            icon: LucideIcons.trash2,
            destructive: true,
            shortcut: FileActionsService.deleteShortcut),
        if (selected.every((e) => Trash.instance.canTrash(e.path)))
          ExplorerMenu.item(context,
              value: 'forGood',
              label: 'Delete for good',
              icon: LucideIcons.fileX,
              destructive: true,
              shortcut: FileActionsService.deleteForGoodShortcut),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action is PaneMenuAction) return action.run();
    if (action is ShareMethod) {
      return fileActionsService.shareVia(context, action, selected);
    }
    if (await ImageActions.handle(context, action, images) || !context.mounted) return;
    if (await TagActions.handle(context, action, paths) || !context.mounted) return;
    switch (action) {
      case 'copy':
        context.read<ClipboardBloc>().add(CopyToClipboard(selected));
      case 'cut':
        context.read<ClipboardBloc>().add(CutToClipboard(selected));
      case 'zip':
        _handleCompress(context, state);
      case 'all':
        bloc.add(SelectAll());
      case 'none':
        bloc.add(ToggleSelectionMode(enable: false));
      case 'delete':
        fileActionsService.deleteFiles(context, selected);
      case 'forGood':
        fileActionsService.deleteFiles(context, selected, permanent: true);
    }
  }

  /// Right-click on the empty space of a folder.
  Future<void> _showFolderMenu(
    BuildContext context,
    FileExplorerLoaded state,
    Offset position,
  ) async {
    if (ExplorerPaths.isTrash(state.path)) return TrashActions.showFolderMenu(context, position);
    final bloc = context.read<FileExplorerBloc>();
    final clipboard = context.read<ClipboardBloc>();
    final inFolder = !ExplorerPaths.isVirtual(state.path);
    // Also files another app copied (macOS), read when pasting.
    final canPaste = inFolder && clipboard.canPaste;
    final action = await ExplorerMenu.showAt<Object>(
      context,
      position,
      items: [
        if (inFolder)
          ExplorerMenu.item(context,
              value: 'folder',
              label: 'New folder',
              icon: LucideIcons.folderPlus,
              shortcut: Platform.isMacOS ? '⇧⌘N' : 'Ctrl+Shift+N'),
        ExplorerMenu.item(context,
            value: 'paste',
            label: 'Paste',
            icon: LucideIcons.clipboardPaste,
            enabled: canPaste,
            shortcut: FileActionsService.shortcut('V')),
        ExplorerMenu.item(context,
            value: 'all',
            label: 'Select all',
            icon: LucideIcons.listChecks,
            shortcut: FileActionsService.shortcut('A')),
        ExplorerMenu.item(context,
            value: 'refresh',
            label: 'Refresh',
            icon: LucideIcons.refreshCw,
            shortcut: 'F5'),
        ExplorerMenu.submenu<Object>(context,
            label: 'Group by',
            icon: LucideIcons.rows3,
            items: [
              for (final g in GroupBy.values)
                ExplorerMenu.item<Object>(context,
                    value: g, label: groupByLabel(g), icon: groupByIcon(g), checked: g == state.groupBy),
            ]),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'window',
            label: 'Open in new window',
            icon: LucideIcons.appWindow,
            shortcut: FileActionsService.shortcut('N')),
        if (inFolder)
          fileActionsService.shareSubmenu(context, [Directory(state.path)],
              label: 'Share this folder'),
      ],
    );
    if (action == null || !context.mounted) return;
    if (action is ShareMethod) {
      return fileActionsService.shareVia(context, action, [Directory(state.path)]);
    }
    if (action is GroupBy) return bloc.add(ChangeGroupBy(action));
    switch (action) {
      case 'folder':
        fileActionsService.createFolder(context, state.path);
      case 'paste':
        clipboard.add(PasteFromClipboard(state.path));
      case 'all':
        bloc.add(SelectAll());
      case 'refresh':
        bloc.add(LoadDirectory(state.path));
      case 'window':
        Desktop.openWindow(folder: state.path);
    }
  }

  static String _friendlyError(String message) {
    if (message.contains('not found or access denied')) {
      return "It may have been moved or deleted, or Folders isn't allowed "
          'to read it.';
    }
    return message;
  }

  void _handleTap(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) async {
    if (state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(SelectItem(entity));
    } else {
      await _open(context, state, entity);
    }
  }

  void _handleLongPress(
    BuildContext context,
    FileExplorerLoaded state,
    FileSystemEntity entity,
  ) {
    HapticFeedback.selectionClick();
    _clicks.mark(entity.path);
    if (!state.isSelectionMode) {
      context.read<FileExplorerBloc>().add(ToggleSelectionMode(enable: true));
    }
    context.read<FileExplorerBloc>().add(SelectItem(entity));
  }

  Future<void> _handleCompress(
    BuildContext context,
    FileExplorerLoaded state,
  ) async {
    if (state.selectedItems.isEmpty) return;
    final count = state.selectedItems.length;

    final String? fileName = await fileActionsService.promptForName(
      context,
      title: 'Compress to ZIP',
      description: count == 1
          ? 'The selected item will be added to a new ZIP archive in this '
                'folder.'
          : '$count items will be added to a new ZIP archive in this folder.',
      initialValue: 'archive.zip',
      selectBaseName: true,
      confirmLabel: 'Compress',
    );

    if (fileName != null && fileName.isNotEmpty && context.mounted) {
      // Filter only files for now, directories need recursive add logic in ArchiveService
      // My ArchiveService.compressFiles only takes List<File>.
      // So we filter:
      final filesOnly = state.selectedItems.whereType<File>().toList();

      if (filesOnly.length != state.selectedItems.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Folders were skipped: they can't be compressed yet"),
          ),
        );
      }

      if (filesOnly.isEmpty) return;

      try {
        final destPath = p.join(
          // A category isn't a folder: next to the first file.
          ExplorerPaths.isVirtual(state.path) ? p.dirname(filesOnly.first.path) : state.path,
          fileName.endsWith('.zip') ? fileName : '$fileName.zip',
        );
        await ArchiveService().compressFiles(filesOnly, File(destPath));

        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Compressed to $fileName')));
          // Refresh
          context.read<FileExplorerBloc>().add(LoadDirectory(state.path));
          context.read<FileExplorerBloc>().add(
            ToggleSelectionMode(enable: false),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Compression failed: $e')));
        }
      }
    }
  }

  Future<void> _handleHttpShare(
    BuildContext context,
    FileExplorerState state,
  ) async {
    if (state is! FileExplorerLoaded ||
        ExplorerPaths.isVirtual(state.path)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Open a folder to share it')),
      );
      return;
    }
    final bloc = context.read<FileExplorerBloc>();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FileServerScreen(initialFolder: state.path),
      ),
    );
    // Show files other devices uploaded.
    final now = bloc.state;
    if (!bloc.isClosed && now is FileExplorerLoaded) {
      bloc.add(LoadDirectory(now.path));
    }
  }
}

/// "4 folders · 14 files" under the last row.
class _FolderSummary extends StatelessWidget {
  const _FolderSummary({required this.entities});

  final List<FileSystemEntity> entities;

  @override
  Widget build(BuildContext context) {
    // macOS packages (apps) count as files, as Finder shows them.
    final folders = entities
        .where((e) => e is Directory && !FileActionsService.isPackage(e))
        .length;
    final files = entities.length - folders;
    final parts = [
      if (folders > 0) '$folders ${folders == 1 ? 'folder' : 'folders'}',
      if (files > 0) '$files ${files == 1 ? 'file' : 'files'}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text(
        parts.join(' · '),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// A group's heading: its name, how many items, and a rule.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.group, required this.side});

  final EntityGroup group;
  final double side;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(side + 4, 12, side + 4, 6),
      child: Row(
        children: [
          Text(group.label, style: text.titleSmall),
          const SizedBox(width: 8),
          Text('${group.entities.length}', style: text.bodySmall),
          const SizedBox(width: 12),
          Expanded(child: Divider(height: 1, color: colors.border)),
        ],
      ),
    );
  }
}

/// "Searching folders inside…" while subfolders are searched.
class _Searching extends StatelessWidget {
  const _Searching();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text('Searching folders inside…', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _SearchSummary extends StatelessWidget {
  const _SearchSummary({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Text(
        count == 1 ? '1 result' : '$count results',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// Placeholder rows while a folder loads.
class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton({required this.top});

  final double top;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: top),
      itemCount: 12,
      itemBuilder: (context, index) => SizedBox(
        height: 62,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  bar(120.0 + (index * 37) % 90, 12),
                  const SizedBox(height: 8),
                  bar(72.0 + (index * 23) % 40, 10),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [child] only if it's still on screen after a short delay, so fast
/// folder loads don't flash a placeholder.
class _DelayedReveal extends StatefulWidget {
  const _DelayedReveal({required this.child});

  final Widget child;

  @override
  State<_DelayedReveal> createState() => _DelayedRevealState();
}

class _DelayedRevealState extends State<_DelayedReveal> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: widget.child,
    );
  }
}

/// Shown when storage access hasn't been granted.
class _PermissionDeniedScreen extends StatelessWidget {
  const _PermissionDeniedScreen({required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: ExplorerEmptyState(
          icon: LucideIcons.folderLock,
          title: 'Allow access to your files',
          description:
              'Folders needs the "All files access" permission to '
              'browse, open and organise the files on this device. Nothing '
              'leaves your device.',
          actions: [
            OutlinedButton(
              onPressed: openAppSettings,
              child: const Text('Open settings'),
            ),
            FilledButton(
              onPressed: onRequest,
              child: const Text('Allow access'),
            ),
          ],
        ),
      ),
    );
  }
}
