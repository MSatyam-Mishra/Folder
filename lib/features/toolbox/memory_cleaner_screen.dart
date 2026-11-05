import 'package:explorer/core/services/toolbox/junk_scanner.dart';
import 'package:explorer/features/file_explorere/widgets/entity_meta.dart';
import 'package:explorer/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:explorer/features/file_explorere/widgets/file_list_item.dart' show SelectionCheck;
import 'package:explorer/features/toolbox/toolbox_menu.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:explorer/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Finds junk files, shows them by kind with the safe ones ticked, and deletes
/// what stays ticked.
class MemoryCleanerScreen extends StatefulWidget {
  const MemoryCleanerScreen({super.key});

  @override
  State<MemoryCleanerScreen> createState() => _MemoryCleanerScreenState();
}

class _MemoryCleanerScreenState extends State<MemoryCleanerScreen> {
  List<JunkGroup>? _groups;
  final _chosen = <JunkKind>{};
  final _open = <JunkKind>{};
  bool _cleaning = false;
  String? _result;

  Future<void> _scan() async {
    setState(() => _groups = null);
    final groups = await JunkScanner.scan();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _chosen
        ..clear()
        ..addAll([for (final group in groups) if (group.kind.selectedAtFirst) group.kind]);
    });
  }

  List<JunkGroup> get _chosenGroups => [
        for (final group in _groups ?? const <JunkGroup>[])
          if (_chosen.contains(group.kind)) group,
      ];

  int get _chosenSize => _chosenGroups.fold(0, (sum, group) => sum + group.size);

  Future<void> _clean() async {
    final items = [for (final group in _chosenGroups) ...group.items];
    final confirmed = await confirmToolboxDelete(
      context,
      title: 'Delete ${items.length} ${items.length == 1 ? 'item' : 'items'}?',
      message: "This frees ${EntityFormat.size(_chosenSize)}. They're deleted for good; this can't be undone.",
    );
    if (!confirmed || !mounted) return;
    setState(() => _cleaning = true);
    final result = await JunkScanner.clean(items);
    if (!mounted) return;
    setState(() {
      _cleaning = false;
      _result = 'Freed ${EntityFormat.size(result.freed)}.'
          '${result.failed > 0 ? " ${result.failed} couldn't be deleted, as they're in use." : ''}';
    });
    await _scan();
  }

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Widget _group(JunkGroup group) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final kind = group.kind;
    final open = _open.contains(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _chosen.contains(kind) ? _chosen.remove(kind) : _chosen.add(kind)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                SelectionCheck(selected: _chosen.contains(kind)),
                const SizedBox(width: 12),
                Icon(kind.icon, size: 20, color: colors.mutedForeground),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kind.label, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                      Text(kind.description, style: text.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(EntityFormat.size(group.size), style: text.bodySmall),
                IconButton(
                  tooltip: open ? 'Hide files' : 'Show files',
                  icon: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18),
                  onPressed: () => setState(() => open ? _open.remove(kind) : _open.add(kind)),
                ),
              ],
            ),
          ),
        ),
        if (open)
          for (final item in group.items.take(200))
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 3, 16, 3),
              child: Text(
                '${p.basename(item.path)}  ·  ${EntityFormat.size(item.size)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
            ),
        if (open && group.items.length > 200)
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 3, 16, 8),
            child: Text('and ${group.items.length - 200} more', style: text.bodySmall),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final top = DockedGlossyTopBar.contentTopInset(context);
    final groups = _groups;
    final Widget body;
    if (groups == null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Looking for junk…', style: text.bodyMedium),
          ],
        ),
      );
    } else if (groups.isEmpty) {
      body = ExplorerEmptyState(
        padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
        icon: LucideIcons.circleCheck,
        title: 'All clean',
        description: _result ?? 'There is no junk to remove right now.',
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(8, top + 12, 8, 12),
              children: [
                if (_result != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                    child: Text(_result!, style: text.bodyMedium),
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
                onPressed: _cleaning || _chosen.isEmpty ? null : _clean,
                icon: const Icon(LucideIcons.eraser, size: 18),
                label: Text(_cleaning ? 'Cleaning…' : 'Clean ${EntityFormat.size(_chosenSize)}'),
              ),
            ),
          ),
        ],
      );
    }
    return ExplorerScaffold(
      title: 'Memory cleaner',
      trailing: AppIconButton(
        icon: const Icon(LucideIcons.refreshCw),
        tooltip: 'Look again',
        onPressed: groups == null ? null : _scan,
      ),
      body: body,
    );
  }
}
