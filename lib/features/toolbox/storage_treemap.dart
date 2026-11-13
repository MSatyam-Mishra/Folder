import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:folders/core/services/toolbox/storage_scanner.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';

/// Lays out [values] (biggest first, all above 0) in [area] as rectangles as
/// close to squares as can be: Bruls, Huizing and van Wijk's squarified
/// treemap. The rectangles come back in the order of [values], and their
/// areas are in the same proportions.
List<Rect> squarify(List<double> values, Rect area) {
  final rects = List<Rect>.filled(values.length, Rect.zero);
  if (values.isEmpty || area.width <= 0 || area.height <= 0) return rects;
  final total = values.fold<double>(0, (sum, v) => sum + v);
  if (total <= 0) return rects;
  final scale = area.width * area.height / total;
  var rest = area;
  var start = 0;
  while (start < values.length) {
    final side = math.min(rest.width, rest.height);
    // Grow the row while that makes its worst rectangle more square.
    var end = start + 1;
    var sum = values[start] * scale;
    var worst = _worst(values[start] * scale, values[start] * scale, sum, side);
    while (end < values.length) {
      final next = values[end] * scale;
      final grown = _worst(values[start] * scale, next, sum + next, side);
      if (grown > worst) break;
      worst = grown;
      sum += next;
      end++;
    }
    // The last row fills what's left, whatever rounding left over.
    if (end == values.length) sum = rest.width * rest.height;
    rest = _layRow(values, start, end, scale, sum, rest, rects);
    start = end;
  }
  return rects;
}

/// The worst aspect ratio in a row of total [sum] along [side], whose
/// biggest item is [max] and smallest [min].
double _worst(double max, double min, double sum, double side) {
  final s2 = sum * sum;
  final w2 = side * side;
  return math.max(w2 * max / s2, s2 / (w2 * min));
}

Rect _layRow(List<double> values, int start, int end, double scale, double sum, Rect rest, List<Rect> rects) {
  final rowTotal = [for (var i = start; i < end; i++) values[i] * scale].fold<double>(0, (a, b) => a + b);
  final stretch = rowTotal > 0 ? sum / rowTotal : 1.0;
  if (rest.width >= rest.height) {
    // A column down the left side.
    final width = rest.height > 0 ? math.min(rest.width, sum / rest.height) : 0.0;
    var y = rest.top;
    for (var i = start; i < end; i++) {
      final height = width > 0 ? values[i] * scale * stretch / width : 0.0;
      final bottom = i == end - 1 ? rest.bottom : math.min(rest.bottom, y + height);
      rects[i] = Rect.fromLTRB(rest.left, y, rest.left + width, bottom);
      y = bottom;
    }
    return Rect.fromLTRB(rest.left + width, rest.top, rest.right, rest.bottom);
  }
  // A row along the top.
  final height = rest.width > 0 ? math.min(rest.height, sum / rest.width) : 0.0;
  var x = rest.left;
  for (var i = start; i < end; i++) {
    final width = height > 0 ? values[i] * scale * stretch / height : 0.0;
    final right = i == end - 1 ? rest.right : math.min(rest.right, x + width);
    rects[i] = Rect.fromLTRB(x, rest.top, right, rest.top + height);
    x = right;
  }
  return Rect.fromLTRB(rest.left, rest.top + height, rest.right, rest.bottom);
}

/// The colour of each kind, the same in every style: a hue each, apart
/// enough to tell at a glance, light or dark.
abstract final class StorageColors {
  static Color of(StorageKind kind, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (kind) {
      StorageKind.videos => dark ? const Color(0xFF9F7AEA) : const Color(0xFF8B5CF6),
      StorageKind.photos => dark ? const Color(0xFF34C77B) : const Color(0xFF22B455),
      StorageKind.music => dark ? const Color(0xFFFB8C3C) : const Color(0xFFF97316),
      StorageKind.documents => dark ? const Color(0xFF5B9BF8) : const Color(0xFF3B82F6),
      StorageKind.apps => dark ? const Color(0xFFF0506E) : const Color(0xFFE11D48),
      StorageKind.archives => dark ? const Color(0xFFE8C030) : const Color(0xFFD9A406),
      StorageKind.other => dark ? const Color(0xFF7C8A9E) : const Color(0xFF9AA6B6),
    };
  }

  /// The kind that takes most of [folder].
  static StorageKind mainKindOf(StorageFolder folder) {
    var best = StorageKind.other;
    var most = -1;
    for (final kind in StorageKind.values) {
      final bytes = folder.kinds[kind.index];
      if (bytes > most) {
        most = bytes;
        best = kind;
      }
    }
    return best;
  }
}

/// One rectangle of the map: a file, a folder, or a folder's files too small
/// to show one by one ([node] null, [owner] the folder).
class TreemapTile {
  const TreemapTile(this.rect, this.depth, {this.node, required this.owner, required this.color, this.label});

  final Rect rect;

  /// 0 for what's right in the folder shown, 1 for what's in those…
  final int depth;
  final StorageNode? node;
  final StorageFolder owner;
  final Color color;
  final String? label;

  /// What's right in the folder shown that holds this tile.
  StorageNode? topIn(StorageFolder shown) {
    StorageNode? at = node ?? owner;
    while (at != null && !identical(at.parent, shown)) {
      at = at.parent;
    }
    return at;
  }
}

/// Lays out a folder's map: what's in it, and inside each folder what's in
/// that, down to [maxDepth] or until the tiles get too small to see.
List<TreemapTile> layoutTreemap(
  StorageFolder folder,
  Size size, {
  required Brightness brightness,
  int maxDepth = 3,
  double gap = 1,
}) {
  final tiles = <TreemapTile>[];
  void fill(StorageFolder at, Rect area, int depth) {
    final items = <(StorageNode?, double)>[
      for (final child in at.children)
        if (child.disk > 0) (child, child.disk.toDouble()),
      if (at.smallDisk > 0) (null, at.smallDisk.toDouble()),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    if (items.isEmpty) return;
    final rects = squarify([for (final item in items) item.$2], area);
    for (var i = 0; i < items.length; i++) {
      final node = items[i].$1;
      final rect = rects[i].deflate(gap / 2);
      if (rect.width < 1 || rect.height < 1) continue;
      switch (node) {
        case StorageFolder():
          final roomy = depth + 1 < maxDepth && rect.width > 12 && rect.height > 12;
          final header = roomy && depth == 0 && rect.height > 48 && rect.width > 64 ? 16.0 : 0.0;
          tiles.add(TreemapTile(
            rect,
            depth,
            node: node,
            owner: at,
            color: roomy
                ? Colors.transparent
                : StorageColors.of(StorageColors.mainKindOf(node), brightness),
            label: depth == 0 ? node.name : null,
          ));
          if (roomy) {
            fill(node, Rect.fromLTRB(rect.left + 2, rect.top + 2 + header, rect.right - 2, rect.bottom - 2), depth + 1);
          }
        case StorageFile():
          tiles.add(TreemapTile(
            rect,
            depth,
            node: node,
            owner: at,
            color: StorageColors.of(node.kind, brightness),
            label: depth == 0 ? node.name : null,
          ));
        case null:
          tiles.add(TreemapTile(
            rect,
            depth,
            owner: at,
            color: StorageColors.of(StorageKind.other, brightness).withValues(alpha: 0.7),
            label: depth == 0 ? '${at.smallFiles} smaller files' : null,
          ));
      }
    }
  }

  fill(folder, Offset.zero & size, 0);
  return tiles;
}

/// A folder as a treemap: every file a rectangle as big as the space it
/// takes, coloured by its kind, inside rectangles for its folders. A tap on
/// a folder opens it, a tap on a file [onPick]s it; a right-click or a long
/// press asks for its actions; on a computer the pointer shows what's under
/// it.
class StorageTreemap extends StatefulWidget {
  const StorageTreemap({
    super.key,
    required this.folder,
    required this.onOpen,
    required this.onPick,
    required this.onMenu,
    this.selected,
  });

  final StorageFolder folder;

  /// A folder right in [folder] was tapped.
  final ValueChanged<StorageFolder> onOpen;

  /// A file, or a folder's smaller files (null), was tapped.
  final ValueChanged<StorageNode?> onPick;

  /// The actions for what's under the pointer.
  final void Function(StorageNode node, Offset globalPosition) onMenu;
  final StorageNode? selected;

  @override
  State<StorageTreemap> createState() => _StorageTreemapState();
}

class _StorageTreemapState extends State<StorageTreemap> {
  List<TreemapTile> _tiles = const [];
  (StorageFolder, Size, Brightness, int)? _laidOut;
  TreemapTile? _hover;

  List<TreemapTile> _tilesFor(Size size, Brightness brightness) {
    final key = (widget.folder, size, brightness, widget.folder.disk);
    if (_laidOut != key) {
      _laidOut = key;
      _tiles = layoutTreemap(widget.folder, size, brightness: brightness);
      _hover = null;
    }
    return _tiles;
  }

  /// The deepest tile at [point].
  TreemapTile? _tileAt(Offset point) {
    for (var i = _tiles.length - 1; i >= 0; i--) {
      if (_tiles[i].rect.contains(point)) return _tiles[i];
    }
    return null;
  }

  void _tap(Offset point) {
    final tile = _tileAt(point);
    if (tile == null) return;
    final top = tile.topIn(widget.folder);
    if (top is StorageFolder) {
      widget.onOpen(top);
    } else {
      widget.onPick(top);
    }
  }

  void _menu(Offset local, Offset global) {
    final tile = _tileAt(local);
    final node = tile?.node;
    if (node != null) widget.onMenu(node, global);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final text = theme.textTheme;
    final hover = _hover;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final tiles = _tilesFor(size, brightness);
        final hoverNode = hover?.node;
        return Stack(
          children: [
            Semantics(
              label: 'Map of ${widget.folder.name}',
              child: MouseRegion(
                onHover: (event) {
                  final tile = _tileAt(event.localPosition);
                  if (!identical(tile, _hover)) setState(() => _hover = tile);
                },
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _tap(details.localPosition),
                  onLongPressStart: (details) => _menu(details.localPosition, details.globalPosition),
                  onSecondaryTapUp: (details) => _menu(details.localPosition, details.globalPosition),
                  child: CustomPaint(
                    size: size,
                    painter: _TreemapPainter(
                      tiles: tiles,
                      hover: hover,
                      selected: widget.selected,
                      line: theme.colorScheme.surface,
                      frame: theme.colorScheme.outlineVariant,
                      onFrame: theme.colorScheme.onSurface,
                      labelStyle: (text.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
            if (hover != null)
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(
                          hoverNode == null
                              ? '${hover.owner.smallFiles} smaller files in ${hover.owner.name} · '
                                  '${EntityFormat.size(hover.owner.smallDisk)}'
                              : '${hoverNode.name} · ${EntityFormat.size(hoverNode.disk)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TreemapPainter extends CustomPainter {
  _TreemapPainter({
    required this.tiles,
    required this.hover,
    required this.selected,
    required this.line,
    required this.frame,
    required this.onFrame,
    required this.labelStyle,
  });

  final List<TreemapTile> tiles;
  final TreemapTile? hover;
  final StorageNode? selected;
  final Color line;
  final Color frame;

  /// Text on a folder's own strip.
  final Color onFrame;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint();
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = frame;
    for (final tile in tiles) {
      final rect = tile.rect;
      if (tile.color.a == 0) {
        // A folder with its contents inside: a frame and a faint ground.
        fill.shader = null;
        fill.color = frame.withValues(alpha: 0.18);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), fill);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), outline);
      } else {
        // A cushion: lighter at the top left, so neighbours stand apart. The
        // paint's own colour must be opaque, or it fades the shader.
        fill.color = const Color(0xFFFFFFFF);
        fill.shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(tile.color, Colors.white, 0.18)!, tile.color],
        ).createShader(rect);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.shortestSide > 8 ? 2 : 0)), fill);
      }
      final label = tile.label;
      if (label != null && rect.width > 44 && rect.height > 16) {
        _label(canvas, rect, label, onColor: tile.color.a > 0, size: tile.node?.disk ?? tile.owner.smallDisk);
      }
    }
    fill.shader = null;
    final picked = selected;
    if (picked != null) {
      for (final tile in tiles) {
        if (identical(tile.node, picked)) {
          canvas.drawRect(
            tile.rect.deflate(1),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = Colors.white,
          );
          canvas.drawRect(
            tile.rect.deflate(1),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = Colors.black,
          );
        }
      }
    }
    final hover = this.hover;
    if (hover != null) {
      canvas.drawRect(
        hover.rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: 0.9),
      );
    }
  }

  /// A tile's name and size: on two lines in a tile of colour that's tall
  /// enough, on one in a folder's strip above what it holds.
  void _label(Canvas canvas, Rect rect, String name, {required bool onColor, required int size}) {
    final style = onColor
        ? labelStyle.copyWith(shadows: const [Shadow(blurRadius: 2, color: Color(0x99000000))])
        : labelStyle.copyWith(color: onFrame);
    final twoLines = onColor && rect.height > 32;
    final painter = TextPainter(
      text: TextSpan(
        text: name,
        style: style.copyWith(fontWeight: FontWeight.w600),
        children: [
          TextSpan(
            text: '${twoLines ? '\n' : '  '}${EntityFormat.size(size)}',
            style: style.copyWith(color: style.color?.withValues(alpha: 0.8)),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
      maxLines: twoLines ? 2 : 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, rect.width - 8));
    if (painter.height > rect.height - 2) return;
    painter.paint(canvas, rect.topLeft + const Offset(4, 2));
    painter.dispose();
  }

  @override
  bool shouldRepaint(_TreemapPainter old) =>
      !identical(old.tiles, tiles) || old.hover != hover || old.selected != selected || old.line != line;
}
