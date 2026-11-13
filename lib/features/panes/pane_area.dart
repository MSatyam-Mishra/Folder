import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/pane_actions.dart';
import 'package:folders/features/panes/pane_settings.dart';
import 'package:folders/features/panes/preview_pane.dart';
import 'package:folders/shared/ui/app_ui.dart';

/// The browser's page, a second one beside it while dual pane is on, and
/// the preview pane on the right while that's on. Dividers between them
/// are dragged to share the room (a double-click shares it evenly again).
class DualPaneArea extends StatefulWidget {
  const DualPaneArea({super.key, required this.first, required this.second});

  /// The browser's own page.
  final Widget first;

  /// Builds the second pane's page, under its own browser.
  final WidgetBuilder second;

  /// The narrowest a pane gets beside another one.
  static const double minPane = 320;

  /// The narrowest the page gets beside the preview pane.
  static const double minSingle = 360;

  @override
  State<DualPaneArea> createState() => _DualPaneAreaState();
}

class _DualPaneAreaState extends State<DualPaneArea> {
  DualPaneController? _panes;

  // Where a drag of a divider started.
  double _dragFrom = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final panes = DualPanes.of(context);
    if (panes != _panes) {
      _panes?.detachArea(context);
      _panes = panes;
    }
    panes?.attachArea(context, context.read<FileExplorerBloc>());
  }

  @override
  void dispose() {
    _panes?.detachArea(context);
    super.dispose();
  }

  /// Tells the header how much room there is, after this frame.
  void _report(DualPaneController panes, {required bool two, required bool preview}) {
    if (two == panes.roomForTwo && preview == panes.roomForPreview) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) panes.setRoom(two: two, preview: preview);
    });
  }

  @override
  Widget build(BuildContext context) {
    final panes = DualPanes.of(context);
    if (panes == null) return widget.first;
    return ListenableBuilder(
      listenable: Listenable.merge([panes.ratio, PaneSettings.instance]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) => _layout(context, panes, box.maxWidth),
      ),
    );
  }

  Widget _layout(BuildContext context, DualPaneController panes, double width) {
    const line = 1.0;
    final settings = PaneSettings.instance;
    final roomForTwo = width >= 2 * DualPaneArea.minPane + line;
    final dual = panes.enabled && roomForTwo;
    final panesMin = dual ? 2 * DualPaneArea.minPane + line : DualPaneArea.minSingle;
    final previewRoom = width - panesMin - line;
    final roomForPreview = PaneActions.previewAllowed(context) && previewRoom >= PaneSettings.previewMin;
    final preview = settings.preview && roomForPreview;
    final previewWidth = preview
        ? settings.previewWidth.clamp(PaneSettings.previewMin, math.min(PaneSettings.previewMax, previewRoom)).toDouble()
        : 0.0;
    final panesWidth = width - (preview ? previewWidth + line : 0);
    final room = panesWidth - line;
    final firstWidth = dual
        ? (room * panes.ratio.value).clamp(DualPaneArea.minPane, room - DualPaneArea.minPane).toDouble()
        : panesWidth;
    _report(panes, two: roomForTwo, preview: roomForPreview);

    final glass = context.look.style.glass;
    final colors = context.colors;
    Widget rule(Key key) => SizedBox(
          key: key,
          width: line,
          child: glass ? null : ColoredBox(color: colors.border),
        );

    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const ValueKey('first pane'),
              width: firstWidth,
              child: _PaneFrame(
                index: 0,
                width: firstWidth,
                dual: dual,
                shared: dual || preview,
                panes: panes,
                child: widget.first,
              ),
            ),
            if (dual) ...[
              rule(const ValueKey('pane rule')),
              SizedBox(
                key: const ValueKey('second pane'),
                width: room - firstWidth,
                child: _PaneFrame(
                  index: 1,
                  width: room - firstWidth,
                  dual: true,
                  shared: true,
                  panes: panes,
                  child: _SecondPane(panes: panes, builder: widget.second),
                ),
              ),
            ],
            if (preview) ...[
              rule(const ValueKey('preview rule')),
              SizedBox(
                key: const ValueKey('preview pane'),
                width: previewWidth,
                child: PreviewPane(panes: panes),
              ),
            ],
          ],
        ),
        if (dual)
          Positioned(
            key: const ValueKey('pane divider'),
            left: firstWidth - 2,
            top: 0,
            bottom: 0,
            width: 8,
            child: PaneDivider(
              tooltip: 'Drag to resize the panes',
              onStart: () => _dragFrom = firstWidth,
              onDrag: (dx) => panes.setRatio((_dragFrom + dx) / room),
              onReset: () => panes.setRatio(0.5),
            ),
          ),
        if (preview)
          Positioned(
            key: const ValueKey('preview divider'),
            left: panesWidth - 2,
            top: 0,
            bottom: 0,
            width: 8,
            child: PaneDivider(
              tooltip: 'Drag to resize the preview',
              onStart: () => _dragFrom = previewWidth,
              onDrag: (dx) => settings.setPreviewWidth(_dragFrom - dx),
              onReset: () => settings.setPreviewWidth(PaneSettings.previewUsual),
            ),
          ),
      ],
    );
  }
}

/// A pane: says where it is to what's inside ([PaneSlot]), becomes the
/// active one when pressed, and is marked along its top while active.
class _PaneFrame extends StatelessWidget {
  const _PaneFrame({
    required this.index,
    required this.width,
    required this.dual,
    required this.shared,
    required this.panes,
    required this.child,
  });

  final int index;
  final double width;
  final bool dual;
  final bool shared;
  final DualPaneController panes;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final active = dual && panes.active == index;
    return Listener(
      behavior: HitTestBehavior.translucent,
      // Before what's pressed acts: a menu or a key then works on this pane.
      onPointerDown: dual ? (_) => panes.activate(index) : null,
      child: PaneSlot(
        index: index,
        width: width,
        dual: dual,
        shared: shared,
        child: Stack(
          children: [
            Positioned.fill(child: child),
            if (active)
              Positioned(
                key: const ValueKey('active pane'),
                top: 0,
                left: 0,
                right: 0,
                height: 3,
                child: IgnorePointer(child: _ActiveMark()),
              ),
          ],
        ),
      ),
    );
  }
}

/// The active pane's mark: a line in the theme's colour along its top.
class _ActiveMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.primary,
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(2)),
        ),
      );
}

/// The second pane: a browser of its own, with its own keyboard scope and
/// messages, starting where it was last (else on the first pane's folder).
class _SecondPane extends StatefulWidget {
  const _SecondPane({required this.panes, required this.builder});

  final DualPaneController panes;
  final WidgetBuilder builder;

  @override
  State<_SecondPane> createState() => _SecondPaneState();
}

class _SecondPaneState extends State<_SecondPane> {
  late final FileExplorerBloc _bloc;

  @override
  void initState() {
    super.initState();
    final panes = widget.panes;
    final first = panes.first;
    _bloc = FileExplorerBloc(repository: first?.repository)
      ..add(LoadDirectory(panes.secondFolder ?? pathOfBrowser(first) ?? ExplorerPaths.initialPath));
    panes.attachSecond(_bloc);
  }

  @override
  void dispose() {
    widget.panes.detachSecond(_bloc);
    _bloc.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Messages from this pane show in it, not in both.
    return ScaffoldMessenger(
      child: FocusScope(
        node: widget.panes.secondScope,
        child: BlocProvider<FileExplorerBloc>.value(
          value: _bloc,
          child: BlocListener<FileExplorerBloc, FileExplorerState>(
            listenWhen: (before, now) => pathOfState(now) != null && pathOfState(now) != pathOfState(before),
            listener: (context, state) => widget.panes.secondMoved(pathOfState(state)!),
            child: Builder(builder: widget.builder),
          ),
        ),
      ),
    );
  }
}

/// A divider between panes, dragged to resize them; marked while the
/// pointer is on it.
class PaneDivider extends StatefulWidget {
  const PaneDivider({
    super.key,
    required this.onStart,
    required this.onDrag,
    required this.onReset,
    this.tooltip,
  });

  final VoidCallback onStart;

  /// How far it was dragged from where it started.
  final ValueChanged<double> onDrag;
  final VoidCallback onReset;
  final String? tooltip;

  @override
  State<PaneDivider> createState() => _PaneDividerState();
}

class _PaneDividerState extends State<PaneDivider> {
  bool _hovered = false;
  bool _dragging = false;
  double _fromX = 0;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onReset,
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (details) {
          _fromX = details.globalPosition.dx;
          widget.onStart();
          setState(() => _dragging = true);
        },
        onHorizontalDragUpdate: (details) => widget.onDrag(details.globalPosition.dx - _fromX),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(left: 1),
            width: 2,
            color: _hovered || _dragging ? context.colors.primary : Colors.transparent,
          ),
        ),
      ),
    );
  }
}

/// The sidebar works on the active pane: what it opens shows there.
class ActivePaneBloc extends StatelessWidget {
  const ActivePaneBloc({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final panes = DualPanes.of(context);
    final bloc = panes?.activeBloc ?? context.read<FileExplorerBloc>();
    return BlocProvider<FileExplorerBloc>.value(value: bloc, child: child);
  }
}

/// Back (Android) for a browser's page: with two panes, only the active
/// one's counts ([onBack] goes up a folder or ends a selection); the other
/// lets it through.
class PanePopScope extends StatelessWidget {
  const PanePopScope({super.key, required this.canPop, required this.onBack, required this.child});

  /// Whether Back may leave the page (nothing to go back to here).
  final bool canPop;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final active = DualPanes.isActive(context);
    return PopScope(
      canPop: canPop || !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && active) onBack();
      },
      child: child,
    );
  }
}

/// The tasks' dock ([child], a Positioned) in the rightmost pane only, so
/// two panes don't show it twice.
class PaneDock extends StatelessWidget {
  const PaneDock({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final slot = PaneSlot.of(context);
    if (slot == null || slot.rightmost) return child;
    return const Positioned(left: 0, top: 0, width: 0, height: 0, child: SizedBox.shrink());
  }
}
