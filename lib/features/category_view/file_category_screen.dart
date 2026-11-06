import 'dart:io';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:folders/core/services/file_action_service.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Every document or archive on the device, newest first, with type
/// filters, search and sorting.
class FileCategoryScreen extends StatefulWidget {
  const FileCategoryScreen({
    super.key,
    required this.group,
    this.onShowInFolder,
    this.loader,
  });

  final DeviceFileGroup group;

  /// Opens a folder in the file explorer (called after this screen closes).
  final void Function(String folder)? onShowInFolder;

  /// Replaces [DeviceFiles.find] (tests).
  final Future<List<DeviceFile>> Function()? loader;

  @override
  State<FileCategoryScreen> createState() => _FileCategoryScreenState();
}

enum _Sort { newest, name, size }

class _Filter {
  const _Filter(this.label, this.extensions);
  final String label;
  final Set<String>? extensions;
}

class _FileCategoryScreenState extends State<FileCategoryScreen> {
  late List<DeviceFile>? _files = widget.loader == null
      ? DeviceFiles.cached(widget.group)
      : null;
  Object? _error;
  _Sort _sort = _Sort.newest;
  int _filter = 0;
  String _query = '';

  late final List<_Filter> _filters = switch (widget.group) {
    DeviceFileGroup.documents => [
      const _Filter('All', null),
      const _Filter('PDF', FileTypes.pdf),
      _Filter('Word', {
        ...FileTypes.word,
        ...FileTypes.legacyWord,
        ...FileTypes.richText,
        ...FileTypes.openDocumentText,
      }),
      _Filter('Sheets', {
        ...FileTypes.spreadsheet,
        ...FileTypes.legacySpreadsheet,
        ...FileTypes.delimited,
        ...FileTypes.openDocumentSpreadsheet,
      }),
      _Filter('Slides', {
        ...FileTypes.presentation,
        ...FileTypes.legacyPresentation,
        ...FileTypes.openDocumentPresentation,
      }),
      _Filter('Books', {
        ...FileTypes.epub,
        ...FileTypes.ebook,
        ...FileTypes.comic,
      }),
      _Filter('Text', {...FileTypes.markdown, 'txt'}),
    ],
    DeviceFileGroup.archives => [
      const _Filter('All', null),
      const _Filter('ZIP', {'zip'}),
      const _Filter('RAR', {'rar'}),
      const _Filter('7z', {'7z'}),
      const _Filter('Disk images', FileTypes.diskImage),
    ],
  };

  String get _title => switch (widget.group) {
    DeviceFileGroup.documents => 'Documents',
    DeviceFileGroup.archives => 'Archives',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final files =
          await (widget.loader?.call() ?? DeviceFiles.find(widget.group));
      if (!mounted) return;
      setState(() {
        _files = files;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<DeviceFile> _visible() {
    final filter = _filters[_filter].extensions;
    final query = _query.trim().toLowerCase();
    final list = [
      for (final f in _files ?? const <DeviceFile>[])
        if ((filter == null ||
                filter.contains(FileTypes.extensionOf(f.path))) &&
            (query.isEmpty || f.name.toLowerCase().contains(query)))
          f,
    ];
    switch (_sort) {
      case _Sort.newest:
        break;
      case _Sort.name:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case _Sort.size:
        list.sort((a, b) => b.size.compareTo(a.size));
    }
    return list;
  }

  int _count(_Filter filter) {
    final exts = filter.extensions;
    final files = _files ?? const <DeviceFile>[];
    if (exts == null) return files.length;
    return files
        .where((f) => exts.contains(FileTypes.extensionOf(f.path)))
        .length;
  }

  Future<void> _delete(DeviceFile file) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${file.name}"?'),
        content: const Text(
          "This file will be permanently deleted. This can't be undone.",
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await File(file.path).delete();
      DeviceFiles.invalidate();
      setState(() => _files = [...?_files]..remove(file));
    } on FileSystemException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Couldn't delete ${file.name}: ${e.osError?.message ?? e.message}",
          ),
        ),
      );
    }
  }

  void _showInFolder(DeviceFile file) {
    final open = widget.onShowInFolder;
    if (open == null) return;
    Navigator.pop(context);
    open(p.dirname(file.path));
  }

  @override
  Widget build(BuildContext context) {
    final top = AppTopBarScaffold.contentTopInset(context);
    final files = _files;
    return ExplorerScaffold(
      title: _title,
      trailing: PopupMenuButton<_Sort>(
        tooltip: 'Sort',
        icon: const Icon(LucideIcons.arrowUpDown, size: 20),
        initialValue: _sort,
        onSelected: (sort) => setState(() => _sort = sort),
        itemBuilder: (_) => const [
          PopupMenuItem(value: _Sort.newest, child: _MenuLabel(LucideIcons.calendarClock, 'Newest first')),
          PopupMenuItem(value: _Sort.name, child: _MenuLabel(LucideIcons.arrowDownAZ, 'Name')),
          PopupMenuItem(value: _Sort.size, child: _MenuLabel(LucideIcons.arrowDownWideNarrow, 'Largest first')),
        ],
      ),
      body: () {
        if (files == null) {
          if (_error != null) {
            return ExplorerEmptyState(
              padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
              destructive: true,
              icon: LucideIcons.circleAlert,
              title: "Couldn't list ${_title.toLowerCase()}",
              description: '$_error',
              actions: [
                FilledButton.icon(
                  onPressed: () {
                    setState(() => _error = null);
                    _load();
                  },
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: const Text('Try again'),
                ),
              ],
            );
          }
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final visible = _visible();
        return RefreshIndicator(
          edgeOffset: top,
          onRefresh: _load,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: top + 8)),
              SliverToBoxAdapter(child: _searchField(context)),
              SliverToBoxAdapter(child: _filterChips(context)),
              if (visible.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: ExplorerEmptyState(
                    padding: const EdgeInsets.all(24),
                    icon: _query.isNotEmpty
                        ? LucideIcons.searchX
                        : widget.group == DeviceFileGroup.documents
                        ? LucideIcons.fileText
                        : LucideIcons.archive,
                    title: _query.isNotEmpty
                        ? 'No matches'
                        : 'No ${_title.toLowerCase()} found',
                    description: _query.isNotEmpty
                        ? 'Nothing here matches "$_query".'
                        : widget.group == DeviceFileGroup.documents
                        ? 'PDFs, Office files, e-books and text files on '
                              'this device show up here.'
                        : 'ZIP, RAR, 7z, TAR and ISO files on this '
                              'device show up here.',
                  ),
                )
              else
                SliverList.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, i) => _FileRow(
                    file: visible[i],
                    onDelete: () => _delete(visible[i]),
                    onShowInFolder: widget.onShowInFolder == null
                        ? null
                        : () => _showInFolder(visible[i]),
                  ),
                ),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.paddingOf(context).bottom + 24,
                ),
              ),
            ],
          ),
        );
      }(),
    );
  }

  Widget _searchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search ${_title.toLowerCase()}',
          prefixIcon: const Icon(LucideIcons.search, size: 18),
          isDense: true,
        ),
      ),
    );
  }

  Widget _filterChips(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final filter = _filters[i];
          final count = _count(filter);
          return ChoiceChip(
            label: Text(count > 0 ? '${filter.label} $count' : filter.label),
            selected: _filter == i,
            showCheckmark: false,
            onSelected: (_) => setState(() => _filter = i),
          );
        },
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.onDelete,
    required this.onShowInFolder,
  });

  final DeviceFile file;
  final VoidCallback onDelete;
  final VoidCallback? onShowInFolder;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final folder = p.basename(p.dirname(file.path));
    final meta = [
      EntityFormat.size(file.size),
      EntityFormat.date(file.modified),
      if (folder.isNotEmpty && folder != '0') folder,
    ].join(' · ');
    final radius = BorderRadius.circular(8);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        borderRadius: radius,
        onTap: () => FileOpener.open(context, File(file.path)),
        onLongPress: () => FileOpener.showOpenWith(context, File(file.path)),
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                FileIcon(path: file.path, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<VoidCallback>(
                  tooltip: 'More',
                  icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: () =>
                          FileOpener.showOpenWith(context, File(file.path)),
                      child: const _MenuLabel(
                        LucideIcons.squareArrowOutUpRight,
                        'Open with…',
                      ),
                    ),
                    PopupMenuItem(
                      value: () =>
                          FileActionsService().share(context, File(file.path)),
                      child: const _MenuLabel(LucideIcons.share2, 'Share'),
                    ),
                    if (onShowInFolder != null)
                      PopupMenuItem(
                        value: onShowInFolder,
                        child: const _MenuLabel(
                          LucideIcons.folderOpen,
                          'Show in folder',
                        ),
                      ),
                    PopupMenuItem(
                      value: onDelete,
                      child: _MenuLabel(
                        LucideIcons.trash2,
                        'Delete',
                        color: context.colors.destructive,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(label, style: color == null ? null : TextStyle(color: color)),
      ],
    );
  }
}
