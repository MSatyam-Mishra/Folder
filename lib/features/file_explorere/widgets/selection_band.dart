import 'dart:async';
import 'dart:io';

import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Marks what grabs an item for dragging: its icon and name, or all of it
/// once selected. Pressing anywhere else starts a [SelectionBand].
const Object itemDragPart = _ItemDragPart();

class _ItemDragPart {
  const _ItemDragPart();
}

/// Whether [position] (global) is on an [itemDragPart].
bool overDragPart(BuildContext context, Offset position) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, View.of(context).viewId);
  return result.path.any((entry) {
    final target = entry.target;
    return target is RenderMetaData && identical(target.metaData, itemDragPart);
  });
}

/// The items built at the moment, for the selection band and the arrow keys.
class ShownItems {
  final _items = <String, _ShownItemState>{};

  /// How much of the list the header and the bottom bar cover.
  double top = 0;
  double bottom = 0;

  ScrollableState? get _scrollable =>
      _items.isEmpty ? null : Scrollable.maybeOf(_items.values.first.context);

  ScrollPosition? get position => _scrollable?.position;

  /// How many items fit across: the most sharing a row.
  int get columns {
    final inRow = <double, int>{};
    for (final item in _items.values) {
      final box = item.box;
      if (box == null) continue;
      final y = box.localToGlobal(Offset.zero).dy.roundToDouble();
      inRow[y] = (inRow[y] ?? 0) + 1;
    }
    return inRow.values.fold(1, (most, count) => count > most ? count : most);
  }

  /// How many rows Page Up and Page Down move by.
  int get rowsOnPage {
    final view = _scrollable?.context.findRenderObject();
    final row = _items.isEmpty ? null : _items.values.first.box;
    if (view is! RenderBox || row == null || row.size.height <= 0) return 1;
    final rows = (view.size.height - top - bottom) ~/ row.size.height;
    return rows < 1 ? 1 : rows;
  }

  /// Scrolls to [path], the [index]th of [count] items in the list.
  void reveal(String path, int index, int count) {
    if (_scrollIntoView(path)) return;
    // Too far off to be built: near where it should be, then exactly.
    final position = this.position;
    if (position == null) return;
    position.jumpTo(count > 1 ? position.maxScrollExtent * index / (count - 1) : 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollIntoView(path));
  }

  bool _scrollIntoView(String path) {
    final item = _items[path];
    final box = item?.box;
    if (item == null || box == null) return false;
    final scrollable = Scrollable.maybeOf(item.context);
    final view = scrollable?.context.findRenderObject();
    if (scrollable == null || view is! RenderBox) return false;
    final y = box.localToGlobal(Offset.zero, ancestor: view).dy;
    final above = y - top;
    final below = y + box.size.height - (view.size.height - bottom);
    final by = above < 0 ? above : (below > 0 ? below : 0.0);
    final position = scrollable.position;
    if (by != 0) {
      position.jumpTo((position.pixels + by).clamp(position.minScrollExtent, position.maxScrollExtent));
    }
    return true;
  }
}

/// An item of a list, known to [items] while it's built.
class ShownItem extends StatefulWidget {
  const ShownItem({super.key, required this.items, required this.entity, required this.child});

  final ShownItems items;
  final FileSystemEntity entity;
  final Widget child;

  @override
  State<ShownItem> createState() => _ShownItemState();
}

class _ShownItemState extends State<ShownItem> {
  RenderBox? get box {
    final object = context.findRenderObject();
    return object is RenderBox && object.hasSize && object.attached ? object : null;
  }

  void _remove(ShownItem from) {
    if (identical(from.items._items[from.entity.path], this)) {
      from.items._items.remove(from.entity.path);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.items._items[widget.entity.path] = this;
  }

  @override
  void didUpdateWidget(ShownItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    _remove(oldWidget);
    widget.items._items[widget.entity.path] = this;
  }

  @override
  void dispose() {
    _remove(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Selecting by dragging a band over the items with the mouse, from anywhere
/// that doesn't grab an item. Ctrl (Cmd) adds to what's selected. Near the
/// list's top and bottom edges it scrolls.
class SelectionBand extends StatefulWidget {
  const SelectionBand({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    required this.child,
  });

  final ShownItems items;

  /// What's selected now.
  final Set<FileSystemEntity> Function() selected;

  /// The band covers [selection] now; [done] when the button went up.
  final void Function(Set<FileSystemEntity> selection, {required bool done}) onChanged;
  final Widget child;

  @override
  State<SelectionBand> createState() => _SelectionBandState();
}

class _SelectionBandState extends State<SelectionBand> {
  /// The width of the scrollbar at the right, which has its own drag.
  static const _scrollbar = 14.0;
  static const _slop = 6.0;
  static const _edge = 40.0;

  int? _pointer;
  Offset _from = Offset.zero;
  Offset _at = Offset.zero;
  double _fromPixels = 0;
  bool _active = false;
  Set<FileSystemEntity> _kept = const {};
  Set<FileSystemEntity> _covered = const {};
  Timer? _scrolling;

  Rect get _band {
    final scrolled = (widget.items.position?.pixels ?? _fromPixels) - _fromPixels;
    return Rect.fromPoints(_from - Offset(0, scrolled), _at);
  }

  void _down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse || event.buttons != kPrimaryButton) return;
    final box = context.findRenderObject() as RenderBox;
    if (event.localPosition.dx > box.size.width - _scrollbar) return;
    if (overDragPart(context, event.position)) return;
    _pointer = event.pointer;
    _from = _at = event.localPosition;
    _fromPixels = widget.items.position?.pixels ?? 0;
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _at = event.localPosition;
    if (!_active) {
      if ((_at - _from).distance < _slop) return;
      final keys = HardwareKeyboard.instance;
      _active = true;
      _kept = (Platform.isMacOS ? keys.isMetaPressed : keys.isControlPressed)
          ? {...widget.selected()}
          : const {};
      _covered = {..._kept};
      widget.onChanged(_covered, done: false);
      _scrolling = Timer.periodic(const Duration(milliseconds: 16), (_) => _scrollAtEdge());
    }
    _update();
  }

  void _update() {
    final box = context.findRenderObject() as RenderBox;
    final band = _band;
    final covered = {..._covered};
    // Items scrolled too far away to be built stay as they were.
    for (final item in widget.items._items.values) {
      final itemBox = item.box;
      if (itemBox == null) continue;
      final rect = itemBox.localToGlobal(Offset.zero, ancestor: box) & itemBox.size;
      final entity = item.widget.entity;
      if (rect.overlaps(band)) {
        covered.add(entity);
      } else if (!_kept.contains(entity)) {
        covered.remove(entity);
      }
    }
    if (!setEquals(covered, _covered)) {
      _covered = covered;
      widget.onChanged(covered, done: false);
    }
    setState(() {});
  }

  void _scrollAtEdge() {
    final position = widget.items.position;
    if (position == null || !mounted) return;
    final box = context.findRenderObject() as RenderBox;
    final top = widget.items.top + _edge;
    final bottom = box.size.height - widget.items.bottom - _edge;
    final by = _at.dy < top ? _at.dy - top : (_at.dy > bottom ? _at.dy - bottom : 0.0);
    if (by == 0) return;
    final to = (position.pixels + by * 0.35).clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to == position.pixels) return;
    position.jumpTo(to);
    _update();
  }

  void _end(int pointer) {
    if (pointer != _pointer) return;
    _pointer = null;
    _scrolling?.cancel();
    _scrolling = null;
    if (!_active) return;
    setState(() => _active = false);
    widget.onChanged(_covered, done: true);
  }

  @override
  void dispose() {
    _scrolling?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Listener(
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (event) => _end(event.pointer),
      onPointerCancel: (event) => _end(event.pointer),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_active)
            Positioned.fromRect(
              rect: _band,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.14),
                    border: Border.all(color: colors.primary.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
