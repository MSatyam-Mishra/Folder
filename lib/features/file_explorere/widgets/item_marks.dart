import 'package:flutter/material.dart';
import 'package:folders/features/git_status/git_porcelain.dart';
import 'package:folders/features/git_status/git_status_controller.dart';
import 'package:folders/features/git_status/git_widgets.dart';
import 'package:folders/features/tags/tag_dot.dart';
import 'package:folders/features/tags/tag_store.dart';

/// What's shown beside an item's name: its tags' dots and its Git mark.
/// Nothing at all for an item with neither.
class ItemMarks extends StatelessWidget {
  const ItemMarks({
    super.key,
    required this.path,
    this.git,
    this.gap = 6,
    this.dotSize = 9,
    this.ring,
  });

  final String path;
  final GitStatusController? git;

  /// Space before the marks, when there are any (after a name).
  final double gap;
  final double dotSize;

  /// The colour around overlapping dots: what they're drawn on.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final store = TagStore.instance;
    final git = this.git;
    return ListenableBuilder(
      listenable: git == null ? store : Listenable.merge([store, git]),
      builder: (context, _) {
        if (!store.loaded) {
          store.ensureLoaded();
        } else {
          store.lookAtSystemTags(path);
        }
        final tags = store.tagsOf(path);
        final status = git?.value;
        final mark = status?.markFor(path);
        final inside = mark == null ? status?.insideOf(path) : null;
        final showsGit = (mark != null && mark != GitMark.ignored) || inside != null;
        if (tags.isEmpty && !showsGit) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsetsDirectional.only(start: gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tags.isNotEmpty) TagDots(tags: tags, size: dotSize, ring: ring),
              if (tags.isNotEmpty && showsGit) const SizedBox(width: 5),
              if (showsGit) GitMarkBadge(mark: mark, inside: inside),
            ],
          ),
        );
      },
    );
  }
}
