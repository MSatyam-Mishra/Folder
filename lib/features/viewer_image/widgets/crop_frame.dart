import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What a pointer has hold of, on a crop frame.
enum CropZone { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, inside, outside }

extension on CropZone {
  bool get movesLeft => this == CropZone.left || this == CropZone.topLeft || this == CropZone.bottomLeft;
  bool get movesRight => this == CropZone.right || this == CropZone.topRight || this == CropZone.bottomRight;
  bool get movesTop => this == CropZone.top || this == CropZone.topLeft || this == CropZone.topRight;
  bool get movesBottom => this == CropZone.bottom || this == CropZone.bottomLeft || this == CropZone.bottomRight;
  bool get isCorner => (movesLeft || movesRight) && (movesTop || movesBottom);
}

/// The sums of a crop frame, in fractions of the image (0 to 1).
abstract final class CropGeometry {
  /// What's at [point] on [frame], in the same units, within [reach] of an edge.
  /// Corners come first, and a small frame leaves room to be moved by.
  static CropZone zoneAt(Offset point, Rect frame, double reach) {
    final near = math.min(reach, math.max(6.0, frame.shortestSide / 3));
    final byLeft = (point.dx - frame.left).abs() <= near;
    final byRight = (point.dx - frame.right).abs() <= near;
    final byTop = (point.dy - frame.top).abs() <= near;
    final byBottom = (point.dy - frame.bottom).abs() <= near;
    final acrossX = point.dx >= frame.left - near && point.dx <= frame.right + near;
    final acrossY = point.dy >= frame.top - near && point.dy <= frame.bottom + near;
    if (byLeft && byTop) return CropZone.topLeft;
    if (byRight && byTop) return CropZone.topRight;
    if (byLeft && byBottom) return CropZone.bottomLeft;
    if (byRight && byBottom) return CropZone.bottomRight;
    if (byLeft && acrossY) return CropZone.left;
    if (byRight && acrossY) return CropZone.right;
    if (byTop && acrossX) return CropZone.top;
    if (byBottom && acrossX) return CropZone.bottom;
    return frame.contains(point) ? CropZone.inside : CropZone.outside;
  }

  /// [start] after dragging [zone] by [delta]. [aspect] is the width to height
  /// it must keep, as fractions of the image; [minimum] the least it can be.
  static Rect dragged(CropZone zone, Rect start, Offset delta, {double? aspect, required Size minimum}) {
    if (zone == CropZone.inside) {
      return start.shift(Offset(
        delta.dx.clamp(-start.left, 1 - start.right),
        delta.dy.clamp(-start.top, 1 - start.bottom),
      ));
    }
    if (zone == CropZone.outside) return start;
    if (aspect != null) return _keepingAspect(zone, start, delta, aspect, minimum);
    var left = start.left, top = start.top, right = start.right, bottom = start.bottom;
    if (zone.movesLeft) left = (left + delta.dx).clamp(0.0, right - minimum.width);
    if (zone.movesRight) right = (right + delta.dx).clamp(left + minimum.width, 1.0);
    if (zone.movesTop) top = (top + delta.dy).clamp(0.0, bottom - minimum.height);
    if (zone.movesBottom) bottom = (bottom + delta.dy).clamp(top + minimum.height, 1.0);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// A corner keeps the opposite corner still; an edge keeps the opposite edge
  /// still, and grows to both sides along its length.
  static Rect _keepingAspect(CropZone zone, Rect start, Offset delta, double aspect, Size minimum) {
    final least = math.max(minimum.width, minimum.height * aspect);
    double fit(double wanted, double most) => wanted.clamp(math.min(least, most), most);
    if (zone.isCorner) {
      final anchorX = zone.movesRight ? start.left : start.right;
      final anchorY = zone.movesBottom ? start.top : start.bottom;
      final overX = zone.movesRight ? start.right + delta.dx - anchorX : anchorX - (start.left + delta.dx);
      final overY = zone.movesBottom ? start.bottom + delta.dy - anchorY : anchorY - (start.top + delta.dy);
      final roomX = zone.movesRight ? 1 - anchorX : anchorX;
      final roomY = zone.movesBottom ? 1 - anchorY : anchorY;
      final width = fit(math.max(overX, overY * aspect), math.min(roomX, roomY * aspect));
      final height = width / aspect;
      return Rect.fromLTRB(
        zone.movesRight ? anchorX : anchorX - width,
        zone.movesBottom ? anchorY : anchorY - height,
        zone.movesRight ? anchorX + width : anchorX,
        zone.movesBottom ? anchorY + height : anchorY,
      );
    }
    if (zone.movesLeft || zone.movesRight) {
      final anchorX = zone.movesRight ? start.left : start.right;
      final over = zone.movesRight ? start.right + delta.dx - anchorX : anchorX - (start.left + delta.dx);
      final middle = start.center.dy;
      final room = zone.movesRight ? 1 - anchorX : anchorX;
      final width = fit(over, math.min(room, math.min(middle, 1 - middle) * 2 * aspect));
      final height = width / aspect;
      return Rect.fromLTRB(
        zone.movesRight ? anchorX : anchorX - width,
        middle - height / 2,
        zone.movesRight ? anchorX + width : anchorX,
        middle + height / 2,
      );
    }
    final anchorY = zone.movesBottom ? start.top : start.bottom;
    final over = zone.movesBottom ? start.bottom + delta.dy - anchorY : anchorY - (start.top + delta.dy);
    final middle = start.center.dx;
    final room = zone.movesBottom ? 1 - anchorY : anchorY;
    final width = fit(over * aspect, math.min(room * aspect, math.min(middle, 1 - middle) * 2));
    final height = width / aspect;
    return Rect.fromLTRB(
      middle - width / 2,
      zone.movesBottom ? anchorY : anchorY - height,
      middle + width / 2,
      zone.movesBottom ? anchorY + height : anchorY,
    );
  }

  /// A new frame, drawn from [from] to [to] on the image; [previous] until it's
  /// big enough to be one.
  static Rect drawn(Offset from, Offset to, Rect previous, {required Size minimum}) {
    final rect = Rect.fromPoints(from, to).intersect(const Rect.fromLTWH(0, 0, 1, 1));
    return rect.width < minimum.width || rect.height < minimum.height ? previous : rect;
  }
}

/// A crop frame over an image, with every edge and corner to take hold of, its
/// inside to move it by, and the rest of the image to draw a new one on.
///
/// It keeps its own state while dragged and only repaints itself, so it follows
/// the finger however large the image; [onChanged] comes at the end of a drag.
class CropFrame extends StatefulWidget {
  const CropFrame({
    super.key,
    required this.imageRect,
    required this.rect,
    required this.pixelSize,
    required this.onChanged,
    this.aspect,
  });

  /// Room to take hold of an edge at the image's border: the system's back
  /// gesture has a phone's screen edges.
  static const margin = 20.0;

  /// Where the image is, in this widget.
  final Rect imageRect;

  /// The frame, in fractions of the image.
  final Rect rect;

  /// The image's size, for the size shown during a drag.
  final Size pixelSize;

  /// Width to height to keep, in fractions of the image; null for free.
  final double? aspect;
  final ValueChanged<Rect> onChanged;

  @override
  State<CropFrame> createState() => _CropFrameState();
}

class _CropFrameState extends State<CropFrame> {
  static const _mouseReach = 12.0;
  static const _touchReach = 30.0;
  static const _minimumPixels = 32.0;

  late final _rect = ValueNotifier(widget.rect);
  final _dragging = ValueNotifier(false);
  MouseCursor _cursor = SystemMouseCursors.basic;

  int? _pointer;
  CropZone? _zone;
  Offset _downAt = Offset.zero;
  Rect _startRect = Rect.zero;

  Size get _minimum => Size(
        math.min(1, _minimumPixels / widget.imageRect.width),
        math.min(1, _minimumPixels / widget.imageRect.height),
      );

  /// The frame in this widget's own units.
  Rect get _onScreen {
    final image = widget.imageRect;
    final r = _rect.value;
    return Rect.fromLTRB(
      image.left + r.left * image.width,
      image.top + r.top * image.height,
      image.left + r.right * image.width,
      image.top + r.bottom * image.height,
    );
  }

  Offset _fraction(Offset point) => Offset(
        (point.dx - widget.imageRect.left) / widget.imageRect.width,
        (point.dy - widget.imageRect.top) / widget.imageRect.height,
      );

  @override
  void didUpdateWidget(CropFrame old) {
    super.didUpdateWidget(old);
    // A ratio or a reset from the buttons; not its own last drag coming back.
    if (widget.rect != _rect.value && _zone == null) _rect.value = widget.rect;
  }

  @override
  void dispose() {
    _rect.dispose();
    _dragging.dispose();
    super.dispose();
  }

  void _onDown(PointerDownEvent event) {
    if (_pointer != null || event.buttons & kPrimaryButton == 0 && event.kind == PointerDeviceKind.mouse) return;
    final reach = event.kind == PointerDeviceKind.mouse ? _mouseReach : _touchReach;
    _pointer = event.pointer;
    _zone = CropGeometry.zoneAt(event.localPosition, _onScreen, reach);
    _downAt = event.localPosition;
    _startRect = _rect.value;
    _dragging.value = true;
    if (event.kind == PointerDeviceKind.touch && _zone != CropZone.outside && _zone != CropZone.inside) {
      HapticFeedback.selectionClick();
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final zone = _zone!;
    final image = widget.imageRect;
    if (zone == CropZone.outside) {
      // A frame keeps its shape, so a new one can only be drawn when free.
      if (widget.aspect != null) return;
      _rect.value = CropGeometry.drawn(
        _fraction(_downAt),
        _fraction(event.localPosition),
        _startRect,
        minimum: _minimum,
      );
      return;
    }
    final moved = event.localPosition - _downAt;
    _rect.value = CropGeometry.dragged(
      zone,
      _startRect,
      Offset(moved.dx / image.width, moved.dy / image.height),
      aspect: widget.aspect,
      minimum: _minimum,
    );
  }

  void _onEnd(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _zone = null;
    _dragging.value = false;
    if (_rect.value != _startRect) widget.onChanged(_rect.value);
  }

  void _onHover(PointerHoverEvent event) {
    final zone = CropGeometry.zoneAt(event.localPosition, _onScreen, _mouseReach);
    final cursor = switch (zone) {
      CropZone.topLeft || CropZone.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
      CropZone.topRight || CropZone.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
      CropZone.left || CropZone.right => SystemMouseCursors.resizeLeftRight,
      CropZone.top || CropZone.bottom => SystemMouseCursors.resizeUpDown,
      CropZone.inside => SystemMouseCursors.move,
      CropZone.outside => widget.aspect == null ? SystemMouseCursors.precise : SystemMouseCursors.basic,
    };
    if (cursor != _cursor) setState(() => _cursor = cursor);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _cursor,
      onHover: _onHover,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        // Raw pointers: no waiting to tell a drag from a tap.
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onEnd,
        onPointerCancel: _onEnd,
        child: CustomPaint(
          size: Size.infinite,
          painter: _CropPainter(
            rect: _rect,
            dragging: _dragging,
            imageRect: widget.imageRect,
            pixelSize: widget.pixelSize,
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.rect,
    required this.dragging,
    required this.imageRect,
    required this.pixelSize,
  }) : super(repaint: Listenable.merge([rect, dragging]));

  final ValueListenable<Rect> rect;
  final ValueListenable<bool> dragging;
  final Rect imageRect;
  final Size pixelSize;

  static const _handleLength = 20.0;
  static const _handleWidth = 3.5;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect.value;
    final frame = Rect.fromLTRB(
      imageRect.left + r.left * imageRect.width,
      imageRect.top + r.top * imageRect.height,
      imageRect.left + r.right * imageRect.width,
      imageRect.top + r.bottom * imageRect.height,
    );
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(imageRect)
        ..addRect(frame),
      Paint()..color = Colors.black.withValues(alpha: 0.6),
    );

    final lines = Paint()
      ..color = Colors.white.withValues(alpha: dragging.value ? 0.7 : 0.35)
      ..strokeWidth = 0.75;
    for (var i = 1; i < 3; i++) {
      final x = frame.left + frame.width * i / 3;
      final y = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), lines);
      canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), lines);
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final handles = Paint()
      ..color = Colors.white
      ..strokeWidth = _handleWidth
      ..strokeCap = StrokeCap.round;
    final along = math.min(_handleLength, frame.shortestSide / 2);
    for (final (x, y, dx, dy) in [
      (frame.left, frame.top, 1.0, 1.0),
      (frame.right, frame.top, -1.0, 1.0),
      (frame.left, frame.bottom, 1.0, -1.0),
      (frame.right, frame.bottom, -1.0, -1.0),
    ]) {
      canvas.drawLine(Offset(x, y), Offset(x + dx * along, y), handles);
      canvas.drawLine(Offset(x, y), Offset(x, y + dy * along), handles);
    }
    // In the middle of each edge, showing they can be dragged too.
    final bar = math.min(_handleLength / 2, frame.shortestSide / 6);
    final middle = frame.center;
    canvas.drawLine(Offset(middle.dx - bar, frame.top), Offset(middle.dx + bar, frame.top), handles);
    canvas.drawLine(Offset(middle.dx - bar, frame.bottom), Offset(middle.dx + bar, frame.bottom), handles);
    canvas.drawLine(Offset(frame.left, middle.dy - bar), Offset(frame.left, middle.dy + bar), handles);
    canvas.drawLine(Offset(frame.right, middle.dy - bar), Offset(frame.right, middle.dy + bar), handles);

    if (dragging.value) _paintSize(canvas, frame, r);
  }

  /// The crop's size in pixels, in the frame.
  void _paintSize(Canvas canvas, Rect frame, Rect r) {
    final label = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: '${(r.width * pixelSize.width).round()} × ${(r.height * pixelSize.height).round()}',
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
      ),
    )..layout();
    final box = Rect.fromCenter(
      center: frame.center,
      width: label.width + 16,
      height: label.height + 8,
    );
    if (box.width < frame.width && box.height < frame.height) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(8)),
        Paint()..color = Colors.black.withValues(alpha: 0.6),
      );
      label.paint(canvas, box.center - Offset(label.width / 2, label.height / 2));
    }
    label.dispose();
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.imageRect != imageRect || old.pixelSize != pixelSize || old.rect != rect || old.dragging != dragging;
}
