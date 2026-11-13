import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/remote/place_editor.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The sidebar's (computers) and the drawer's (phones) "Network" section:
/// the saved places, then "Add a place". A right-click or a long press on
/// a place opens, edits, renames or removes it.
class NetworkPlacesSection extends StatefulWidget {
  const NetworkPlacesSection({super.key});

  @override
  State<NetworkPlacesSection> createState() => _NetworkPlacesSectionState();
}

enum _PlaceAction { open, newTab, edit, rename, remove }

class _NetworkPlacesSectionState extends State<NetworkPlacesSection> {
  final _places = RemotePlaces.instance;

  @override
  void initState() {
    super.initState();
    _places.addListener(_changed);
    _places.load();
  }

  @override
  void dispose() {
    _places.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _dismissDrawer() {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  void _open(RemoteConnection place) {
    _dismissDrawer();
    context.read<FileExplorerBloc>().add(LoadDirectory(RemotePaths.build(place.id, place.rootPath)));
  }

  Future<void> _add() async {
    final bloc = context.read<FileExplorerBloc>();
    _dismissDrawer();
    final saved = await showPlaceEditor(context);
    if (saved != null && !bloc.isClosed) bloc.add(LoadDirectory(RemotePaths.build(saved.id, saved.rootPath)));
  }

  Future<void> _menu(RemoteConnection place, Offset? position) async {
    final tabs = ExplorerTabs.instance.enabled;
    // Built in: nothing to edit or remove.
    final fixed = _places.isBuiltIn(place.id);
    final _PlaceAction? action;
    if (position != null && Desktop.isDesktop) {
      action = await ExplorerMenu.showAt<_PlaceAction>(
        context,
        position,
        items: [
          ExplorerMenu.item(context, value: _PlaceAction.open, label: 'Open', icon: LucideIcons.folderOpen),
          if (tabs)
            ExplorerMenu.item(context, value: _PlaceAction.newTab, label: 'Open in new tab', icon: LucideIcons.squarePlus),
          if (!fixed) ...[
            ExplorerMenu.divider(),
            ExplorerMenu.item(context, value: _PlaceAction.edit, label: 'Edit…', icon: LucideIcons.settings2),
            ExplorerMenu.item(context, value: _PlaceAction.rename, label: 'Rename…', icon: LucideIcons.pencil),
            ExplorerMenu.divider(),
            ExplorerMenu.item(context,
                value: _PlaceAction.remove, label: 'Remove', icon: LucideIcons.trash2, destructive: true),
          ],
        ],
      );
    } else {
      action = await AppSheet.show<_PlaceAction>(
        context,
        child: Builder(
          builder: (sheet) {
            Widget row(_PlaceAction value, IconData icon, String label, {bool destructive = false}) {
              final color = destructive ? sheet.colors.destructive : null;
              return ListTile(
                leading: Icon(icon, size: 18, color: color),
                title: Text(label, style: TextStyle(color: color)),
                onTap: () => Navigator.pop(sheet, value),
              );
            }

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(place.name, style: Theme.of(sheet).textTheme.titleMedium),
                ),
                row(_PlaceAction.open, LucideIcons.folderOpen, 'Open'),
                if (tabs) row(_PlaceAction.newTab, LucideIcons.squarePlus, 'Open in new tab'),
                if (!fixed) ...[
                  row(_PlaceAction.edit, LucideIcons.settings2, 'Edit'),
                  row(_PlaceAction.rename, LucideIcons.pencil, 'Rename'),
                  row(_PlaceAction.remove, LucideIcons.trash2, 'Remove', destructive: true),
                ],
              ],
            );
          },
        ),
      );
    }
    if (action == null || !mounted) return;
    switch (action) {
      case _PlaceAction.open:
        _open(place);
      case _PlaceAction.newTab:
        ExplorerTabs.instance.open(RemotePaths.build(place.id, place.rootPath));
      case _PlaceAction.edit:
        await showPlaceEditor(context, place: place);
      case _PlaceAction.rename:
        await _rename(place);
      case _PlaceAction.remove:
        await _remove(place);
    }
  }

  Future<void> _rename(RemoteConnection place) async {
    final controller = TextEditingController(text: place.name)
      ..selection = TextSelection(baseOffset: 0, extentOffset: place.name.length);
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Rename place'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (value) => Navigator.pop(dialog, value),
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(dialog), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, controller.text), child: const Text('Rename')),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) await _places.rename(place.id, name);
  }

  Future<void> _remove(RemoteConnection place) async {
    final bloc = context.read<FileExplorerBloc>();
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Remove "${place.name}"?'),
        content: const Text('Folders forgets this place and its saved password. Nothing on it is deleted.'),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure != true) return;
    await RemotePool.instance.close(place.id);
    await _places.remove(place.id);
    // Not left looking at a place that's gone.
    final state = bloc.state;
    final path = switch (state) {
      FileExplorerLoaded(:final path) => path,
      FileExplorerError(:final path) => path,
      _ => null,
    };
    if (!bloc.isClosed && path != null && RemotePaths.parse(path)?.$1 == place.id) {
      bloc.add(LoadDirectory(ExplorerPaths.initialPath));
    }
  }

  @override
  Widget build(BuildContext context) {
    final places = [..._places.builtIn, ..._places.places];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSidebarSection('Network'),
        for (final place in places)
          GestureDetector(
            key: ValueKey('place-${place.id}'),
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (details) => _menu(place, details.globalPosition),
            onLongPress: () => _menu(place, null),
            child: AppSidebarItem(
              icon: RemoteProtocols.of(place.protocol)?.icon ?? LucideIcons.server,
              label: place.name,
              detail: place.host.isNotEmpty && place.host != place.name ? place.host : null,
              onTap: () => _open(place),
            ),
          ),
        AppSidebarItem(
          key: const ValueKey('add-place'),
          icon: LucideIcons.circlePlus,
          label: 'Add a place',
          detail: places.isEmpty ? 'SFTP, FTP, WebDAV and more' : null,
          onTap: _add,
        ),
      ],
    );
  }
}
