import 'package:flutter/material.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/tags/tag_color.dart';
import 'package:folders/features/tags/tag_dot.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What's picked in "Tags ▸"; see [TagActions.handle].
sealed class TagChoice {
  const TagChoice();
}

final class ToggleTagChoice extends TagChoice {
  const ToggleTagChoice(this.name);

  final String name;
}

final class NewTagChoice extends TagChoice {
  const NewTagChoice();
}

final class ClearTagsChoice extends TagChoice {
  const ClearTagsChoice();
}

/// A tag's name and colour, from [TagEditor].
typedef TagEdit = ({String name, TagColor color});

/// Tagging items, and making, editing and deleting tags.
abstract final class TagActions {
  /// "Tags ▸" for a right-click menu on [paths]: each tag, ticked when they
  /// all have it, then New tag… and Remove all tags. Null if [context] went
  /// away while the tags loaded. Hand what's picked to [handle].
  static Future<PopupMenuEntry<Object>?> menuEntry(BuildContext context, List<String> paths) async {
    final store = TagStore.instance;
    await store.ensureLoaded();
    if (!context.mounted || paths.isEmpty || !paths.every(TagStore.canTag)) return null;
    final anyTagged = paths.any((path) => store.tagsOf(path).isNotEmpty);
    return ExplorerMenu.submenu<Object>(
      context,
      label: 'Tags',
      icon: LucideIcons.tag,
      items: [
        for (final tag in store.tags)
          tagMenuItem<Object>(context, value: ToggleTagChoice(tag.name), tag: tag, state: store.stateOf(paths, tag.name)),
        if (store.tags.isNotEmpty) ExplorerMenu.divider(),
        ExplorerMenu.item(context, value: const NewTagChoice(), label: 'New tag…', icon: LucideIcons.tagPlus),
        if (anyTagged)
          ExplorerMenu.item(context, value: const ClearTagsChoice(), label: 'Remove all tags', icon: LucideIcons.tagX),
      ],
    );
  }

  /// Does what was picked from [menuEntry] to [paths]; false when [choice]
  /// isn't a tag's.
  static Future<bool> handle(BuildContext context, Object? choice, List<String> paths) async {
    if (choice is! TagChoice) return false;
    final store = TagStore.instance;
    await store.ensureLoaded();
    switch (choice) {
      case ToggleTagChoice(:final name):
        store.toggle(paths, name);
      case NewTagChoice():
        if (context.mounted) await newTag(context, tagging: paths);
      case ClearTagsChoice():
        final tags = {for (final path in paths) ...store.tagsOf(path)};
        for (final tag in tags) {
          store.setTag(paths, tag.name, on: false);
        }
    }
    return true;
  }

  /// A menu row for [tag]: its dot, its name, and a tick when [state] is
  /// all (a dash for some).
  static PopupMenuItem<T> tagMenuItem<T>(
    BuildContext context, {
    required T value,
    required TagDef tag,
    TagState state = TagState.none,
  }) {
    final colors = context.colors;
    return PopupMenuItem<T>(
      value: value,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          SizedBox.square(dimension: 16, child: Center(child: TagMark(tag: tag))),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tag.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.popoverForeground),
            ),
          ),
          if (state != TagState.none) ...[
            const SizedBox(width: 12),
            Icon(state == TagState.all ? LucideIcons.check : LucideIcons.minus, size: 16, color: colors.foreground),
          ],
        ],
      ),
    );
  }

  /// A sheet (phones) or dialog listing the tags with ticks, for [paths];
  /// each tap puts a tag on or takes it off at once.
  static Future<void> showPicker(BuildContext context, List<String> paths) async {
    await TagStore.instance.ensureLoaded();
    final taggable = paths.where(TagStore.canTag).toList();
    if (!context.mounted || taggable.isEmpty) return;
    await AppSheet.show<void>(context, child: TagPicker(paths: taggable));
  }

  /// Asks for a new tag's name and colour, makes it and puts it on [tagging].
  static Future<TagDef?> newTag(BuildContext context, {List<String> tagging = const []}) async {
    final store = TagStore.instance;
    await store.ensureLoaded();
    if (!context.mounted) return null;
    final edit = await AppSheet.show<TagEdit>(
      context,
      child: TagEditor(
        title: 'New tag',
        confirmLabel: 'Create',
        validate: (name) => store.problemWith(name),
      ),
    );
    if (edit == null || store.problemWith(edit.name) != null) return null;
    final tag = store.addTag(edit.name, color: edit.color);
    if (tagging.isNotEmpty) store.setTag(tagging, tag.name, on: true);
    return tag;
  }

  /// Renames and recolours [tag].
  static Future<void> edit(BuildContext context, TagDef tag) async {
    final store = TagStore.instance;
    final edit = await AppSheet.show<TagEdit>(
      context,
      child: TagEditor(
        title: 'Edit tag',
        confirmLabel: 'Save',
        initialName: tag.name,
        initialColor: tag.color,
        validate: (name) => store.problemWith(name, renaming: tag.name),
      ),
    );
    if (edit == null || store.problemWith(edit.name, renaming: tag.name) != null) return;
    if (edit.name.trim() != tag.name) store.renameTag(tag.name, edit.name);
    store.recolorTag(edit.name, edit.color);
  }

  /// Asks, then deletes [tag] (the items stay; they lose the tag).
  static Future<bool> delete(BuildContext context, TagDef tag) async {
    final count = TagStore.instance.countOf(tag.name);
    final sure = await AppSheet.show<bool>(context, child: _DeleteTag(tag: tag, count: count));
    if (sure != true) return false;
    TagStore.instance.deleteTag(tag.name);
    return true;
  }

  /// Right-click on a tag: open it, edit it, change its colour or delete it.
  static Future<void> showTagMenu(
    BuildContext context,
    TagDef tag,
    Offset position, {
    required VoidCallback onOpen,
  }) async {
    final choice = await ExplorerMenu.showAt<Object>(context, position, items: [
      ExplorerMenu.item(context, value: 'open', label: 'Open', icon: LucideIcons.folderOpen),
      ExplorerMenu.divider(),
      ExplorerMenu.item(context, value: 'edit', label: 'Rename…', icon: LucideIcons.pencil),
      ExplorerMenu.submenu<Object>(context, label: 'Colour', icon: LucideIcons.palette, items: [
        for (final color in [TagColor.none, ...TagColor.ordered])
          tagMenuItem<Object>(
            context,
            value: color,
            tag: TagDef(color.label, color),
            state: tag.color == color ? TagState.all : TagState.none,
          ),
      ]),
      ExplorerMenu.divider(),
      ExplorerMenu.item(context, value: 'delete', label: 'Delete tag', icon: LucideIcons.trash2, destructive: true),
    ]);
    if (!context.mounted) return;
    switch (choice) {
      case 'open':
        onOpen();
      case 'edit':
        await edit(context, tag);
      case 'delete':
        await delete(context, tag);
      case TagColor color:
        TagStore.instance.recolorTag(tag.name, color);
    }
  }

  /// Phones: a long press on a tag.
  static Future<void> showTagSheet(BuildContext context, TagDef tag, {required VoidCallback onOpen}) {
    return AppSheet.show<void>(
      context,
      child: Builder(builder: (sheet) {
        void run(Future<void> Function() action) {
          Navigator.pop(sheet);
          action();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              TagMark(tag: tag, size: 14),
              const SizedBox(width: 10),
              Expanded(child: Text(tag.name, style: Theme.of(sheet).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 8),
            _SheetRow(icon: LucideIcons.folderOpen, label: 'Open', onTap: () => run(() async => onOpen())),
            _SheetRow(icon: LucideIcons.pencil, label: 'Rename or change colour', onTap: () => run(() => edit(context, tag))),
            _SheetRow(
              icon: LucideIcons.trash2,
              label: 'Delete tag',
              destructive: true,
              onTap: () => run(() async => delete(context, tag)),
            ),
          ],
        );
      }),
    );
  }
}

/// A tag's mark in menus and lists: its dot, or a tag icon when it has no
/// colour.
class TagMark extends StatelessWidget {
  const TagMark({super.key, required this.tag, this.size = 11});

  final TagDef tag;
  final double size;

  @override
  Widget build(BuildContext context) => tag.color == TagColor.none
      ? Icon(LucideIcons.tag, size: size + 3, color: context.colors.mutedForeground)
      : TagDot(color: tag.color, size: size);
}

/// The tags, ticked as [paths] have them; a tap puts one on or takes it
/// off at once.
class TagPicker extends StatelessWidget {
  const TagPicker({super.key, required this.paths});

  final List<String> paths;

  @override
  Widget build(BuildContext context) {
    final store = TagStore.instance;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tags', style: text.titleLarge),
          const SizedBox(height: 2),
          Text(
            paths.length == 1 ? p.basename(paths.single) : '${paths.length} items',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final tag in store.tags)
            _PickRow(
              leading: TagMark(tag: tag, size: 12),
              label: tag.name,
              state: store.stateOf(paths, tag.name),
              onTap: () => store.toggle(paths, tag.name),
            ),
          Divider(height: 17, color: context.colors.border),
          _PickRow(
            leading: Icon(LucideIcons.tagPlus, size: 16, color: context.colors.mutedForeground),
            label: 'New tag…',
            onTap: () => TagActions.newTag(context, tagging: paths),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ),
        ],
      ),
    );
  }
}

class _PickRow extends StatelessWidget {
  const _PickRow({required this.leading, required this.label, required this.onTap, this.state});

  final Widget leading;
  final String label;
  final VoidCallback onTap;

  /// A tick box when given.
  final TagState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: SizedBox(
          height: 36,
          child: Row(
            children: [
              SizedBox.square(dimension: 20, child: Center(child: leading)),
              const SizedBox(width: 12),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (state != null)
                Checkbox(
                  tristate: true,
                  value: switch (state) {
                    TagState.all => true,
                    TagState.some => null,
                    TagState.none => false,
                  },
                  onChanged: (_) => onTap(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tag's name and colour, for a new tag or to edit one; pops a [TagEdit].
class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.title,
    required this.confirmLabel,
    required this.validate,
    this.initialName = '',
    this.initialColor = TagColor.none,
  });

  final String title;
  final String confirmLabel;
  final String? Function(String name) validate;
  final String initialName;
  final TagColor initialColor;

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  late final _name = TextEditingController(text: widget.initialName)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initialName.length);
  late TagColor _color = widget.initialColor;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final problem = widget.validate(_name.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop<TagEdit>(context, (name: _name.text.trim(), color: _color));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: text.titleLarge),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Name',
            errorText: _error,
            prefixIcon: const Icon(LucideIcons.tag, size: 16),
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        Text('Colour', style: text.labelMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final color in [TagColor.none, ...TagColor.ordered])
              _Swatch(color: color, selected: color == _color, onTap: () => setState(() => _color = color)),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
          ],
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap});

  final TagColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fill = color.color;
    return Tooltip(
      message: color.label,
      child: InkResponse(
        onTap: onTap,
        radius: 20,
        child: Container(
          width: 30,
          height: 30,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? colors.ring : Colors.transparent, width: 2),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill ?? colors.muted,
              border: fill == null ? Border.all(color: colors.mutedForeground) : null,
            ),
            child: fill == null
                ? Icon(LucideIcons.ban, size: 13, color: colors.mutedForeground)
                : selected
                    ? const Icon(LucideIcons.check, size: 13, color: Colors.white)
                    : null,
          ),
        ),
      ),
    );
  }
}

class _DeleteTag extends StatelessWidget {
  const _DeleteTag({required this.tag, required this.count});

  final TagDef tag;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Delete the tag "${tag.name}"?', style: text.titleLarge),
        const SizedBox(height: 8),
        Text(
          count == 0
              ? 'Nothing has this tag.'
              : '${count == 1 ? 'One item loses' : '$count items lose'} this tag. The items themselves stay where they are.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: colors.destructive, foregroundColor: colors.destructiveForeground),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.icon, required this.label, required this.onTap, this.destructive = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = destructive ? colors.destructive : colors.foreground;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(children: [
          Icon(icon, size: 18, color: destructive ? color : context.look.iconColor(icon, colors.mutedForeground)),
          const SizedBox(width: 14),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color))),
        ]),
      ),
    );
  }
}
