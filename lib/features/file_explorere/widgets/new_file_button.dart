import 'package:folders/core/services/new_files.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/file_explorere/widgets/file_list_item.dart' show SelectionCheck;
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The + next to New folder: a menu of the kinds of file to create. Its first
/// row, with the settings icon, chooses which kinds the menu has.
class NewFileButton extends StatelessWidget {
  const NewFileButton({super.key, required this.onCreate});

  final ValueChanged<NewFileKind> onCreate;

  static const _settings = Object();

  Future<void> _open(BuildContext context) async {
    final chosen = await NewFiles.chosen();
    if (!context.mounted) return;
    final colors = context.colors;
    final picked = await ExplorerMenu.show<Object>(
      context,
      minWidth: 240,
      items: [
        PopupMenuItem<Object>(
          value: _settings,
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(child: Text('New file', style: Theme.of(context).textTheme.labelMedium)),
              Tooltip(
                message: 'Choose file types',
                child: Icon(LucideIcons.settings, size: 15, color: colors.mutedForeground),
              ),
            ],
          ),
        ),
        ExplorerMenu.divider<Object>(),
        for (final kind in NewFiles.kinds)
          if (chosen.contains(kind.extension))
            ExplorerMenu.item<Object>(context, value: kind, label: kind.menuLabel, icon: kind.icon),
      ],
    );
    if (!context.mounted) return;
    if (identical(picked, _settings)) {
      await AppSheet.show<void>(context, child: _FileTypesPicker(initial: chosen));
    } else if (picked is NewFileKind) {
      onCreate(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New file',
      child: Builder(
        // The menu opens under the button itself.
        builder: (context) => OutlinedButton(
          onPressed: () => _open(context),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(36, 36),
            maximumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
          ),
          child: const Icon(LucideIcons.plus, size: 16),
        ),
      ),
    );
  }
}

/// Where there's no room for the buttons in the header (a phone): what to
/// create, in a sheet. Its first row has the settings icon, as in the menu of
/// [NewFileButton]. Without [onNewFolder], only files are offered.
Future<void> showNewItemSheet(
  BuildContext context, {
  VoidCallback? onNewFolder,
  required ValueChanged<NewFileKind> onNewFile,
}) async {
  final picked = await AppSheet.show<Object>(
    context,
    child: _NewItemList(withFolder: onNewFolder != null),
  );
  if (picked is NewFileKind) {
    onNewFile(picked);
  } else if (identical(picked, _NewItemList.folder)) {
    onNewFolder?.call();
  }
}

class _NewItemList extends StatefulWidget {
  const _NewItemList({required this.withFolder});

  static const folder = Object();

  final bool withFolder;

  @override
  State<_NewItemList> createState() => _NewItemListState();
}

class _NewItemListState extends State<_NewItemList> {
  Set<String>? _chosen;

  Future<void> _load() async {
    final chosen = await NewFiles.chosen();
    if (mounted) setState(() => _chosen = chosen);
  }

  /// The list stays open and follows what's ticked.
  Future<void> _chooseTypes() async {
    await AppSheet.show<void>(context, child: _FileTypesPicker(initial: _chosen ?? const {}));
    await _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Widget _row(Object value, IconData icon, String label) {
    final colors = context.colors;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20, color: context.look.iconColor(icon, colors.mutedForeground)),
      title: Text(label),
      onTap: () => Navigator.pop(context, value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chosen = _chosen ?? const <String>{};
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('New', style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'Choose file types',
              icon: const Icon(LucideIcons.settings, size: 20),
              onPressed: _chooseTypes,
            ),
          ],
        ),
        if (widget.withFolder) _row(_NewItemList.folder, LucideIcons.folderPlus, 'New folder'),
        for (final kind in NewFiles.kinds)
          if (chosen.contains(kind.extension)) _row(kind, kind.icon, kind.menuLabel),
      ],
    );
  }
}

/// A checkbox for every kind of file; the ticked ones are in the + menu.
class _FileTypesPicker extends StatefulWidget {
  const _FileTypesPicker({required this.initial});

  final Set<String> initial;

  @override
  State<_FileTypesPicker> createState() => _FileTypesPickerState();
}

class _FileTypesPickerState extends State<_FileTypesPicker> {
  late final _chosen = {...widget.initial};

  void _toggle(String extension) {
    setState(() {
      if (!_chosen.remove(extension)) _chosen.add(extension);
    });
    NewFiles.setChosen(_chosen);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('File types', style: text.titleMedium),
        const SizedBox(height: 4),
        Text('The ticked ones show in the + menu.', style: text.bodySmall),
        for (final MapEntry(key: group, value: kinds) in NewFiles.grouped.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(group, style: text.labelMedium),
          ),
          for (final kind in kinds)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => _toggle(kind.extension),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                child: Row(
                  children: [
                    SelectionCheck(selected: _chosen.contains(kind.extension), size: 16),
                    const SizedBox(width: 10),
                    Icon(kind.icon, size: 16, color: context.look.iconColor(kind.icon, colors.mutedForeground)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(kind.menuLabel, style: text.bodyMedium)),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
