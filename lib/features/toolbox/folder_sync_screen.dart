import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:folders/core/services/toolbox/folder_compare.dart';
import 'package:folders/core/services/toolbox/folder_sync.dart';
import 'package:folders/core/services/toolbox/sync_pairs.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/ios_style.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Compares two folders and makes them match: choose the folders (or a saved
/// pair), compare, see what differs by group, pick how to sync, check every
/// step in the preview, then it runs as a background task.
class FolderSyncScreen extends StatefulWidget {
  const FolderSyncScreen({super.key});

  /// In place of the system's folder picker, for tests: the folder chosen,
  /// starting from [initial].
  @visibleForTesting
  static Future<String?> Function(String? initial)? pickFolder;

  @override
  State<FolderSyncScreen> createState() => _FolderSyncScreenState();
}

enum _Stage { setup, comparing, results, preview, running, done }

class _FolderSyncScreenState extends State<FolderSyncScreen> {
  var _stage = _Stage.setup;
  String? _left;
  String? _right;
  var _options = const CompareOptions();
  var _mode = SyncMode.copy;
  String? _error;

  List<SyncPair> _pairs = const [];

  /// The saved pair in use, if any.
  SyncPair? _pair;

  FolderCompare? _compare;
  CompareProgress? _progress;
  FolderComparison? _comparison;

  /// Groups open, and how many of each group's rows show.
  final _open = <Object>{};
  final _shownOf = <Object, int>{};

  final _choices = <String, ConflictChoice>{};
  SyncPlan? _plan;

  SyncJob? _job;
  SyncOutcome? _outcome;

  static const _maxWidth = 760.0;
  static const _firstRows = 100;
  static const _conflictsKey = 'conflicts';
  static const _untouchedKey = 'untouched';
  static final _number = NumberFormat.decimalPattern();

  @override
  void initState() {
    super.initState();
    _loadPairs();
    final running = SyncJob.running;
    if (running != null) _follow(running);
  }

  @override
  void dispose() {
    _compare?.stop();
    _job?.task.removeListener(_onTask);
    super.dispose();
  }

  Future<void> _loadPairs() async {
    final pairs = await SyncPairs.load();
    if (mounted) setState(() => _pairs = pairs);
  }

  // ---- choosing ----

  Future<void> _choose({required bool left}) async {
    final initial = left ? _left : _right;
    String? folder;
    final hook = FolderSyncScreen.pickFolder;
    try {
      folder = hook != null
          ? await hook(initial)
          : await FilePicker.platform.getDirectoryPath(
              dialogTitle: left ? 'Left folder' : 'Right folder',
              initialDirectory: initial,
            );
    } on Object {
      folder = null;
    }
    if (folder == null || folder.isEmpty || !mounted) return;
    if (folder.startsWith('content://')) {
      setState(() => _error = "That place can't be synced. Choose a folder on this device.");
      return;
    }
    setState(() {
      if (left) {
        _left = folder;
      } else {
        _right = folder;
      }
      _error = null;
    });
  }

  void _swap() => setState(() {
        final left = _left;
        _left = _right;
        _right = left;
      });

  // ---- comparing ----

  Future<void> _startCompare() async {
    final problem = FolderComparer.problem(_left, _right);
    if (problem != null) {
      setState(() {
        _error = problem;
        _stage = _Stage.setup;
      });
      return;
    }
    _compare?.stop();
    final compare = _compare = FolderCompare(_left!, _right!, options: _options, onProgress: (progress) {
      if (mounted) setState(() => _progress = progress);
    });
    setState(() {
      _stage = _Stage.comparing;
      _progress = null;
      _error = null;
    });
    final FolderComparison? comparison;
    try {
      comparison = await compare.start();
    } on Object {
      if (!mounted || !identical(_compare, compare)) return;
      setState(() {
        _compare = null;
        _stage = _Stage.setup;
        _error = "The comparison couldn't finish. Try again.";
      });
      return;
    }
    if (!mounted || comparison == null || !identical(_compare, compare)) return;
    setState(() {
      _compare = null;
      _comparison = comparison;
      _choices.clear();
      _openResults();
      _stage = _Stage.results;
    });
  }

  /// A short list opens all its groups; a long one waits to be opened.
  void _openResults() {
    _open
      ..clear()
      ..addAll((_comparison?.items.length ?? 0) <= 30 ? SyncDiff.values : const <SyncDiff>[]);
    _shownOf.clear();
  }

  void _stopCompare() {
    _compare?.stop();
    setState(() {
      _compare = null;
      _stage = _Stage.setup;
    });
  }

  // ---- pairs ----

  void _usePair(SyncPair pair, {bool compare = true}) {
    setState(() {
      _pair = pair;
      _left = pair.left;
      _right = pair.right;
      _mode = pair.mode;
      _options = pair.options;
      _error = null;
    });
    if (compare) _startCompare();
  }

  /// The saved pair in use, brought up to date with what's set up now.
  SyncPair? get _currentPair => _pair?.copyWith(left: _left, right: _right, mode: _mode, options: _options);

  Future<void> _savePair() async {
    final left = _left;
    final right = _right;
    if (left == null || right == null) return;
    final name = await _askName(
      title: _pair == null ? 'Save this pair' : 'Rename pair',
      initial: _pair?.name ?? SyncPair.defaultName(left, right),
    );
    if (name == null || !mounted) return;
    final pair = (_currentPair ?? SyncPair(id: SyncPairs.newId(), name: name, left: left, right: right)).copyWith(
      name: name,
      mode: _mode,
      options: _options,
    );
    await SyncPairs.put(pair);
    if (!mounted) return;
    setState(() => _pair = pair);
    await _loadPairs();
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Saved "$name"')));
  }

  Future<void> _pairMenu(SyncPair pair, Offset at) async {
    final action = await ExplorerMenu.showAt<String>(
      context,
      at,
      items: [
        ExplorerMenu.item(context, value: 'compare', label: 'Compare', icon: LucideIcons.gitCompareArrows),
        ExplorerMenu.item(context, value: 'edit', label: 'Change', icon: LucideIcons.pencil),
        ExplorerMenu.item(context, value: 'rename', label: 'Rename', icon: LucideIcons.textCursorInput),
        ExplorerMenu.divider(),
        ExplorerMenu.item(context, value: 'remove', label: 'Remove', icon: LucideIcons.trash2, destructive: true),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'compare':
        _usePair(pair);
      case 'edit':
        _usePair(pair, compare: false);
      case 'rename':
        final name = await _askName(title: 'Rename pair', initial: pair.name);
        if (name == null) return;
        await SyncPairs.rename(pair.id, name);
        if (_pair?.id == pair.id) _pair = _pair!.copyWith(name: name);
        await _loadPairs();
      case 'remove':
        await SyncPairs.remove(pair.id);
        if (_pair?.id == pair.id) setState(() => _pair = null);
        await _loadPairs();
    }
  }

  Future<String?> _askName({required String title, required String initial}) => AppSheet.show<String>(
        context,
        child: _NameForm(title: title, initial: initial),
      );

  // ---- previewing and syncing ----

  void _preview() {
    if (_comparison == null) return;
    _replan();
    setState(() {
      _open
        ..clear()
        ..addAll(SyncActionKind.values)
        ..add(_conflictsKey);
      _shownOf.clear();
      _stage = _Stage.preview;
    });
  }

  void _resolve(String path, ConflictChoice choice) {
    _choices[path] = choice;
    _replan();
  }

  void _resolveAll(ConflictChoice choice) {
    for (final conflict in _plan?.conflicts ?? const <SyncConflict>[]) {
      _choices[conflict.item.path] = choice;
    }
    _replan();
  }

  void _replan() {
    final comparison = _comparison;
    if (comparison == null) return;
    setState(() => _plan = SyncPlanner.plan(comparison, _mode, lastSync: _pair?.lastSync, choices: _choices));
  }

  Future<void> _sync() async {
    final plan = _plan;
    if (plan == null || plan.isEmpty) return;
    final pair = _currentPair;
    if (pair != null) {
      await SyncPairs.put(pair);
      _pair = pair;
    }
    if (!mounted) return;
    _follow(SyncJob.start(plan, pairId: pair?.id));
  }

  void _follow(SyncJob job) {
    _job?.task.removeListener(_onTask);
    _job = job;
    job.task.addListener(_onTask);
    setState(() {
      _plan = job.plan;
      _left = job.plan.left;
      _right = job.plan.right;
      _stage = _Stage.running;
    });
    job.outcome.then((outcome) {
      if (!mounted || !identical(_job, job)) return;
      setState(() {
        _outcome = outcome;
        _stage = _Stage.done;
      });
      _loadPairs();
    }, onError: (Object error) {
      if (!mounted || !identical(_job, job)) return;
      setState(() {
        _outcome = SyncOutcome(
          copied: 0,
          replaced: 0,
          deleted: 0,
          bytes: 0,
          failures: [SyncFailure('', SyncActionKind.copyRight, '$error')],
          cancelled: false,
        );
        _stage = _Stage.done;
      });
    });
  }

  void _onTask() {
    if (mounted) setState(() {});
  }

  void _finish() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      setState(() => _stage = _Stage.setup);
    }
  }

  void _showFailures() {
    final failures = _outcome?.failures ?? const <SyncFailure>[];
    final text = Theme.of(context).textTheme;
    AppSheet.show<void>(
      context,
      style: SheetStyle.side,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't be synced", style: text.titleLarge),
          const SizedBox(height: 4),
          Text('They may be in use or protected, or changed since the comparison.', style: text.bodySmall),
          const SizedBox(height: 12),
          for (final failure in failures.take(300))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_actionIcon(failure.kind), size: 18, color: context.colors.mutedForeground),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(failure.path.isEmpty ? failure.kind.label : failure.path, style: text.bodyMedium),
                        Text(failure.reason, style: text.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (failures.length > 300) Text('and ${failures.length - 300} more', style: text.bodySmall),
        ],
      ),
    );
  }

  // ---- looks ----

  bool get _grouped => context.look.groupedLists;

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  static String _count(int items, [String one = 'item', String many = 'items']) =>
      '${_number.format(items)} ${items == 1 ? one : many}';

  static String _tail(String path) {
    final parts = p.split(path);
    return parts.length <= 4 ? path : '…${p.separator}${p.joinAll(parts.sublist(parts.length - 3))}';
  }

  static IconData _diffIcon(SyncDiff diff) => switch (diff) {
        SyncDiff.onlyLeft => LucideIcons.arrowLeft,
        SyncDiff.onlyRight => LucideIcons.arrowRight,
        SyncDiff.newerLeft => LucideIcons.clock,
        SyncDiff.newerRight => LucideIcons.clock3,
        SyncDiff.differentSize => LucideIcons.scale,
        SyncDiff.differentContents => LucideIcons.fileDiff,
        SyncDiff.typeClash => LucideIcons.triangleAlert,
      };

  static IconData _modeIcon(SyncMode mode) => switch (mode) {
        SyncMode.copy => LucideIcons.arrowRight,
        SyncMode.mirror => LucideIcons.flipHorizontal2,
        SyncMode.twoWay => LucideIcons.arrowLeftRight,
      };

  static IconData _actionIcon(SyncActionKind kind) => switch (kind) {
        SyncActionKind.copyRight => LucideIcons.arrowRight,
        SyncActionKind.copyLeft => LucideIcons.arrowLeft,
        SyncActionKind.replaceRight || SyncActionKind.replaceLeft => LucideIcons.replace,
        SyncActionKind.deleteRight || SyncActionKind.deleteLeft => LucideIcons.trash2,
      };

  Widget _limit(Widget child) => Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: _maxWidth), child: child),
      );

  /// A card: iOS's grouped one, or a rounded outline.
  Widget _panel(Widget child) {
    final colors = context.colors;
    return Material(
      type: _grouped ? MaterialType.canvas : MaterialType.transparency,
      color: _grouped ? IosStyle.groupedCard(_dark) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_grouped ? 12 : 16),
        side: _grouped ? BorderSide.none : BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _divider({double indent = 16}) => Divider(
        height: 1,
        thickness: _grouped ? 0.5 : 1,
        indent: indent,
        color: _grouped ? IosStyle.separator(_dark) : context.colors.border,
      );

  Widget _heading(IconData icon, String title, [String? about]) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(_grouped ? 16 : 6, 24, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_grouped)
            Text(
              title.toUpperCase(),
              style: text.bodySmall?.copyWith(fontSize: 12, letterSpacing: 0.3, color: colors.mutedForeground),
            )
          else
            Row(
              children: [
                Icon(icon, size: 16, color: context.look.iconColor(icon, colors.mutedForeground)),
                const SizedBox(width: 8),
                Text(title, style: text.titleSmall),
              ],
            ),
          if (about != null) ...[
            const SizedBox(height: 2),
            Text(about, style: text.bodySmall),
          ],
        ],
      ),
    );
  }

  /// A page of cards that scrolls under the top bar, with [bottom] at its
  /// foot.
  Widget _page(List<Widget> children, {Widget? bottom}) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final list = ListView(
      padding: EdgeInsets.fromLTRB(12, top + 12, 12, bottom == null ? MediaQuery.paddingOf(context).bottom + 24 : 16),
      children: [for (final child in children) _limit(child)],
    );
    if (bottom == null) return list;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [Expanded(child: list), _bar(bottom)],
    );
  }

  Widget _bar(Widget child) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: _grouped ? IosStyle.separator(_dark) : colors.border, width: _grouped ? 0.5 : 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 12), child: _limit(child)),
      ),
    );
  }

  /// A state in the middle of the page: comparing, syncing, done.
  Widget _centred(List<Widget> children) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final bottom = MediaQuery.paddingOf(context).bottom + 24;
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, top + 16, 24, bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - top - 16 - bottom)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(String title) => Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      );

  Widget _line(String line) => Text(
        line,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.colors.mutedForeground),
      );

  Widget _ring({required double? value, required Widget child}) {
    final colors = context.colors;
    return SizedBox.square(
      dimension: 160,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: value,
            strokeWidth: 10,
            strokeCap: StrokeCap.round,
            color: colors.primary,
            backgroundColor: colors.border,
          ),
          Padding(padding: const EdgeInsets.all(26), child: Center(child: FittedBox(child: child))),
        ],
      ),
    );
  }

  Widget _badge(IconData icon, {double size = 96}) {
    final tint = context.colors.primary;
    return DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.12)),
      child: SizedBox.square(dimension: size, child: Icon(icon, size: size * 0.44, color: tint)),
    );
  }

  /// A tinted line with an icon: a warning, or what couldn't be done.
  Widget _note(IconData icon, String text, {Color? color, Widget? action}) {
    final colors = context.colors;
    final tint = color ?? colors.mutedForeground;
    return DecoratedBox(
      decoration: BoxDecoration(color: tint.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 10, action == null ? 14 : 6, 10),
        child: Row(
          children: [
            Icon(icon, size: 18, color: tint),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color ?? colors.foreground),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }

  /// Where a menu opens from a widget without a pointer: its centre.
  static Offset _centerOf(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  // ---- setup ----

  Widget _folderRow({required bool left}) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final path = left ? _left : _right;
    return InkWell(
      onTap: () => _choose(left: left),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SizedBox.square(
                dimension: 36,
                child: Icon(
                  LucideIcons.folderOpen,
                  size: 18,
                  color: context.look.iconColor(LucideIcons.folderOpen, colors.primary),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(left ? 'Left' : 'Right', style: text.bodySmall),
                  Text(
                    path ?? 'Choose a folder',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: path == null ? null : FontWeight.w500,
                      color: path == null ? colors.mutedForeground : null,
                    ),
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight, size: 18, color: colors.mutedForeground),
          ],
        ),
      ),
    );
  }

  Widget _setupView() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final error = _error;
    return _page([
      _heading(LucideIcons.folderSync, 'Folders', 'What changed on the left goes to the right, unless you sync both ways.'),
      _panel(Column(
        children: [
          _folderRow(left: true),
          Row(
            children: [
              Expanded(child: _divider(indent: 62)),
              IconButton(
                tooltip: 'Swap',
                visualDensity: VisualDensity.compact,
                icon: const Icon(LucideIcons.arrowUpDown, size: 18),
                onPressed: _left == null && _right == null ? null : _swap,
              ),
              const SizedBox(width: 6),
            ],
          ),
          _folderRow(left: false),
        ],
      )),
      _heading(LucideIcons.listChecks, 'Options'),
      _panel(Column(
        children: [
          SwitchListTile(
            secondary: const Icon(LucideIcons.fileSearch, size: 20),
            title: const Text('Compare contents'),
            subtitle: const Text('Slower: reads every file whose size matches, to find changes the date hides'),
            value: _options.contents,
            onChanged: (value) => setState(
              () => _options = CompareOptions(contents: value, ignoreHourShift: _options.ignoreHourShift),
            ),
          ),
          _divider(indent: 56),
          SwitchListTile(
            secondary: const Icon(LucideIcons.clock, size: 20),
            title: const Text('Ignore 1-hour differences'),
            subtitle: const Text('For memory cards and drives that shift times with daylight saving (FAT, exFAT)'),
            value: _options.ignoreHourShift,
            onChanged: (value) => setState(
              () => _options = CompareOptions(contents: _options.contents, ignoreHourShift: value),
            ),
          ),
        ],
      )),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _note(LucideIcons.triangleAlert, error, color: colors.destructive),
        ),
      const SizedBox(height: 20),
      Center(
        child: SizedBox(
          width: 280,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _startCompare,
            icon: const Icon(LucideIcons.gitCompareArrows, size: 20),
            label: const Text('Compare', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Nothing changes until you have seen what a sync will do. Links and junctions are left alone.',
        textAlign: TextAlign.center,
        style: text.bodySmall,
      ),
      if (_pairs.isNotEmpty) ...[
        _heading(LucideIcons.bookmark, 'Saved pairs', 'Compare again in a tap.'),
        _panel(Column(
          children: [
            for (final (index, pair) in _pairs.indexed) ...[
              if (index > 0) _divider(indent: 62),
              _pairRow(pair),
            ],
          ],
        )),
      ],
    ]);
  }

  Widget _pairRow(SyncPair pair) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final last = pair.lastRun;
    return Builder(
      builder: (row) => InkWell(
        onTap: () => _usePair(pair),
        onSecondaryTapUp: (details) => _pairMenu(pair, details.globalPosition),
        onLongPress: () => _pairMenu(pair, _centerOf(row)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SizedBox.square(dimension: 36, child: Icon(_modeIcon(pair.mode), size: 18, color: colors.primary)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pair.name, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                    Text(
                      '${pair.mode.label}: ${_tail(pair.left)}  →  ${_tail(pair.right)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                    if (last != null)
                      Text(
                        'Last run ${_ago(last)}${pair.lastSummary == null ? '' : ': ${pair.lastSummary}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                  ],
                ),
              ),
              Builder(
                builder: (button) => IconButton(
                  tooltip: 'More',
                  icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                  onPressed: () => _pairMenu(pair, _centerOf(button)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- comparing ----

  Widget _comparingView() {
    final text = Theme.of(context).textTheme;
    final progress = _progress;
    final reading = progress?.phase == ComparePhase.contents;
    final value = reading && progress!.bytesTotal > 0 ? progress.bytesDone / progress.bytesTotal : null;
    return _centred([
      _ring(
        value: value,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_number.format(progress?.files ?? 0), style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
            Text('files', style: text.bodySmall),
          ],
        ),
      ),
      const SizedBox(height: 28),
      _title(reading ? 'Comparing contents…' : 'Comparing…'),
      const SizedBox(height: 8),
      _line(reading
          ? '${EntityFormat.size(progress!.bytesDone)} of ${EntityFormat.size(progress.bytesTotal)} read'
          : 'Looking through both folders'),
      const SizedBox(height: 4),
      Text(
        progress == null || progress.place.isEmpty ? ' ' : progress.place,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: text.bodySmall,
      ),
      const SizedBox(height: 28),
      OutlinedButton.icon(
        onPressed: _stopCompare,
        icon: const Icon(LucideIcons.circleStop, size: 16),
        label: const Text('Stop'),
      ),
    ]);
  }

  // ---- results ----

  String _sideLine(String side, SyncStat? stat) {
    if (stat == null) return '$side: not there';
    if (stat.isFolder) return '$side: folder, ${_count(stat.files, 'file', 'files')}, ${EntityFormat.size(stat.size)}';
    return '$side: ${EntityFormat.size(stat.size)}, ${EntityFormat.date(stat.modifiedTime)}';
  }

  Widget _itemRow(SyncItem item, {IconData? icon, Widget? trailing, String? extra}) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final folder = p.dirname(item.path);
    final isFolder = (item.left ?? item.right)?.isFolder ?? false;
    return Tooltip(
      message: item.path,
      waitDuration: const Duration(milliseconds: 600),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 12, 6),
        child: Row(
          children: [
            Icon(icon ?? (isFolder ? LucideIcons.folder : LucideIcons.file), size: 16, color: colors.mutedForeground),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: item.name),
                        if (folder != '.')
                          TextSpan(text: '  ·  $folder', style: TextStyle(color: colors.mutedForeground)),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium,
                  ),
                  Text(
                    extra ?? '${_sideLine('Left', item.left)}   ${_sideLine('Right', item.right)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }

  /// A group's heading row, which opens and closes it.
  Widget _groupHeader({
    required Object key,
    required IconData icon,
    required String label,
    required int count,
    required int bytes,
    Color? color,
  }) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final open = _open.contains(key);
    final tint = color ?? colors.primary;
    return InkWell(
      onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: tint.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
              child: SizedBox.square(
                dimension: 34,
                child: Icon(icon, size: 18, color: color ?? context.look.iconColor(icon, colors.primary)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: color)),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_number.format(count), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                Text(EntityFormat.size(bytes), style: text.bodySmall),
              ],
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: open ? 'Hide' : 'Show',
              child: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: colors.mutedForeground),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  /// The first rows of a group, with a button for more.
  List<Widget> _rows<T>(Object key, List<T> all, Widget Function(T row) build) {
    final text = Theme.of(context).textTheme;
    final shown = _shownOf[key] ?? _firstRows;
    return [
      for (final row in all.take(shown)) build(row),
      if (all.length > shown)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 14, 8),
          child: Row(
            children: [
              Expanded(child: Text('and ${_number.format(all.length - shown)} more', style: text.bodySmall)),
              TextButton.icon(
                onPressed: () => setState(() => _shownOf[key] = shown + 500),
                icon: const Icon(LucideIcons.chevronDown, size: 16),
                label: const Text('Show more'),
              ),
            ],
          ),
        ),
      const SizedBox(height: 6),
    ];
  }

  Widget _resultsSummary(FolderComparison comparison) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return _panel(Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          _badge(comparison.matches ? LucideIcons.circleCheck : LucideIcons.gitCompareArrows, size: 72),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  comparison.matches
                      ? 'The folders match'
                      : _count(comparison.items.length, 'difference', 'differences'),
                  style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_count(comparison.identical, 'file', 'files')} the same on both sides '
                  '(${EntityFormat.size(comparison.identicalBytes)})',
                  style: text.bodySmall,
                ),
                Text('Left: ${_tail(comparison.left)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                Text('Right: ${_tail(comparison.right)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                if (comparison.skippedLinks > 0)
                  Text('${_count(comparison.skippedLinks, 'link', 'links')} left alone', style: text.bodySmall),
                if (comparison.unreadable.isNotEmpty)
                  Text(
                    "${_count(comparison.unreadable.length, 'folder', 'folders')} couldn't be read",
                    style: text.bodySmall?.copyWith(color: colors.destructive),
                  ),
              ],
            ),
          ),
        ],
      ),
    ));
  }

  Widget _resultsView() {
    final comparison = _comparison!;
    final groups = [
      for (final diff in SyncDiff.values)
        if (comparison.of(diff) case final items when items.isNotEmpty) (diff, items),
    ];
    final children = <Widget>[
      _resultsSummary(comparison),
      if (groups.isNotEmpty) ...[
        _heading(LucideIcons.listChecks, 'What differs', 'Tap a group to see its files.'),
        _panel(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, (diff, items)) in groups.indexed) ...[
              if (index > 0) _divider(indent: 60),
              _groupHeader(
                key: diff,
                icon: _diffIcon(diff),
                label: diff.label,
                count: items.length,
                bytes: items.fold(0, (sum, item) => sum + item.size),
              ),
              if (_open.contains(diff)) ..._rows(diff, items, (item) => _itemRow(item)),
            ],
          ],
        )),
      ],
    ];
    if (comparison.matches) {
      return _page([
        ...children,
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(160, 48)),
            onPressed: _finish,
            icon: const Icon(LucideIcons.check, size: 18),
            label: const Text('Done'),
          ),
        ),
      ]);
    }
    return _page(children, bottom: _modeBar());
  }

  Widget _modeBar() {
    final text = Theme.of(context).textTheme;
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final modes = SegmentedButton<SyncMode>(
      showSelectedIcon: false,
      segments: [
        for (final mode in SyncMode.values)
          ButtonSegment(value: mode, icon: Icon(_modeIcon(mode), size: 16), label: Text(mode.label)),
      ],
      selected: {_mode},
      onSelectionChanged: (modes) => setState(() => _mode = modes.first),
    );
    final button = FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
      onPressed: _preview,
      icon: const Icon(LucideIcons.listChecks, size: 18),
      label: const Text('Preview', style: TextStyle(fontWeight: FontWeight.w600)),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          Row(children: [modes, const Spacer(), SizedBox(width: 200, child: button)])
        else
          Center(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: modes)),
        const SizedBox(height: 6),
        Text(_mode.description, style: text.bodySmall, textAlign: wide ? TextAlign.start : TextAlign.center),
        if (!wide) ...[const SizedBox(height: 10), button],
      ],
    );
  }

  // ---- preview ----

  Widget _choiceButtons(String path, ConflictChoice current) => SegmentedButton<ConflictChoice>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(
            value: ConflictChoice.left,
            tooltip: 'Keep the left one',
            icon: Icon(LucideIcons.arrowRight, size: 14),
          ),
          ButtonSegment(value: ConflictChoice.skip, tooltip: 'Leave both', icon: Icon(LucideIcons.equal, size: 14)),
          ButtonSegment(
            value: ConflictChoice.right,
            tooltip: 'Keep the right one',
            icon: Icon(LucideIcons.arrowLeft, size: 14),
          ),
        ],
        selected: {current},
        onSelectionChanged: (choice) => _resolve(path, choice.first),
      );

  Widget _previewSummary(SyncPlan plan) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return _panel(Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          _badge(_modeIcon(plan.mode), size: 72),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.isEmpty ? 'Nothing to do' : _count(plan.actions.length, 'change', 'changes'),
                  style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text('${plan.mode.label}: ${plan.mode.description}', style: text.bodySmall),
                if (plan.copyBytes > 0) Text('${EntityFormat.size(plan.copyBytes)} to copy', style: text.bodySmall),
                if (plan.deletes > 0)
                  Text(
                    '${_count(plan.deletes)} to delete (${EntityFormat.size(plan.deleteBytes)})',
                    style: text.bodySmall?.copyWith(color: colors.destructive, fontWeight: FontWeight.w600),
                  ),
                if (plan.skippedConflicts > 0)
                  Text(
                    '${_count(plan.skippedConflicts, 'conflict', 'conflicts')} left as they are',
                    style: text.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    ));
  }

  Widget _previewView() {
    final plan = _plan!;
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final kinds = [for (final kind in SyncActionKind.values) if (plan.count(kind) > 0) kind];
    final replaces = plan.count(SyncActionKind.replaceRight) + plan.count(SyncActionKind.replaceLeft);
    final rightDeletes = plan.count(SyncActionKind.deleteRight);
    final children = <Widget>[
      _previewSummary(plan),
      if (plan.mode == SyncMode.mirror && rightDeletes > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _note(
            LucideIcons.triangleAlert,
            'Mirror deletes ${_count(rightDeletes)} on the right '
            '(${EntityFormat.size(plan.bytesOf(SyncActionKind.deleteRight))}) that '
            "${rightDeletes == 1 ? "isn't" : "aren't"} on the left.",
            color: colors.destructive,
          ),
        ),
      if (replaces > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _note(LucideIcons.replace, 'The older copy of each replaced file is deleted the way Delete does it.'),
        ),
      if (kinds.isNotEmpty) ...[
        _heading(LucideIcons.listChecks, 'What will happen', 'In this order. Tap a group to see every item.'),
        _panel(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, kind) in kinds.indexed) ...[
              if (index > 0) _divider(indent: 60),
              _groupHeader(
                key: kind,
                icon: _actionIcon(kind),
                label: kind.label,
                count: plan.count(kind),
                bytes: plan.bytesOf(kind),
                color: kind.isDelete ? colors.destructive : null,
              ),
              if (_open.contains(kind))
                ..._rows(kind, plan.of(kind), (action) => _itemRow(action.item, icon: _actionIcon(kind))),
            ],
          ],
        )),
      ],
      if (plan.conflicts.isNotEmpty) ...[
        _heading(LucideIcons.triangleAlert, 'Conflicts', "Two-way sync can't tell which one wins. Choose, or leave both."),
        _panel(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _groupHeader(
              key: _conflictsKey,
              icon: LucideIcons.triangleAlert,
              label: 'Conflicts',
              count: plan.conflicts.length,
              bytes: plan.conflicts.fold(0, (sum, c) => sum + c.item.size),
            ),
            if (_open.contains(_conflictsKey)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
                child: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('For all:', style: text.bodySmall),
                    TextButton.icon(
                      onPressed: () => _resolveAll(ConflictChoice.left),
                      icon: const Icon(LucideIcons.arrowRight, size: 16),
                      label: const Text('Keep left'),
                    ),
                    TextButton.icon(
                      onPressed: () => _resolveAll(ConflictChoice.skip),
                      icon: const Icon(LucideIcons.equal, size: 16),
                      label: const Text('Leave both'),
                    ),
                    TextButton.icon(
                      onPressed: () => _resolveAll(ConflictChoice.right),
                      icon: const Icon(LucideIcons.arrowLeft, size: 16),
                      label: const Text('Keep right'),
                    ),
                  ],
                ),
              ),
              ..._rows(
                _conflictsKey,
                plan.conflicts,
                (conflict) => _itemRow(
                  conflict.item,
                  icon: LucideIcons.triangleAlert,
                  extra: '${conflict.reason.label}. ${_sideLine('Left', conflict.item.left)}   '
                      '${_sideLine('Right', conflict.item.right)}',
                  trailing: _choiceButtons(conflict.item.path, conflict.choice),
                ),
              ),
            ],
          ],
        )),
      ],
      if (plan.untouched.isNotEmpty) ...[
        _heading(LucideIcons.equal, 'Left as they are', '${plan.mode.label} leaves these alone.'),
        _panel(Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _groupHeader(
              key: _untouchedKey,
              icon: LucideIcons.equal,
              label: 'Not changed',
              count: plan.untouched.length,
              bytes: plan.untouched.fold(0, (sum, item) => sum + item.size),
            ),
            if (_open.contains(_untouchedKey))
              ..._rows(
                _untouchedKey,
                plan.untouched,
                (item) => _itemRow(item, icon: _diffIcon(item.diff), extra: item.diff.label),
              ),
          ],
        )),
      ],
    ];
    final deletes = plan.deletes;
    final syncButton = FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        backgroundColor: deletes > 0 ? colors.destructive : null,
        foregroundColor: deletes > 0 ? colors.destructiveForeground : null,
      ),
      onPressed: plan.isEmpty ? null : _sync,
      icon: Icon(deletes > 0 ? LucideIcons.trash2 : LucideIcons.folderSync, size: 18),
      label: Text(
        plan.isEmpty ? 'Nothing to do' : (deletes > 0 ? 'Sync and delete ${_number.format(deletes)}' : 'Sync now'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    return _page(
      children,
      bottom: Row(
        children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => setState(() {
              _openResults();
              _stage = _Stage.results;
            }),
            icon: const Icon(LucideIcons.arrowLeft, size: 18),
            label: const Text('Back'),
          ),
          const SizedBox(width: 12),
          Expanded(child: syncButton),
        ],
      ),
    );
  }

  // ---- running and done ----

  Widget _runningView() {
    final text = Theme.of(context).textTheme;
    final task = _job?.task;
    final value = task?.progress;
    return _centred([
      _ring(
        value: value,
        child: Text(
          '${((value ?? 0) * 100).round()}%',
          style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      const SizedBox(height: 28),
      _title(task?.cancelRequested ?? false ? 'Stopping…' : 'Syncing…'),
      const SizedBox(height: 8),
      _line(task?.detail.isNotEmpty ?? false ? task!.detail : 'Getting ready…'),
      const SizedBox(height: 4),
      Text(
        task?.message ?? ' ',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: text.bodySmall,
      ),
      const SizedBox(height: 28),
      OutlinedButton.icon(
        onPressed: task?.canCancel ?? false ? task!.cancel : null,
        icon: const Icon(LucideIcons.circleStop, size: 16),
        label: const Text('Cancel'),
      ),
      const SizedBox(height: 12),
      Text('It carries on if you leave this page.', style: text.bodySmall, textAlign: TextAlign.center),
    ]);
  }

  Widget _doneView() {
    final colors = context.colors;
    final outcome = _outcome!;
    final failed = outcome.failures.length;
    return _centred([
      _badge(outcome.cancelled ? LucideIcons.circleStop : LucideIcons.check),
      const SizedBox(height: 24),
      _title(outcome.cancelled ? 'Sync stopped' : 'Synced'),
      const SizedBox(height: 8),
      _line(outcome.summary),
      if (outcome.bytes > 0) ...[
        const SizedBox(height: 4),
        _line('${EntityFormat.size(outcome.bytes)} copied'),
      ],
      if (failed > 0) ...[
        const SizedBox(height: 18),
        _note(
          LucideIcons.triangleAlert,
          "${_count(failed)} couldn't be synced.",
          color: colors.destructive,
          action: TextButton.icon(
            onPressed: _showFailures,
            icon: const Icon(LucideIcons.list, size: 16),
            label: const Text('See which'),
          ),
        ),
      ],
      const SizedBox(height: 28),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(140, 48)),
            onPressed: _startCompare,
            icon: const Icon(LucideIcons.refreshCw, size: 18),
            label: const Text('Compare again'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
            onPressed: _finish,
            icon: const Icon(LucideIcons.check, size: 18),
            label: const Text('Done'),
          ),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = switch (_stage) {
      _Stage.setup => _setupView(),
      _Stage.comparing => _comparingView(),
      _Stage.results => _resultsView(),
      _Stage.preview => _previewView(),
      _Stage.running => _runningView(),
      _Stage.done => _doneView(),
    };
    final settled = const {_Stage.results, _Stage.preview, _Stage.done}.contains(_stage);
    return ExplorerScaffold(
      title: 'Folder sync',
      // iOS's grouped lists: white cards on a grey page, as see-through as
      // the page would be.
      backgroundColor: _grouped ? IosStyle.groupedBackground(_dark).withValues(alpha: colors.background.a) : null,
      trailing: settled
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_stage == _Stage.results)
                  AppIconButton(icon: const Icon(LucideIcons.refreshCw), tooltip: 'Compare again', onPressed: _startCompare),
                AppIconButton(
                  icon: Icon(_pair == null ? LucideIcons.bookmarkPlus : LucideIcons.bookmarkCheck),
                  tooltip: _pair == null ? 'Save this pair' : 'Rename pair',
                  onPressed: _savePair,
                ),
                AppIconButton(
                  icon: const Icon(LucideIcons.folderOpen),
                  tooltip: 'Choose other folders',
                  onPressed: () => setState(() => _stage = _Stage.setup),
                ),
              ],
            )
          : null,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
        child: KeyedSubtree(key: ValueKey(_stage), child: body),
      ),
    );
  }
}

/// "3 days ago", or the date once it's a month or more.
String _ago(DateTime at) {
  final gone = DateTime.now().difference(at);
  String count(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';
  if (gone.inMinutes < 1) return 'just now';
  if (gone.inHours < 1) return count(gone.inMinutes, 'minute');
  if (gone.inDays < 1) return count(gone.inHours, 'hour');
  if (gone.inDays < 2) return 'yesterday';
  if (gone.inDays < 30) return count(gone.inDays, 'day');
  return 'on ${EntityFormat.date(at)}';
}

/// A name for a saved pair.
class _NameForm extends StatefulWidget {
  const _NameForm({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameForm> createState() => _NameFormState();
}

class _NameFormState extends State<_NameForm> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: text.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(LucideIcons.bookmark, size: 18)),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(LucideIcons.x, size: 16),
                label: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(LucideIcons.check, size: 16),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
