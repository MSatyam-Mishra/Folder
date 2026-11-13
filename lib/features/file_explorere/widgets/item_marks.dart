import 'package:flutter/material.dart';
import 'package:folders/features/tags/tag_dot.dart';
import 'package:folders/features/tags/tag_store.dart';

/// What's shown beside an item's name: its tags' dots. Nothing at all for an
/// item without tags.
class ItemMarks extends StatelessWidget {
  const ItemMarks({
    super.key,
    required this.path,
    this.gap = 6,
    this.dotSize = 9,
    this.ring,
  });

  final String path;

  /// Space before the marks, when there are any (after a name).
  final double gap;
  final double dotSize;

  /// The colour around overlapping dots: what they're drawn on.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final store = TagStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.loaded) {
          store.ensureLoaded();
        } else {
          store.lookAtSystemTags(path);
        }
        final tags = store.tagsOf(path);
        if (tags.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsetsDirectional.only(start: gap),
          child: TagDots(tags: tags, size: dotSize, ring: ring),
        );
      },
    );
  }
}
