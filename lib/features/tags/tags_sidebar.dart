import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/file_drag_drop.dart';
import 'package:folders/features/tags/tag_actions.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

/// The sidebar's and drawer's Tags: each tag in use, and every tag made by
/// the user (Finder's colours show once something has them). A tag opens its
/// folder; right-click (a long press on phones) edits it; files dropped on
/// one get it.
class TagsSidebarSection extends StatefulWidget {
  const TagsSidebarSection({super.key});

  @override
  State<TagsSidebarSection> createState() => _TagsSidebarSectionState();
}

class _TagsSidebarSectionState extends State<TagsSidebarSection> {
  final _store = TagStore.instance;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final shown = [
          for (final tag in _store.tags)
            if (!TagStore.isBuiltIn(tag) || _store.isUsed(tag.name)) tag,
        ];
        // The tag whose folder is open.
        final open = context.select((FileExplorerBloc bloc) {
          final state = bloc.state;
          final path = switch (state) {
            FileExplorerLoaded(:final path) => path,
            FileExplorerLoading(:final path) => path,
            _ => null,
          };
          return path == null ? null : TagPaths.nameOf(path);
        });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppSidebarSection(
              'Tags',
              trailing: _NewTagButton(onPressed: () => TagActions.newTag(context)),
            ),
            if (_store.loaded && shown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 16, 6),
                child: Text(
                  Desktop.isDesktop ? 'Right-click a file to tag it.' : 'Long-press a file, then Tags.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            for (final tag in shown)
              TagSidebarItem(
                tag: tag,
                count: _store.countOf(tag.name),
                selected: open != null && TagStore.keyOf(open) == tag.key,
              ),
          ],
        );
      },
    );
  }
}

class _NewTagButton extends StatelessWidget {
  const _NewTagButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New tag',
      child: InkResponse(
        onTap: onPressed,
        radius: 14,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(LucideIcons.plus, size: 15, color: context.colors.mutedForeground),
        ),
      ),
    );
  }
}

/// One tag in the sidebar.
class TagSidebarItem extends StatefulWidget {
  const TagSidebarItem({super.key, required this.tag, required this.count, this.selected = false});

  final TagDef tag;
  final int count;
  final bool selected;

  @override
  State<TagSidebarItem> createState() => _TagSidebarItemState();
}

class _TagSidebarItemState extends State<TagSidebarItem> {
  bool _hovering = false;

  void _open() {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
    context.read<FileExplorerBloc>().add(LoadDirectory(TagPaths.of(widget.tag.name)));
  }

  void _hover(bool value) {
    if (value != _hovering && mounted) setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final selected = widget.selected;
    final fg = selected ? colors.accentForeground : colors.foreground;
    final radius = BorderRadius.circular(context.look.itemRadius);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: _open,
          onSecondaryTapUp: Desktop.isDesktop
              ? (details) => TagActions.showTagMenu(context, widget.tag, details.globalPosition, onOpen: _open)
              : null,
          onLongPress: Desktop.isDesktop ? null : () => TagActions.showTagSheet(context, widget.tag, onOpen: _open),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            foregroundDecoration: _hovering
                ? BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.10),
                    borderRadius: radius,
                    border: Border.all(color: colors.primary, width: 1.5),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                SizedBox.square(dimension: 17, child: Center(child: TagMark(tag: widget.tag, size: 10))),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.tag.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.count > 0) ...[
                  const SizedBox(width: 8),
                  Text('${widget.count}', style: text.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!Desktop.isDesktop || !nativeDragAndDrop) return row;
    // Files dropped here get the tag; nothing is copied or moved.
    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropEnter: (_) => _hover(true),
      onDropLeave: (_) => _hover(false),
      onDropEnded: (_) => _hover(false),
      onDropOver: (event) {
        final allowed = event.session.allowedOperations;
        // Never a move: the app the files come from would take them away.
        if (allowed.contains(DropOperation.copy)) return DropOperation.copy;
        if (allowed.contains(DropOperation.link)) return DropOperation.link;
        return DropOperation.none;
      },
      onPerformDrop: (event) async {
        _hover(false);
        final paths = await droppedFilePaths(event.session.items);
        if (paths.isEmpty || !context.mounted) return;
        await tagDropped(context, widget.tag, paths);
      },
      child: row,
    );
  }
}

/// Puts [tag] on files dropped on it, and says so.
Future<void> tagDropped(BuildContext context, TagDef tag, List<String> paths) async {
  final store = TagStore.instance;
  await store.ensureLoaded();
  store.setTag(paths, tag.name, on: true);
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    content: Text(paths.length == 1 ? 'Tagged "${tag.name}"' : 'Tagged ${paths.length} items "${tag.name}"'),
  ));
}
