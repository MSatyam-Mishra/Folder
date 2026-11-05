import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How big icons and thumbnails are in the file list, 1 being the usual
/// size: Ctrl+wheel and touchpad pinch over the files, Ctrl+plus/minus
/// (Ctrl+0 back to 1), or the slider in Options. One size for every view,
/// tab and window, and kept.
class ExplorerZoom extends ValueNotifier<double> {
  ExplorerZoom._() : super(1);

  static final instance = ExplorerZoom._();

  static const double min = 0.75;
  static const double max = 3;
  static const _key = 'explorer_zoom';

  /// Each wheel notch or key press: about 15%.
  static const double _step = 1.15;

  Timer? _save;

  /// The size last used.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = (prefs.getDouble(_key) ?? 1).clamp(min, max);
  }

  /// Sets the size; saved a moment later (a pinch sets it many times).
  void set(double zoom) {
    final next = zoom.clamp(min, max).toDouble();
    if (next == value) return;
    value = next;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_key, value);
    });
  }

  /// Bigger ([steps] > 0) or smaller; stops at the usual size on the way.
  void step(int steps) {
    final next = value * math.pow(_step, steps);
    final passesOne = (value < 1 && next > 1) || (value > 1 && next < 1);
    set(passesOne || (next - 1).abs() < 0.04 ? 1 : next);
  }

  void reset() => set(1);

  /// Ctrl (Cmd on macOS) is held: the wheel zooms instead of scrolling.
  static bool get zoomKeyPressed =>
      Platform.isMacOS ? HardwareKeyboard.instance.isMetaPressed : HardwareKeyboard.instance.isControlPressed;
}

/// The grid and gallery at a zoom: as many tiles as fit at [zoom] times the
/// size they have at 100%, sharing all the row's room, so no gap is left at its
/// end. At 100% it's the usual grid, tiles up to [maxTile] wide. So a tile's
/// size moves in steps, as the number in a row changes.
class ZoomedGridDelegate extends SliverGridDelegate {
  const ZoomedGridDelegate({
    required this.maxTile,
    required this.aspectRatio,
    required this.spacing,
    required this.zoom,
  });

  final double maxTile;
  final double aspectRatio;
  final double spacing;
  final double zoom;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final room = constraints.crossAxisExtent;
    final usual = math.max(1, (room / (maxTile + spacing)).ceil());
    final usualTile = math.max(0.0, room - spacing * (usual - 1)) / usual;
    final wanted = math.min(usualTile * zoom, room);
    // The small amount: at 100% the sum comes out a hair under `usual`.
    final count = math.max(1, ((room + spacing) / (wanted + spacing) + 1e-6).floor());
    final tile = math.max(0.0, room - spacing * (count - 1)) / count;
    final height = tile / aspectRatio;
    return SliverGridRegularTileLayout(
      crossAxisCount: count,
      mainAxisStride: height + spacing,
      crossAxisStride: tile + spacing,
      childMainAxisExtent: height,
      childCrossAxisExtent: tile,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(ZoomedGridDelegate oldDelegate) =>
      oldDelegate.maxTile != maxTile ||
      oldDelegate.aspectRatio != aspectRatio ||
      oldDelegate.spacing != spacing ||
      oldDelegate.zoom != zoom;
}

/// Scrolling, except while Ctrl is held: the wheel then zooms (see
/// [ZoomGestures]).
class ZoomKeyScrollPhysics extends ScrollPhysics {
  const ZoomKeyScrollPhysics({super.parent});

  @override
  ZoomKeyScrollPhysics applyTo(ScrollPhysics? ancestor) => ZoomKeyScrollPhysics(parent: buildParent(ancestor));

  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) =>
      !ExplorerZoom.zoomKeyPressed && super.shouldAcceptUserOffset(position);
}

/// Ctrl+wheel and touchpad pinch over [child] zoom the file list.
class ZoomGestures extends StatefulWidget {
  const ZoomGestures({super.key, required this.child});

  final Widget child;

  @override
  State<ZoomGestures> createState() => _ZoomGesturesState();
}

class _ZoomGesturesState extends State<ZoomGestures> {
  double? _pinchFrom;

  @override
  Widget build(BuildContext context) {
    final zoom = ExplorerZoom.instance;
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent || !ExplorerZoom.zoomKeyPressed) return;
        GestureBinding.instance.pointerSignalResolver.register(event, (event) {
          final dy = (event as PointerScrollEvent).scrollDelta.dy;
          if (dy != 0) zoom.step(dy < 0 ? 1 : -1);
        });
      },
      onPointerPanZoomStart: (_) => _pinchFrom = zoom.value,
      onPointerPanZoomUpdate: (event) {
        final from = _pinchFrom;
        // Two-finger scrolling reports a scale of 1: only pinches zoom.
        if (from != null && (event.scale - 1).abs() > 0.02) zoom.set(from * event.scale);
      },
      onPointerPanZoomEnd: (_) => _pinchFrom = null,
      child: widget.child,
    );
  }
}
