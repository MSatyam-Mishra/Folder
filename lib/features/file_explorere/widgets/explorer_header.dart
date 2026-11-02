import 'dart:io';

import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/services/new_files.dart';
import 'package:explorer/features/file_explorere/bloc/grouping.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

import 'explorer_menu.dart';
import 'new_file_button.dart';

/// Menu icons for sorting and grouping.
IconData sortIcon(SortOption option) => switch (option) {
      SortOption.name => LucideIcons.arrowDownAZ,
      SortOption.date => LucideIcons.calendarClock,
      SortOption.size => LucideIcons.ruler,
      SortOption.type => LucideIcons.shapes,
    };

IconData groupByIcon(GroupBy groupBy) => switch (groupBy) {
      GroupBy.none => LucideIcons.list,
      GroupBy.name => LucideIcons.arrowDownAZ,
      GroupBy.date => LucideIcons.calendarClock,
      GroupBy.type => LucideIcons.shapes,
      GroupBy.size => LucideIcons.ruler,
    };

/// One folder on the way from a storage root to the current folder.
class PathCrumb {
  const PathCrumb(this.path, this.label);

  final String path;
  final String label;
}

/// Breadcrumbs from the storage root down to [path] (last = [path]).
List<PathCrumb> explorerCrumbs(
  String path, {
  Map<String, String> labels = const {},
}) {
  final crumbs = <PathCrumb>[];
  String? current = path;
  while (current != null && crumbs.length < 64) {
    crumbs.add(PathCrumb(current, _labelFor(current, labels)));
    if (_isStorageRoot(current)) break;
    current = ExplorerPaths.parentOf(current);
  }
  return crumbs.reversed.toList();
}

final _androidVolume = RegExp(r'^/storage/[^/]+$');

bool _isStorageRoot(String path) =>
    Platform.isAndroid &&
    (path == ExplorerPaths.androidInternalStorage ||
        (_androidVolume.hasMatch(path) && path != '/storage/emulated'));

String _labelFor(String path, Map<String, String> labels) {
  final label = labels[path];
  if (label != null && label.isNotEmpty) return label;
  if (Platform.isAndroid) {
    if (path == ExplorerPaths.androidInternalStorage) return 'Internal storage';
    if (_androidVolume.hasMatch(path)) return 'External (${p.basename(path)})';
  }
  return ExplorerPaths.titleForPath(path);
}

/// The explorer's header: menu button (phones), the current folder with its
/// location, and view / sort / options actions.
///
/// On phones the location is a muted line under the folder name (tap it to
/// jump to a parent folder); on wide screens it's a full breadcrumb.
class ExplorerHeader extends StatelessWidget {
  const ExplorerHeader({
    super.key,
    required this.crumbs,
    required this.wide,
    required this.onNavigate,
    this.onMenuPressed,
    this.viewMode,
    this.sortOption,
    this.sortOrder,
    this.onViewModeChanged,
    this.onSortChanged,
    this.onOptionsPressed,
    this.onNewFolder,
    this.onNewFile,
    this.onNewWindow,
    this.groupBy,
    this.onGroupByChanged,
    this.searchOpen = false,
    this.query = '',
    this.onSearch,
    this.onSearchChanged,
    this.onSearchClosed,
  });

  final List<PathCrumb> crumbs;

  /// Breadcrumb layout (wide screens with the docked sidebar).
  final bool wide;
  final ValueChanged<String> onNavigate;

  /// Opens the drawer; null when the sidebar is docked.
  final VoidCallback? onMenuPressed;

  final ViewMode? viewMode;
  final SortOption? sortOption;
  final SortOrder? sortOrder;
  final ValueChanged<ViewMode>? onViewModeChanged;
  final void Function(SortOption option, SortOrder order)? onSortChanged;
  final VoidCallback? onOptionsPressed;
  final VoidCallback? onNewFolder;

  /// The + next to New folder creates a file of this kind.
  final ValueChanged<NewFileKind>? onNewFile;

  /// Opens this folder in another window (desktop).
  final VoidCallback? onNewWindow;

  final GroupBy? groupBy;
  final ValueChanged<GroupBy>? onGroupByChanged;

  /// The search box replaces the location while [searchOpen].
  final bool searchOpen;
  final String query;
  final VoidCallback? onSearch;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onSearchClosed;

  @override
  Widget build(BuildContext context) {
    return _HeaderTheme(
      child: Padding(
        padding: EdgeInsets.only(left: wide ? 16 : 8, right: wide ? 12 : 8),
        child: Row(
          children: [
            if (onMenuPressed != null) ...[
              AppIconButton(
                icon: const Icon(LucideIcons.panelLeft),
                tooltip: 'Open menu',
                onPressed: onMenuPressed,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: searchOpen
                  ? _SearchField(
                      query: query,
                      hint: crumbs.isEmpty
                          ? 'Search'
                          : 'Search ${crumbs.last.label}',
                      onChanged: onSearchChanged,
                      onClosed: onSearchClosed,
                    )
                  : crumbs.isEmpty
                  ? Text('Files', style: AppForeground.title(context))
                  : wide
                      ? _Breadcrumb(crumbs: crumbs, onNavigate: onNavigate)
                      : _CompactTitle(crumbs: crumbs, onNavigate: onNavigate),
            ),
            const SizedBox(width: 8),
            if (!searchOpen && onSearch != null)
              AppIconButton(
                icon: const Icon(LucideIcons.search),
                tooltip: Platform.isMacOS ? 'Search (⌘F)' : 'Search (Ctrl+F)',
                onPressed: onSearch,
              ),
            if (wide && onNewFolder != null) ...[
              OutlinedButton.icon(
                onPressed: onNewFolder,
                icon: const Icon(LucideIcons.folderPlus, size: 16),
                label: const Text('New folder'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
              const SizedBox(width: 8),
              if (onNewFile != null) ...[
                NewFileButton(onCreate: onNewFile!),
                const SizedBox(width: 8),
              ],
            ],
            if (viewMode != null && onViewModeChanged != null)
              _ViewMenuButton(mode: viewMode!, onChanged: onViewModeChanged!),
            if (sortOption != null &&
                sortOrder != null &&
                onSortChanged != null)
              _SortMenuButton(
                option: sortOption!,
                order: sortOrder!,
                onChanged: onSortChanged!,
                groupBy: groupBy,
                onGroupByChanged: onGroupByChanged,
              ),
            if (onNewWindow != null)
              AppIconButton(
                icon: const Icon(LucideIcons.appWindow),
                tooltip: Platform.isMacOS ? 'New window (⌘N)' : 'New window (Ctrl+N)',
                onPressed: onNewWindow,
              ),
            if (onOptionsPressed != null)
              AppIconButton(
                icon: const Icon(LucideIcons.ellipsisVertical),
                tooltip: 'Options',
                onPressed: onOptionsPressed,
              ),
          ],
        ),
      ),
    );
  }
}

/// Header icon colour/size, and 40 px icon buttons (Material pads them to
/// 48 px tap targets otherwise, which crowds phone headers).
class _HeaderTheme extends StatelessWidget {
  const _HeaderTheme({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: IconTheme(
        data: IconThemeData(color: context.colors.foreground, size: 20),
        child: child,
      ),
    );
  }
}

/// Folder name with its parents in a muted line; tapping opens a menu of
/// the parent folders.
class _CompactTitle extends StatelessWidget {
  const _CompactTitle({required this.crumbs, required this.onNavigate});

  final List<PathCrumb> crumbs;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final current = crumbs.last;
    final parents = crumbs.sublist(0, crumbs.length - 1);
    final shown = parents.length > 2
        ? ['…', for (final c in parents.skip(parents.length - 2)) c.label]
        : [for (final c in parents) c.label];

    final title = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          current.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppForeground.title(context).copyWith(height: 1.25),
        ),
        if (parents.isNotEmpty)
          Row(
            children: [
              Flexible(
                child: Text(
                  shown.join('  /  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(height: 1.3),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                LucideIcons.chevronDown,
                size: 12,
                color: colors.mutedForeground,
              ),
            ],
          ),
      ],
    );
    if (parents.isEmpty) return title;

    return Align(
      alignment: Alignment.centerLeft,
      child: Builder(
        builder: (anchor) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final path = await ExplorerMenu.show<String>(
              anchor,
              items: [
                ExplorerMenu.label(anchor, 'Go to'),
                for (final crumb in parents.reversed)
                  ExplorerMenu.item(
                    anchor,
                    value: crumb.path,
                    label: crumb.label,
                    icon: crumb == parents.first
                        ? LucideIcons.hardDrive
                        : LucideIcons.folder,
                  ),
              ],
            );
            if (path != null) onNavigate(path);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: title,
          ),
        ),
      ),
    );
  }
}

/// "Internal storage › Download › Documents"; middle folders collapse into
/// "…" when the path is deep.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.crumbs, required this.onNavigate});

  final List<PathCrumb> crumbs;
  final ValueChanged<String> onNavigate;

  static const _maxVisible = 4;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final collapsed = crumbs.length > _maxVisible
        ? crumbs.sublist(1, crumbs.length - (_maxVisible - 2))
        : const <PathCrumb>[];
    final visible = collapsed.isEmpty
        ? crumbs
        : [crumbs.first, ...crumbs.sublist(crumbs.length - (_maxVisible - 2))];

    final separator = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Icon(
        LucideIcons.chevronRight,
        size: 14,
        color: colors.mutedForeground,
      ),
    );

    final children = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      final crumb = visible[i];
      final last = i == visible.length - 1;
      if (i > 0) children.add(separator);
      if (i == 1 && collapsed.isNotEmpty) {
        children
          ..add(_Ellipsis(crumbs: collapsed, onNavigate: onNavigate))
          ..add(separator);
      }
      children.add(
        Flexible(
          flex: last ? 3 : 1,
          child: _CrumbButton(
            label: crumb.label,
            current: last,
            onTap: last ? null : () => onNavigate(crumb.path),
          ),
        ),
      );
    }
    return Row(children: children);
  }
}

class _CrumbButton extends StatelessWidget {
  const _CrumbButton({required this.label, required this.current, this.onTap});

  final String label;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = current
        ? AppForeground.title(context)
        : Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.mutedForeground,
              fontWeight: FontWeight.w500,
            );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}

class _Ellipsis extends StatelessWidget {
  const _Ellipsis({required this.crumbs, required this.onNavigate});

  final List<PathCrumb> crumbs;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: 'Show hidden folders',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          final path = await ExplorerMenu.show<String>(
            context,
            items: [
              for (final crumb in crumbs)
                ExplorerMenu.item(
                  context,
                  value: crumb.path,
                  label: crumb.label,
                  icon: LucideIcons.folder,
                ),
            ],
          );
          if (path != null) onNavigate(path);
        },
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            LucideIcons.ellipsis,
            size: 16,
            color: colors.mutedForeground,
          ),
        ),
      ),
    );
  }
}

class _ViewMenuButton extends StatelessWidget {
  const _ViewMenuButton({required this.mode, required this.onChanged});

  final ViewMode mode;
  final ValueChanged<ViewMode> onChanged;

  static IconData iconFor(ViewMode mode) => switch (mode) {
        ViewMode.list => LucideIcons.list,
        ViewMode.grid => LucideIcons.layoutGrid,
        ViewMode.compact => LucideIcons.rows3,
        ViewMode.gallery => LucideIcons.images,
      };

  static String labelFor(ViewMode mode) => switch (mode) {
        ViewMode.list => 'List',
        ViewMode.grid => 'Grid',
        ViewMode.compact => 'Compact list',
        ViewMode.gallery => 'Gallery',
      };

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (anchor) => AppIconButton(
        icon: Icon(iconFor(mode)),
        tooltip: 'View',
        onPressed: () async {
          final picked = await ExplorerMenu.show<ViewMode>(
            anchor,
            minWidth: 180,
            items: [
              ExplorerMenu.label(anchor, 'View as'),
              for (final m in ViewMode.values)
                ExplorerMenu.item(
                  anchor,
                  value: m,
                  label: labelFor(m),
                  icon: iconFor(m),
                  checked: m == mode,
                ),
            ],
          );
          if (picked != null && picked != mode) onChanged(picked);
        },
      ),
    );
  }
}

class _SortMenuButton extends StatelessWidget {
  const _SortMenuButton({
    required this.option,
    required this.order,
    required this.onChanged,
    this.groupBy,
    this.onGroupByChanged,
  });

  final SortOption option;
  final SortOrder order;
  final void Function(SortOption option, SortOrder order) onChanged;
  final GroupBy? groupBy;
  final ValueChanged<GroupBy>? onGroupByChanged;


  static String labelFor(SortOption option) => switch (option) {
        SortOption.name => 'Name',
        SortOption.date => 'Date modified',
        SortOption.size => 'Size',
        SortOption.type => 'Type',
      };

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (anchor) => AppIconButton(
        icon: const Icon(LucideIcons.arrowUpDown),
        tooltip: onGroupByChanged == null ? 'Sort' : 'Sort and group',
        onPressed: () async {
          final picked = await ExplorerMenu.show<Object>(
            anchor,
            minWidth: 200,
            items: [
              ExplorerMenu.label(anchor, 'Sort by'),
              for (final o in SortOption.values)
                ExplorerMenu.item<Object>(
                  anchor,
                  value: o,
                  label: labelFor(o),
                  icon: sortIcon(o),
                  checked: o == option,
                ),
              ExplorerMenu.divider(),
              ExplorerMenu.item<Object>(
                anchor,
                value: SortOrder.ascending,
                label: 'Ascending',
                icon: LucideIcons.arrowUpNarrowWide,
                checked: order == SortOrder.ascending,
              ),
              ExplorerMenu.item<Object>(
                anchor,
                value: SortOrder.descending,
                label: 'Descending',
                icon: LucideIcons.arrowDownWideNarrow,
                checked: order == SortOrder.descending,
              ),
              if (onGroupByChanged != null) ...[
                ExplorerMenu.divider(),
                ExplorerMenu.label(anchor, 'Group by'),
                for (final g in GroupBy.values)
                  ExplorerMenu.item<Object>(
                    anchor,
                    value: g,
                    label: groupByLabel(g),
                    icon: groupByIcon(g),
                    checked: g == (groupBy ?? GroupBy.none),
                  ),
              ],
            ],
          );
          switch (picked) {
            case SortOption o when o != option:
              onChanged(o, order);
            case SortOrder o when o != order:
              onChanged(option, o);
            case GroupBy g when g != groupBy:
              onGroupByChanged?.call(g);
          }
        },
      ),
    );
  }
}

/// The search box in the header: what's typed goes to [onChanged] as it's
/// typed; the clear button or Esc closes it.
class _SearchField extends StatefulWidget {
  const _SearchField({
    required this.query,
    required this.hint,
    required this.onChanged,
    required this.onClosed,
  });

  final String query;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClosed;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final _controller = TextEditingController(text: widget.query);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Ready to type. `autofocus` isn't enough: it only applies when nothing
    // has the keyboard yet, and the file list has it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final border = WidgetStateInputBorder.resolveWith((states) {
      final focused = states.contains(WidgetState.focused);
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: focused ? colors.ring : colors.input),
      );
    });
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => widget.onClosed?.call(),
      },
      child: SizedBox(
        height: 38,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          onChanged: widget.onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            border: border,
            hintText: widget.hint,
            prefixIcon: const Icon(LucideIcons.search, size: 16),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: IconButton(
              icon: const Icon(LucideIcons.x, size: 16),
              tooltip: 'Close search (Esc)',
              onPressed: widget.onClosed,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
          ),
        ),
      ),
    );
  }
}

/// Header while selecting: close, count, and actions for the selection.
class ExplorerSelectionHeader extends StatelessWidget {
  const ExplorerSelectionHeader({
    super.key,
    this.hasImages = false,
    required this.count,
    required this.total,
    required this.onClose,
    required this.onShare,
    required this.onSendNearby,
    required this.onCompress,
    required this.onDelete,
    required this.onMenuAction,
    this.wide = false,
  });

  final int count;
  final int total;
  final bool wide;

  /// Pictures are selected: convert and resize them.
  final bool hasImages;
  final VoidCallback onClose;
  final VoidCallback onShare;
  final VoidCallback onSendNearby;
  final VoidCallback onCompress;
  final VoidCallback onDelete;

  /// Called with the [SelectionMenuAction] picked from "More".
  final ValueChanged<SelectionMenuAction> onMenuAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final any = count > 0;
    final single = count == 1;
    return _HeaderTheme(
      child: Padding(
        padding: EdgeInsets.only(left: wide ? 12 : 8, right: wide ? 12 : 8),
        child: Row(
          children: [
            AppIconButton(
              icon: const Icon(LucideIcons.x),
              tooltip: 'Cancel selection',
              onPressed: onClose,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                wide ? '$count of $total selected' : '$count selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppForeground.title(context),
              ),
            ),
            if (Desktop.canShareFiles)
              AppIconButton(
                icon: const Icon(LucideIcons.share2),
                tooltip: 'Share',
                onPressed: any ? onShare : null,
              ),
            AppIconButton(
              icon: const Icon(LucideIcons.radio),
              tooltip: 'Send nearby',
              onPressed: any ? onSendNearby : null,
            ),
            AppIconButton(
              icon: const Icon(LucideIcons.archive),
              tooltip: 'Compress',
              onPressed: any ? onCompress : null,
            ),
            AppIconButton(
              icon: const Icon(LucideIcons.trash2),
              tooltip: 'Delete',
              color: any ? colors.destructive : null,
              onPressed: any ? onDelete : null,
            ),
            Builder(
              builder: (anchor) => AppIconButton(
                icon: const Icon(LucideIcons.ellipsisVertical),
                tooltip: 'More actions',
                onPressed: () async {
                  final action = await ExplorerMenu.show<SelectionMenuAction>(
                    anchor,
                    items: [
                      if (count < total)
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.selectAll,
                          label: 'Select all',
                          icon: LucideIcons.listChecks,
                        ),
                      if (any)
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.clear,
                          label: 'Clear selection',
                          icon: LucideIcons.squareDashed,
                        ),
                      if (any) ...[
                        ExplorerMenu.divider(),
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.copy,
                          label: 'Copy',
                          icon: LucideIcons.copy,
                        ),
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.cut,
                          label: 'Cut',
                          icon: LucideIcons.scissors,
                        ),
                      ],
                      if (hasImages) ...[
                        ExplorerMenu.divider(),
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.convert,
                          label: 'Convert to…',
                          icon: LucideIcons.fileImage,
                        ),
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.resize,
                          label: 'Resize…',
                          icon: LucideIcons.scaling,
                        ),
                      ],
                      if (single) ...[
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.rename,
                          label: 'Rename',
                          icon: LucideIcons.pencil,
                        ),
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.properties,
                          label: 'Properties',
                          icon: LucideIcons.info,
                        ),
                        ExplorerMenu.divider(),
                        ExplorerMenu.item(
                          anchor,
                          value: SelectionMenuAction.allActions,
                          label: 'All actions…',
                          icon: LucideIcons.ellipsis,
                        ),
                      ],
                    ],
                  );
                  if (action != null) onMenuAction(action);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum SelectionMenuAction {
  selectAll,
  clear,
  copy,
  cut,
  rename,
  properties,
  allActions,
  convert,
  resize,
}
