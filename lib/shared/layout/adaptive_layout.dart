import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:explorer/shared/ui/app_tokens.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Material 3 window size classes, used to adapt layouts for phones,
/// foldables and tablets.
enum WindowSize {
  /// < 600dp: phones in portrait, folded foldables.
  compact,

  /// 600–839dp: small tablets, unfolded book-style foldables, phones in
  /// landscape.
  medium,

  /// >= 840dp: tablets, desktops.
  expanded;

  static WindowSize of(BuildContext context) =>
      fromWidth(MediaQuery.sizeOf(context).width);

  static WindowSize fromWidth(double width) {
    if (width >= 840) return expanded;
    if (width >= 600) return medium;
    return compact;
  }

  bool get isCompact => this == compact;
  bool get isAtLeastMedium => this != compact;
  bool get isExpanded => this == expanded;
}

/// Information about a physical hinge or fold that splits the screen.
class FoldInfo {
  const FoldInfo(this.bounds, {required this.isVertical, required this.isHalfOpened});

  /// Hinge area in logical pixels (zero width for seamless folds).
  final Rect bounds;

  /// True for a vertical hinge (left/right panes, "book" posture).
  final bool isVertical;

  /// True when the device is partially folded (tabletop/book posture).
  final bool isHalfOpened;

  /// The first visible feature that separates the screen, if any.
  ///
  /// A flat, seamless fold doesn't separate content, so it's ignored unless
  /// [includeFlat] is true.
  static FoldInfo? of(BuildContext context, {bool includeFlat = false}) {
    final features = MediaQuery.displayFeaturesOf(context);
    final size = MediaQuery.sizeOf(context);
    for (final DisplayFeature f in features) {
      if (f.type == DisplayFeatureType.cutout) continue;
      final halfOpened = f.state == DisplayFeatureState.postureHalfOpened;
      final separates = f.type == DisplayFeatureType.hinge || halfOpened;
      if (!separates && !includeFlat) continue;
      final vertical = f.bounds.height >= size.height - 1 ||
          f.bounds.width < f.bounds.height;
      return FoldInfo(f.bounds, isVertical: vertical, isHalfOpened: halfOpened);
    }
    return null;
  }
}

/// Lays out [primary] and [secondary] side by side on wide screens and
/// foldables, or shows only [primary] on compact screens.
///
/// When a vertical hinge is present, the split lands exactly on the hinge so
/// neither pane is drawn under it. Otherwise [secondary] gets
/// [secondaryWidth] on the leading side.
class AdaptiveSplitView extends StatelessWidget {
  const AdaptiveSplitView({
    super.key,
    required this.primary,
    required this.secondary,
    this.secondaryWidth = 300,
    this.minWidthForSplit = 840,
    this.secondaryOnLeading = true,
    this.divider = true,
    this.onResize,
    this.onResizeReset,
  });

  /// The border between the panes was dragged: the width [secondary] should
  /// have (a leading pane). Null keeps its width fixed.
  final ValueChanged<double>? onResize;

  /// The border was double-clicked.
  final VoidCallback? onResizeReset;

  final Widget primary;
  final Widget secondary;
  final double secondaryWidth;
  final double minWidthForSplit;
  final bool secondaryOnLeading;
  final bool divider;

  /// Whether this view would currently show both panes.
  static bool isSplit(BuildContext context, {double minWidthForSplit = 840}) {
    final fold = FoldInfo.of(context);
    if (fold != null && fold.isVertical) return true;
    return MediaQuery.sizeOf(context).width >= minWidthForSplit;
  }

  @override
  Widget build(BuildContext context) {
    final fold = FoldInfo.of(context);
    final width = MediaQuery.sizeOf(context).width;

    if (fold != null && fold.isVertical) {
      final leftWidth = fold.bounds.left;
      final rightWidth = width - fold.bounds.right;
      final left = secondaryOnLeading ? secondary : primary;
      final right = secondaryOnLeading ? primary : secondary;
      return Row(
        children: [
          SizedBox(width: leftWidth, child: left),
          SizedBox(width: fold.bounds.width),
          SizedBox(width: rightWidth, child: right),
        ],
      );
    }

    if (width < minWidthForSplit) return primary;

    final side = SizedBox(width: secondaryWidth, child: secondary);
    final children = <Widget>[
      if (secondaryOnLeading) side,
      if (secondaryOnLeading && divider) const VerticalDivider(width: 1),
      Expanded(child: primary),
      if (!secondaryOnLeading && divider) const VerticalDivider(width: 1),
      if (!secondaryOnLeading) side,
    ];
    final resize = onResize;
    if (resize == null || !secondaryOnLeading) return Row(children: children);
    return Stack(
      children: [
        Row(children: children),
        Positioned(
          // Mostly over the page: the sidebar's scrollbar is just left of it.
          left: secondaryWidth - 2,
          top: 0,
          bottom: 0,
          width: 8,
          child: _ResizeHandle(width: secondaryWidth, onResize: resize, onReset: onResizeReset),
        ),
      ],
    );
  }
}

/// The draggable border between a sidebar and the page, marked while the
/// pointer is on it.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.width, required this.onResize, this.onReset});

  final double width;
  final ValueChanged<double> onResize;
  final VoidCallback? onReset;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;
  double _fromWidth = 0;
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
        // Counted from where it was pressed, so the border stays under the
        // pointer.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (details) {
          _fromWidth = widget.width;
          _fromX = details.globalPosition.dx;
          setState(() => _dragging = true);
        },
        onHorizontalDragUpdate: (details) =>
            widget.onResize(_fromWidth + details.globalPosition.dx - _fromX),
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

/// Full-height navigation pane for wide screens, in the style of the
/// shadcn/ui sidebar: a lightly tinted surface below the status bar. Put it
/// in [AdaptiveSplitView.secondary] (which draws the hairline border).
class DockedSidebar extends StatelessWidget {
  const DockedSidebar({super.key, required this.child});

  final Widget child;

  /// The pane's background, a step off the page background.
  static Color backgroundOf(BuildContext context) {
    final colors = context.colors;
    return Color.alphaBlend(
      colors.muted.withValues(alpha: context.isDarkMode ? 0.45 : 0.4),
      colors.background,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundOf(context),
      child: SafeArea(right: false, child: child),
    );
  }
}

/// Centers [child] and caps its width so reading content doesn't stretch
/// edge to edge on tablets and desktops.
class ReadableWidth extends StatelessWidget {
  const ReadableWidth({super.key, required this.child, this.maxWidth = 900});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
