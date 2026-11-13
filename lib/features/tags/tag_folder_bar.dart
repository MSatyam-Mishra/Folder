import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/tags/tag_actions.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Above a tag's folder: the tag, with Rename and Delete. The folder is
/// listed again when items get or lose the tag, and follows the tag when
/// it's renamed (home when it's deleted).
class TagFolderBar extends StatefulWidget {
  const TagFolderBar({super.key, required this.path});

  static const double height = 48;

  final String path;

  @override
  State<TagFolderBar> createState() => _TagFolderBarState();
}

class _TagFolderBarState extends State<TagFolderBar> {
  final _store = TagStore.instance;
  Set<String> _paths = const {};

  String get _name => TagPaths.nameOf(widget.path) ?? '';

  Set<String> _snapshot() => _store.pathsWith(_name).toSet();

  @override
  void initState() {
    super.initState();
    _paths = _snapshot();
    _store.addListener(_changed);
    _store.ensureLoaded();
  }

  @override
  void didUpdateWidget(TagFolderBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _paths = _snapshot();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted || !_store.loaded) return;
    final bloc = context.read<FileExplorerBloc>();
    if (_store.tagNamed(_name) == null) {
      final renamed = _store.renamedTo(_name);
      // Deleted: back to where tags' folders sit (This PC, or the home folder).
      bloc.add(LoadDirectory(renamed == null ? ExplorerPaths.parentOf(widget.path)! : TagPaths.of(renamed)));
      return;
    }
    final now = _snapshot();
    if (!setEquals(now, _paths)) {
      _paths = now;
      bloc.add(LoadDirectory(widget.path));
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tag = _store.tagNamed(_name) ?? TagDef(_name);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: colors.background.withValues(alpha: colors.background.a * 0.82),
          child: SizedBox(
            height: TagFolderBar.height,
            child: Padding(
              padding: const EdgeInsets.only(left: 18, right: 8),
              child: Row(
                children: [
                  TagMark(tag: tag, size: 12),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tag.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  AppIconButton(
                    icon: const Icon(LucideIcons.pencil, size: 17),
                    tooltip: 'Rename or change colour',
                    onPressed: () => TagActions.edit(context, tag),
                  ),
                  AppIconButton(
                    icon: const Icon(LucideIcons.trash2, size: 17),
                    tooltip: 'Delete tag',
                    onPressed: () => TagActions.delete(context, tag),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
