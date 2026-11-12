import 'package:folders/core/services/toolbox/junk_scanner.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/features/file_explorere/widgets/file_list_item.dart' show SelectionCheck;
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Finds junk, shows it by kind with the safe kinds ticked, and deletes what
/// stays ticked. A kind opens to its files, each of which can be ticked on its
/// own. Below the junk, under Review, are big and old files that aren't junk:
/// nothing there is ticked until the user ticks it.
class JunkCleanerScreen extends StatefulWidget {
  const JunkCleanerScreen({super.key});

  @override
  State<JunkCleanerScreen> createState() => _JunkCleanerScreenState();
}

class _JunkCleanerScreenState extends State<JunkCleanerScreen> {
  List<JunkGroup>? _groups;

  /// The ticked items, by path.
  final _chosen = <String>{};
  final _open = <JunkKind>{};
  bool _cleaning = false;
  String? _result;

  /// How many of a kind's files show when it's open.
  static const _shown = 200;

  Future<void> _scan() async {
    setState(() => _groups = null);
    final groups = await JunkScanner.scan();
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _chosen
        ..clear()
        ..addAll([
          for (final group in groups)
            if (group.kind.selectedAtFirst)
              for (final item in group.items) item.path,
        ]);
    });
  }

  List<JunkItem> get _chosenItems => [
        for (final group in _groups ?? const <JunkGroup>[])
          for (final item in group.items)
            if (_chosen.contains(item.path)) item,
      ];

  /// All of a kind's files ticked, none, or some (null).
  bool? _tickOf(JunkGroup group) {
    final ticked = group.items.where((item) => _chosen.contains(item.path)).length;
    if (ticked == 0) return false;
    return ticked == group.items.length ? true : null;
  }

  void _tickGroup(JunkGroup group) {
    final all = _tickOf(group) == true;
    setState(() {
      for (final item in group.items) {
        all ? _chosen.remove(item.path) : _chosen.add(item.path);
      }
    });
  }

  void _tickItem(JunkItem item) =>
      setState(() => _chosen.contains(item.path) ? _chosen.remove(item.path) : _chosen.add(item.path));

  Future<void> _clean() async {
    final items = _chosenItems;
    final size = items.fold(0, (sum, item) => sum + item.size);
    final confirmed = await confirmToolboxDelete(
      context,
      title: 'Delete ${items.length} ${items.length == 1 ? 'item' : 'items'}?',
      message: "This frees ${EntityFormat.size(size)}. They're deleted for good; this can't be undone.",
    );
    if (!confirmed || !mounted) return;
    setState(() => _cleaning = true);
    final result = await JunkScanner.clean(items);
    if (!mounted) return;
    setState(() {
      _cleaning = false;
      _result = 'Freed ${EntityFormat.size(result.freed)}.'
          '${result.failed > 0 ? " ${result.failed} couldn't be deleted, as they're in use or protected." : ''}';
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
          onTap: () => _tickGroup(group),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                _KindCheck(selected: _tickOf(group)),
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
          for (final item in group.items.take(_shown)) _item(item),
        if (open && group.items.length > _shown)
          Padding(
            padding: const EdgeInsets.fromLTRB(40, 3, 16, 8),
            child: Text('and ${group.items.length - _shown} more', style: text.bodySmall),
          ),
      ],
    );
  }

  /// One file or folder: its name, size and the folder it's in; the whole
  /// path on hover or a long press.
  Widget _item(JunkItem item) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Tooltip(
      message: item.path,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _tickItem(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(40, 5, 16, 5),
          child: Row(
            children: [
              SelectionCheck(selected: _chosen.contains(item.path), size: 16),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: p.basename(item.path)),
                      TextSpan(
                        text: '  ·  ${EntityFormat.size(item.size)}  ·  ${p.basename(p.dirname(item.path))}',
                        style: TextStyle(color: colors.mutedForeground),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reviewHeading() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.scanSearch, size: 16, color: colors.mutedForeground),
              const SizedBox(width: 8),
              Text('Review', style: text.titleSmall),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            "Not junk: big and old files worth a look. Nothing here is ticked until you tick it.",
            style: text.bodySmall,
          ),
        ],
      ),
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
      final chosen = _chosenItems;
      final chosenSize = chosen.fold(0, (sum, item) => sum + item.size);
      final firstReview = groups.indexWhere((group) => group.kind.review);
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
                for (final (index, group) in groups.indexed) ...[
                  if (index == firstReview) _reviewHeading(),
                  _group(group),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _cleaning || chosen.isEmpty ? null : _clean,
                icon: const Icon(LucideIcons.eraser, size: 18),
                label: Text(_cleaning ? 'Cleaning…' : 'Clean ${EntityFormat.size(chosenSize)}'),
              ),
            ),
          ),
        ],
      );
    }
    return ExplorerScaffold(
      title: 'Junk cleaner',
      trailing: AppIconButton(
        icon: const Icon(LucideIcons.refreshCw),
        tooltip: 'Look again',
        onPressed: groups == null ? null : _scan,
      ),
      body: body,
    );
  }
}

/// A kind's tick: all its files, none, or some (null).
class _KindCheck extends StatelessWidget {
  const _KindCheck({required this.selected});

  final bool? selected;

  static const _size = 18.0;

  @override
  Widget build(BuildContext context) {
    final selected = this.selected;
    if (selected != null) return SelectionCheck(selected: selected, size: _size);
    final colors = context.colors;
    return Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: colors.primary, width: 1.25),
      ),
      child: Icon(LucideIcons.minus, size: _size - 5, color: colors.primaryForeground),
    );
  }
}
