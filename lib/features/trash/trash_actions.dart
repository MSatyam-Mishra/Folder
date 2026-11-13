import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/services/path_changes.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/file_explorere/widgets/info_row.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Deleting to the Trash, and what the Trash place does: restore, delete
/// for good, empty.
abstract final class TrashActions {
  /// What the Trash is called here: "the Recycle Bin" on Windows.
  static String get name => Trash.instance.label == 'Recycle Bin' ? 'the Recycle Bin' : 'the Trash';

  /// Moves [entities] to the Trash, with Undo in the message after. False,
  /// doing nothing, when they can't go there (no Trash, a remote place, the
  /// setting off): deleting them is then for good, after asking.
  static Future<bool> moveToTrash(BuildContext context, List<FileSystemEntity> entities) async {
    final trash = Trash.instance;
    final paths = [for (final e in entities) e.path];
    if (paths.isEmpty || !paths.every(trash.canTrash) || !await TrashSettings.enabled()) return false;
    if (!context.mounted) return true;
    final bloc = context.read<FileExplorerBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await trash.moveToTrash(paths);
    // Tags go along, so Undo or Restore brings them back.
    for (final item in result.trashed) {
      PathChanges.moved(item.originalPath, item.storedPath);
    }
    _refresh(bloc, endSelection: true);

    if (result.failed.isNotEmpty && context.mounted) {
      final failed = result.failed.keys.toList();
      final reason = result.failed.values.first;
      final forGood = await confirm(
        context,
        title: failed.length == 1
            ? '"${p.basename(failed.single)}" can\'t go to $name'
            : "${failed.length} items can't go to $name",
        message: '$reason. Delete ${failed.length == 1 ? 'it' : 'them'} for good? This can\'t be undone.',
        action: 'Delete for good',
      );
      if (forGood) {
        final repository = LocalFileRepository();
        var deleted = 0;
        for (final path in failed) {
          try {
            await repository.delete(path, recursive: true);
            deleted++;
          } catch (_) {}
        }
        _refresh(bloc);
        if (deleted < failed.length) {
          _show(messenger, "${failed.length - deleted} couldn't be deleted");
          return true;
        }
      }
    }

    final trashed = result.trashed;
    if (trashed.isEmpty) return true;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(trashed.length == 1
            ? 'Moved "${trashed.single.name}" to $name'
            : 'Moved ${trashed.length} items to $name'),
        action: SnackBarAction(label: 'Undo', onPressed: () => _undo(bloc, messenger, trashed)),
      ));
    return true;
  }

  static Future<void> _undo(FileExplorerBloc bloc, ScaffoldMessengerState messenger, List<TrashItem> items) async {
    final failed = await _restoreAll(items);
    _refresh(bloc);
    if (failed > 0) _show(messenger, "$failed couldn't be restored");
  }

  /// Restores [items]; how many couldn't be.
  static Future<int> _restoreAll(List<TrashItem> items) async {
    var failed = 0;
    for (final item in items) {
      try {
        PathChanges.moved(item.storedPath, await Trash.instance.restore(item));
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  /// Restores [items] where they were.
  static Future<void> restore(BuildContext context, List<TrashItem> items) async {
    if (items.isEmpty) return;
    final bloc = context.read<FileExplorerBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final unknown = items.where((i) => !i.canRestore).length;
    final failed = await _restoreAll([for (final i in items) if (i.canRestore) i]) + unknown;
    _refresh(bloc, endSelection: true);
    final done = items.length - failed;
    _show(
      messenger,
      failed == 0
          ? (done == 1 ? 'Restored "${items.single.name}"' : 'Restored $done items')
          : unknown == items.length
              ? "Where ${items.length == 1 ? 'it was' : 'they were'} isn't known"
              : 'Restored $done; $failed couldn\'t be',
    );
  }

  /// Deletes [items] from the Trash for good, after asking.
  static Future<void> deleteForGood(BuildContext context, List<TrashItem> items) async {
    if (items.isEmpty) return;
    final bloc = context.read<FileExplorerBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirm(
      context,
      title: items.length == 1 ? 'Delete "${items.single.name}" for good?' : 'Delete ${items.length} items for good?',
      message: "This can't be undone.",
      action: 'Delete for good',
    );
    if (!ok) return;
    var failed = 0;
    for (final item in items) {
      try {
        await Trash.instance.deleteForGood(item);
        PathChanges.deleted(item.storedPath);
      } catch (_) {
        failed++;
      }
    }
    _refresh(bloc, endSelection: true);
    if (failed > 0) _show(messenger, "$failed couldn't be deleted");
  }

  /// Empties the Trash, after asking.
  static Future<void> empty(BuildContext context) async {
    final bloc = context.read<FileExplorerBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final state = bloc.state;
    final count = state is FileExplorerLoaded && ExplorerPaths.isTrash(state.path) ? state.entities.length : 0;
    final ok = await confirm(
      context,
      title: 'Empty ${name.replaceFirst('the ', '')}?',
      message: count > 0
          ? '${count == 1 ? 'The item' : 'All $count items'} in it will be deleted for good. This can\'t be undone.'
          : "Everything in it will be deleted for good. This can't be undone.",
      action: 'Empty',
    );
    if (!ok) return;
    try {
      await Trash.instance.empty();
    } catch (e) {
      _show(messenger, "Couldn't empty it: $e");
    }
    _refresh(bloc, endSelection: true);
  }

  /// A right-click on items in the Trash.
  static Future<void> showItemMenu(BuildContext context, List<TrashItem> items, Offset position) async {
    if (items.isEmpty) return;
    final action = await ExplorerMenu.showAt<String>(
      context,
      position,
      items: [
        if (items.length > 1) ExplorerMenu.label(context, '${items.length} selected'),
        ExplorerMenu.item(context,
            value: 'restore',
            label: 'Restore',
            icon: LucideIcons.undo2,
            enabled: items.any((i) => i.canRestore)),
        if (items.length == 1)
          ExplorerMenu.item(context, value: 'details', label: 'Details', icon: LucideIcons.info, shortcut: 'Enter'),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'delete', label: 'Delete for good', icon: LucideIcons.trash2, destructive: true, shortcut: 'Delete'),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'restore':
        await restore(context, items);
      case 'details':
        await showItemSheet(context, items.single);
      case 'delete':
        await deleteForGood(context, items);
    }
  }

  /// A right-click on the Trash's empty space.
  static Future<void> showFolderMenu(BuildContext context, Offset position) async {
    final bloc = context.read<FileExplorerBloc>();
    final open = Trash.instance.openInSystem;
    final action = await ExplorerMenu.showAt<String>(
      context,
      position,
      items: [
        ExplorerMenu.item(context, value: 'all', label: 'Select all', icon: LucideIcons.listChecks),
        ExplorerMenu.item(context, value: 'refresh', label: 'Refresh', icon: LucideIcons.refreshCw, shortcut: 'F5'),
        if (open != null)
          ExplorerMenu.item(context,
              value: 'system',
              label: Platform.isMacOS ? 'Open in Finder' : 'Open in File Explorer',
              icon: LucideIcons.squareArrowOutUpRight),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context,
            value: 'empty', label: 'Empty ${name.replaceFirst('the ', '')}', icon: LucideIcons.trash2, destructive: true),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'all':
        bloc.add(SelectAll());
      case 'refresh':
        _refresh(bloc);
      case 'system':
        await open?.call();
      case 'empty':
        await empty(context);
    }
  }

  /// An item's details, with Restore and Delete for good (a tap on a phone,
  /// a double-click on a computer).
  static Future<void> showItemSheet(BuildContext context, TrashItem item) async {
    final action = await AppSheet.show<String>(context, child: _ItemSheet(item: item));
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'restore':
        await restore(context, [item]);
      case 'delete':
        await deleteForGood(context, [item]);
    }
  }

  /// Asks before something that can't be undone.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) {
        final colors = dialog.colors;
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            OutlinedButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.destructive,
                foregroundColor: colors.destructiveForeground,
              ),
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        );
      },
    );
    return ok == true;
  }

  static void _refresh(FileExplorerBloc bloc, {bool endSelection = false}) {
    if (bloc.isClosed) return;
    final state = bloc.state;
    final path = switch (state) {
      FileExplorerLoaded(:final path) => path,
      FileExplorerError(:final path?) => path,
      _ => null,
    };
    if (endSelection) bloc.add(ToggleSelectionMode(enable: false));
    if (path != null) bloc.add(LoadDirectory(path));
  }

  static void _show(ScaffoldMessengerState messenger, String message) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

class _ItemSheet extends StatelessWidget {
  const _ItemSheet({required this.item});

  final TrashItem item;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final size = item.size;
    final at = item.deletedAt;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            EntityIcon(entity: item.entity, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                InfoRow(
                  title: 'From',
                  content: item.canRestore ? item.originalFolder : 'Not known',
                  selectable: item.canRestore,
                ),
                if (at != null) InfoRow(title: 'Deleted', content: DateFormat.yMMMd().add_jm().format(at)),
                if (size != null) InfoRow(title: 'Size', content: EntityFormat.size(size)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: colors.destructive),
                onPressed: () => Navigator.pop(context, 'delete'),
                icon: const Icon(LucideIcons.trash2, size: 16),
                label: const Text('Delete for good'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: item.canRestore ? () => Navigator.pop(context, 'restore') : null,
                icon: const Icon(LucideIcons.undo2, size: 16),
                label: const Text('Restore'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
