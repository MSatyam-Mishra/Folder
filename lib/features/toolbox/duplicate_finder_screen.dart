import 'dart:io';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/services/toolbox/duplicate_finder.dart';
import 'package:explorer/features/file_explorere/widgets/entity_meta.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart' show SelectionCheck;
import 'package:explorer/features/toolbox/toolbox_menu.dart';
import 'package:explorer/shared/file_icons/file_thumbnail.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Finds files with the same contents. Every copy but the oldest is ticked,
/// and what stays ticked can be deleted.
class DuplicateFinderScreen extends StatefulWidget {
  const DuplicateFinderScreen({super.key, this.folder});

  /// Where to look at first; else the phone's storage or the home folder.
  final String? folder;

  @override
  State<DuplicateFinderScreen> createState() => _DuplicateFinderScreenState();
}

class _DuplicateFinderScreenState extends State<DuplicateFinderScreen> {
  late String _folder = widget.folder ?? ExplorerPaths.homePath;
  DuplicateSearch? _search;
  DuplicateProgress? _progress;
  List<DuplicateGroup>? _groups;
  final _chosen = <String>{};
  bool _deleting = false;
  String? _result;

  Future<void> _start() async {
    final search = _search = DuplicateSearch(_folder, onProgress: (progress) {
      if (mounted) setState(() => _progress = progress);
    });
    setState(() {
      _groups = null;
      _progress = null;
      _result = null;
    });
    final groups = await search.start();
    if (!mounted || groups == null || !identical(_search, search)) return;
    setState(() {
      _search = null;
      _groups = groups;
      _chosen
        ..clear()
        ..addAll([
          for (final group in groups)
            for (final file in group.files.skip(1)) file.path,
        ]);
    });
  }

  void _stop() {
    _search?.cancel();
    setState(() => _search = null);
  }

  Future<void> _chooseFolder() async {
    final folder = await FilePicker.platform.getDirectoryPath();
    if (folder != null && mounted) setState(() => _folder = folder);
  }

  int get _chosenSize => (_groups ?? const <DuplicateGroup>[]).fold(
        0,
        (sum, group) => sum + group.size * group.files.where((f) => _chosen.contains(f.path)).length,
      );

  Future<void> _delete() async {
    final groups = _groups ?? const <DuplicateGroup>[];
    final allGone = groups.where((group) => group.files.every((f) => _chosen.contains(f.path))).length;
    final confirmed = await confirmToolboxDelete(
      context,
      title: 'Delete ${_chosen.length} ${_chosen.length == 1 ? 'file' : 'files'}?',
      message: "This frees ${EntityFormat.size(_chosenSize)}. They're deleted for good; this can't be undone."
          '${allGone > 0 ? '\n\nEvery copy of $allGone ${allGone == 1 ? 'file is' : 'files are'} ticked, so no copy would be left.' : ''}',
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    var freed = 0;
    var failed = 0;
    final kept = <DuplicateGroup>[];
    for (final group in groups) {
      final left = <DuplicateFile>[];
      for (final file in group.files) {
        if (!_chosen.contains(file.path)) {
          left.add(file);
          continue;
        }
        try {
          await File(file.path).delete();
          freed += group.size;
        } on FileSystemException {
          failed++;
          left.add(file);
        }
      }
      if (left.length > 1) kept.add(DuplicateGroup(group.size, left));
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _groups = kept;
      _chosen.clear();
      _result = 'Freed ${EntityFormat.size(freed)}.${failed > 0 ? " $failed couldn't be deleted." : ''}';
    });
  }

  @override
  void dispose() {
    _search?.cancel();
    super.dispose();
  }

  Widget _intro() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: EdgeInsets.fromLTRB(20, DockedGlossyTopBar.contentTopInset(context) + 24, 20, 24),
      children: [
        Text('Look in', style: text.labelMedium),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _chooseFolder,
          icon: const Icon(LucideIcons.folderOpen, size: 16),
          label: Align(
            alignment: Alignment.centerLeft,
            child: Text(_folder, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(LucideIcons.search, size: 18),
          label: const Text('Find duplicates'),
        ),
        const SizedBox(height: 16),
        Text(
          'Files are compared by their contents, so copies are found even under other names. '
          'Hidden files and app folders are left out.',
          style: text.bodySmall?.copyWith(color: colors.mutedForeground),
        ),
      ],
    );
  }

  Widget _searching() {
    final text = Theme.of(context).textTheme;
    final progress = _progress;
    final total = progress?.total ?? 0;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(value: total > 0 ? progress!.done / total : null),
          const SizedBox(height: 16),
          Text(
            progress == null
                ? 'Looking through files…'
                : (total > 0 ? '${progress.phase}: ${progress.done} of $total' : '${progress.phase}: ${progress.done}'),
            textAlign: TextAlign.center,
            style: text.bodyMedium,
          ),
          const SizedBox(height: 16),
          Center(child: OutlinedButton(onPressed: _stop, child: const Text('Stop'))),
        ],
      ),
    );
  }

  Widget _group(DuplicateGroup group) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
          child: Text(
            '${group.files.length} copies · ${EntityFormat.size(group.size)} each',
            style: text.labelMedium,
          ),
        ),
        for (final file in group.files)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _chosen.contains(file.path) ? _chosen.remove(file.path) : _chosen.add(file.path)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  SelectionCheck(selected: _chosen.contains(file.path)),
                  const SizedBox(width: 12),
                  FileThumbnail(
                    path: file.path,
                    size: 36,
                    fallback: EntityIcon(entity: File(file.path), size: 36),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.basename(file.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                        Text(
                          '${p.dirname(file.path)} · ${EntityFormat.date(file.modified)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Open',
                    icon: const Icon(LucideIcons.eye, size: 18),
                    onPressed: () => FileOpener.open(context, File(file.path)),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _results(List<DuplicateGroup> groups) {
    final text = Theme.of(context).textTheme;
    final top = DockedGlossyTopBar.contentTopInset(context);
    if (groups.isEmpty) {
      return ExplorerEmptyState(
        padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
        icon: LucideIcons.circleCheck,
        title: 'No duplicates',
        description: _result ?? 'No two files in this folder have the same contents.',
        actions: [
          OutlinedButton(
            onPressed: () => setState(() {
              _groups = null;
              _result = null;
            }),
            child: const Text('Look somewhere else'),
          ),
        ],
      );
    }
    final wasted = groups.fold<int>(0, (sum, group) => sum + group.wasted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(4, top + 8, 4, 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '${_result == null ? '' : '${_result!} '}'
                  '${groups.length} ${groups.length == 1 ? 'file has' : 'files have'} copies, '
                  'taking up ${EntityFormat.size(wasted)} more than needed. The oldest of each is kept unless you tick it.',
                  style: text.bodySmall,
                ),
              ),
              for (final group in groups) _group(group),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: _deleting || _chosen.isEmpty ? null : _delete,
              icon: const Icon(LucideIcons.trash2, size: 18),
              label: Text(
                _deleting ? 'Deleting…' : 'Delete ${_chosen.length} (${EntityFormat.size(_chosenSize)})',
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return ExplorerScaffold(
      title: 'Duplicate finder',
      body: _search != null ? _searching() : (groups != null ? _results(groups) : _intro()),
    );
  }
}
