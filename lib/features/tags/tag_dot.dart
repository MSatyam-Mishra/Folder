import 'package:flutter/material.dart';
import 'package:folders/features/tags/tag_color.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:folders/shared/ui/app_ui.dart';

/// A tag's dot: filled with its colour, or a ring for a tag without one.
class TagDot extends StatelessWidget {
  const TagDot({super.key, required this.color, this.size = 10, this.ring});

  final TagColor color;
  final double size;

  /// A thin edge in this colour, so overlapping dots stay apart.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final fill = color.color;
    final ring = this.ring;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: fill == null
            ? Border.all(color: context.colors.mutedForeground, width: 1.3)
            : ring == null
                ? null
                : Border.all(color: ring, width: 1.2),
      ),
    );
  }
}

/// An item's tags as overlapping dots, as Finder shows them: the first three,
/// colourless ones last.
class TagDots extends StatelessWidget {
  const TagDots({super.key, required this.tags, this.size = 10, this.ring});

  final List<TagDef> tags;
  final double size;
  final Color? ring;

  static const _max = 3;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    final sorted = [
      ...tags.where((t) => t.color != TagColor.none),
      ...tags.where((t) => t.color == TagColor.none),
    ].take(_max).toList();
    final step = size * 0.62;
    final ring = this.ring ?? context.colors.background;
    return Tooltip(
      message: tags.map((t) => t.name).join(', '),
      child: SizedBox(
        width: size + step * (sorted.length - 1),
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The first on top, as in Finder.
            for (var i = sorted.length - 1; i >= 0; i--)
              Positioned(
                left: step * i,
                child: TagDot(color: sorted[i].color, size: size, ring: sorted.length > 1 ? ring : null),
              ),
          ],
        ),
      ),
    );
  }
}
