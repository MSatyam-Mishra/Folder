import 'dart:math' as math;

import 'package:folders/core/services/toolbox/junk_scanner.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/ios_style.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/file_list_item.dart' show SelectionCheck;
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

/// Finds junk when asked, then shows it by kind with the safe kinds ticked,
/// and deletes what stays ticked: a start screen with the Scan button, the
/// scan going on, what it found, the clean-up going on, and what it freed.
/// A kind opens to its files, each of which can be ticked on its own. Below
/// the junk, under Review, are big and old files that aren't junk: nothing
/// there is ticked until the user ticks it.
class JunkCleanerScreen extends StatefulWidget {
  const JunkCleanerScreen({super.key});

  @override
  State<JunkCleanerScreen> createState() => _JunkCleanerScreenState();
}

enum _Stage { start, scanning, results, cleaning, done }

class _JunkCleanerScreenState extends State<JunkCleanerScreen> {
  var _stage = _Stage.start;
  JunkScan? _scan;
  JunkScanProgress? _progress;
  String? _error;
  List<JunkGroup> _groups = const [];

  /// The ticked items, by path.
  final _chosen = <String>{};
  final _open = <JunkKind>{};

  /// What's being deleted (how many, and their size) and how far that's come.
  var _deleting = (0, 0);
  JunkCleanProgress? _cleanProgress;
  JunkCleanResult? _result;
  _LastClean? _last;

  /// How many of a kind's files show when it's open.
  static const _shown = 200;

  /// How wide the content gets in a wide window.
  static const _maxWidth = 760.0;

  @override
  void initState() {
    super.initState();
    _LastClean.load().then((last) {
      if (mounted) setState(() => _last = last);
    });
  }

  @override
  void dispose() {
    _scan?.stop();
    super.dispose();
  }

  Future<void> _startScan() async {
    _scan?.stop();
    final scan = _scan = JunkScan(onProgress: (progress) {
      if (mounted) setState(() => _progress = progress);
    });
    setState(() {
      _stage = _Stage.scanning;
      _progress = null;
      _error = null;
    });
    final List<JunkGroup>? groups;
    try {
      groups = await scan.start();
    } on Object {
      if (!mounted || !identical(_scan, scan)) return;
      setState(() {
        _scan = null;
        _stage = _Stage.start;
        _error = "The scan couldn't finish. Try again.";
      });
      return;
    }
    if (!mounted || groups == null || !identical(_scan, scan)) return;
    setState(() {
      _scan = null;
      _groups = groups!;
      _open.clear();
      _chosen
        ..clear()
        ..addAll([
          for (final group in groups)
            if (group.kind.selectedAtFirst)
              for (final item in group.items) item.path,
        ]);
      _stage = _Stage.results;
    });
  }

  void _stop() {
    _scan?.stop();
    setState(() {
      _scan = null;
      _stage = _Stage.start;
    });
  }

  List<JunkItem> get _chosenItems => [
        for (final group in _groups)
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
    final size = _sizeOf(items);
    final confirmed = await confirmToolboxDelete(
      context,
      title: 'Delete ${_count(items.length)}?',
      message: "This frees ${EntityFormat.size(size)}. They're deleted for good; this can't be undone.",
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _stage = _Stage.cleaning;
      _deleting = (items.length, size);
      _cleanProgress = null;
    });
    final result = await JunkScanner.clean(items, onProgress: (progress) {
      if (mounted) setState(() => _cleanProgress = progress);
    });
    final last = _LastClean(DateTime.now(), result.freed, result.removed);
    if (result.removed > 0) await last.save();
    if (!mounted) return;
    setState(() {
      _result = result;
      if (result.removed > 0) _last = last;
      _stage = _Stage.done;
    });
  }

  /// Back where the cleaner was opened from, or to its start.
  void _finish() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      setState(() => _stage = _Stage.start);
    }
  }

  void _showNotDeleted() {
    final items = _result?.notDeleted ?? const <JunkItem>[];
    final text = Theme.of(context).textTheme;
    AppSheet.show<void>(
      context,
      style: SheetStyle.side,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Not deleted', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'These are in use or protected. Close the programs that may be using them, then scan again.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          for (final item in items.take(_shown)) _NotDeletedRow(item),
          if (items.length > _shown)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('and ${items.length - _shown} more', style: text.bodySmall),
            ),
        ],
      ),
    );
  }

  static int _sizeOf(Iterable<JunkItem> items) => items.fold(0, (sum, item) => sum + item.size);

  static final _number = NumberFormat.decimalPattern();

  static String _count(int items) => '${_number.format(items)} ${items == 1 ? 'item' : 'items'}';

  /// The last few parts of [path], as the start of a long one says little.
  static String _tail(String path) {
    final parts = p.split(path);
    return parts.length <= 4 ? path : '…${p.separator}${p.joinAll(parts.sublist(parts.length - 3))}';
  }

  bool get _grouped => context.look.groupedLists;

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  /// The ring's track: the border's colour shows on every style's page and
  /// card, where muted can all but vanish (Sweet, iOS's grey page).
  Color get _track => context.colors.border;

  /// [child] no wider than [_maxWidth], in the middle.
  Widget _limit(Widget child) => Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: _maxWidth), child: child),
      );

  /// A state around the ring: in the middle, scrolling if the window is too
  /// low for it.
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

  /// A figure in the middle of the ring, with what it is under it.
  Widget _figure(String figure, String label) {
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(figure, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(label, style: text.bodySmall),
      ],
    );
  }

  Widget _bigButton({required VoidCallback onPressed, required IconData icon, required String label}) => SizedBox(
        width: 280,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _startView() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final last = _last;
    final error = _error;
    return _centred([
      _Ring(value: 0, track: _track, child: _Badge(Tool.junkCleaner.icon)),
      const SizedBox(height: 28),
      _title('Free up space'),
      const SizedBox(height: 8),
      _line(
        'Looks for temporary files, caches, leftovers, unfinished downloads and other junk. '
        'Nothing is deleted until you say so.',
      ),
      if (last != null) ...[
        const SizedBox(height: 18),
        _Note(
          icon: LucideIcons.history,
          text: 'Last cleaned ${_ago(last.at)}: ${EntityFormat.size(last.freed)} freed',
        ),
      ],
      if (error != null) ...[
        const SizedBox(height: 18),
        Text(error, textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: colors.destructive)),
      ],
      const SizedBox(height: 28),
      _bigButton(onPressed: _startScan, icon: LucideIcons.scanSearch, label: 'Scan'),
    ]);
  }

  Widget _scanningView() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final progress = _progress;
    return _centred([
      _Ring(
        value: null,
        track: _track,
        child: _figure(EntityFormat.size(progress?.bytes ?? 0), 'found so far'),
      ),
      const SizedBox(height: 28),
      _title(progress == null ? 'Getting ready…' : '${_count(progress.items)} found'),
      const SizedBox(height: 8),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            progress?.kind?.icon ?? LucideIcons.scanSearch,
            size: 16,
            color: context.look.iconColor(progress?.kind?.icon, colors.mutedForeground),
          ),
          const SizedBox(width: 8),
          Flexible(child: _line(progress?.kind?.label ?? 'Looking through your files')),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        progress == null ? ' ' : _tail(progress.place),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: text.bodySmall,
      ),
      const SizedBox(height: 28),
      OutlinedButton.icon(
        onPressed: _stop,
        icon: const Icon(LucideIcons.circleStop, size: 16),
        label: const Text('Stop'),
      ),
    ]);
  }

  Widget _cleaningView() {
    final (count, size) = _deleting;
    final progress = _cleanProgress;
    final freed = progress?.freed ?? 0;
    final done = progress?.done ?? 0;
    final value = size > 0 ? freed / size : (count > 0 ? done / count : 0.0);
    return _centred([
      _Ring(value: value.clamp(0.0, 1.0), track: _track, child: _figure(EntityFormat.size(freed), 'freed')),
      const SizedBox(height: 28),
      _title('Cleaning…'),
      const SizedBox(height: 8),
      _line('${_number.format(done)} of ${_count(count)} deleted'),
    ]);
  }

  /// What a clean-up freed, or with no [result] that the scan found nothing.
  Widget _doneView(JunkCleanResult? result) {
    final colors = context.colors;
    final failed = result?.failed ?? 0;
    return _centred([
      _Ring(value: 1, track: _track, child: _Badge(LucideIcons.check)),
      const SizedBox(height: 28),
      if (result == null) ...[
        _title('No junk found'),
        const SizedBox(height: 8),
        _line("There's nothing to clean right now."),
      ] else ...[
        _title('${EntityFormat.size(result.freed)} freed'),
        const SizedBox(height: 8),
        _line('${_count(result.removed)} deleted'),
      ],
      if (failed > 0) ...[
        const SizedBox(height: 18),
        _Note(
          icon: LucideIcons.triangleAlert,
          color: colors.destructive,
          text: "${_count(failed)} couldn't be deleted, as they're in use or protected.",
          action: TextButton.icon(
            onPressed: _showNotDeleted,
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
            onPressed: _startScan,
            icon: const Icon(LucideIcons.refreshCw, size: 18),
            label: const Text('Scan again'),
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

  Widget _summary() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final chosen = _sizeOf(_chosenItems);
    final found = _sizeOf([for (final group in _groups) ...group.items]);
    final items = _groups.fold(0, (sum, group) => sum + group.items.length);
    return _panel(
      Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            _Ring(
              size: 84,
              stroke: 8,
              value: found > 0 ? chosen / found : 0,
              track: _track,
              child: Icon(Tool.junkCleaner.icon, size: 26, color: colors.primary),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    EntityFormat.size(chosen),
                    style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                  ),
                  Text('can be freed', style: text.bodyMedium),
                  const SizedBox(height: 4),
                  Text('${EntityFormat.size(found)} found in ${_count(items)}', style: text.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A section's heading, with what it means.
  Widget _heading(IconData icon, String title, String about) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(_grouped ? 16 : 6, 24, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_grouped)
            // iOS: small grey capitals over the card.
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
          const SizedBox(height: 2),
          Text(about, style: text.bodySmall),
        ],
      ),
    );
  }

  /// [groups] on one card, a line between each.
  Widget _section(List<JunkGroup> groups) {
    final line = _grouped ? IosStyle.separator(_dark) : context.colors.border;
    return _panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, group) in groups.indexed) ...[
            if (index > 0) Divider(height: 1, thickness: _grouped ? 0.5 : 1, indent: 90, color: line),
            _group(group),
          ],
        ],
      ),
    );
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
          onTap: () => _tickGroup(group),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
            child: Row(
              children: [
                _KindCheck(selected: _tickOf(group)),
                const SizedBox(width: 12),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SizedBox.square(
                    dimension: 34,
                    child: Icon(kind.icon, size: 18, color: context.look.iconColor(kind.icon, colors.primary)),
                  ),
                ),
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
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(EntityFormat.size(group.size), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                    Text(_count(group.items.length), style: text.bodySmall),
                  ],
                ),
                IconButton(
                  tooltip: open ? 'Hide files' : 'Show files',
                  icon: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18),
                  onPressed: () => setState(() => open ? _open.remove(kind) : _open.add(kind)),
                ),
              ],
            ),
          ),
        ),
        if (open) ...[
          for (final item in group.items.take(_shown)) _item(item),
          if (group.items.length > _shown)
            Padding(
              padding: const EdgeInsets.fromLTRB(44, 3, 16, 8),
              child: Text('and ${group.items.length - _shown} more', style: text.bodySmall),
            ),
          const SizedBox(height: 6),
        ],
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
        onTap: () => _tickItem(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(44, 5, 16, 5),
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

  /// The Clean button, at the foot of the page: with how much is ticked
  /// beside it in a wide window.
  Widget _cleanBar() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final chosen = _chosenItems;
    final all = _groups.fold(0, (sum, group) => sum + group.items.length);
    final button = FilledButton.icon(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
      onPressed: chosen.isEmpty ? null : _clean,
      icon: Icon(Tool.junkCleaner.icon, size: 20),
      label: Text(
        'Clean ${EntityFormat.size(_sizeOf(chosen))}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
    final wide = MediaQuery.sizeOf(context).width >= 600;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: _grouped ? IosStyle.separator(_dark) : colors.border, width: _grouped ? 0.5 : 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: _limit(
            wide
                ? Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_number.format(chosen.length)} of ${_count(all)} ticked',
                          style: text.bodyMedium?.copyWith(color: colors.mutedForeground),
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(width: 280, child: button),
                    ],
                  )
                : SizedBox(width: double.infinity, child: button),
          ),
        ),
      ),
    );
  }

  Widget _resultsView() {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final junk = [for (final group in _groups) if (!group.kind.review) group];
    final review = [for (final group in _groups) if (group.kind.review) group];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.fromLTRB(12, top + 16, 12, 16),
            children: [
              _limit(_summary()),
              if (junk.isNotEmpty) ...[
                _limit(_heading(
                  Tool.junkCleaner.icon,
                  'Junk',
                  "What's certainly safe to lose is ticked; tick anything else you want gone.",
                )),
                _limit(_section(junk)),
              ],
              if (review.isNotEmpty) ...[
                _limit(_heading(
                  LucideIcons.scanSearch,
                  'Review',
                  'Not junk: big and old files worth a look. Nothing here is ticked until you tick it.',
                )),
                _limit(_section(review)),
              ],
            ],
          ),
        ),
        _cleanBar(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = switch (_stage) {
      _Stage.start => _startView(),
      _Stage.scanning => _scanningView(),
      _Stage.results when _groups.isEmpty => _doneView(null),
      _Stage.results => _resultsView(),
      _Stage.cleaning => _cleaningView(),
      _Stage.done => _doneView(_result),
    };
    return ExplorerScaffold(
      title: 'Junk cleaner',
      // iOS's grouped lists: white cards on a grey page, as see-through as
      // the page would be.
      backgroundColor: _grouped ? IosStyle.groupedBackground(_dark).withValues(alpha: colors.background.a) : null,
      trailing: _stage == _Stage.results
          ? AppIconButton(icon: const Icon(LucideIcons.refreshCw), tooltip: 'Scan again', onPressed: _startScan)
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
String _ago(DateTime at, {DateTime? now}) {
  final gone = (now ?? DateTime.now()).difference(at);
  String count(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';
  if (gone.inMinutes < 1) return 'just now';
  if (gone.inHours < 1) return count(gone.inMinutes, 'minute');
  if (gone.inDays < 1) return count(gone.inHours, 'hour');
  if (gone.inDays < 2) return 'yesterday';
  if (gone.inDays < 30) return count(gone.inDays, 'day');
  return 'on ${EntityFormat.date(at)}';
}

/// The last clean-up, for the start screen.
class _LastClean {
  const _LastClean(this.at, this.freed, this.items);

  final DateTime at;
  final int freed;
  final int items;

  static const _atKey = 'junk_cleaner_last_at';
  static const _freedKey = 'junk_cleaner_last_freed';
  static const _itemsKey = 'junk_cleaner_last_items';

  static Future<_LastClean?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_atKey);
    final freed = prefs.getInt(_freedKey);
    if (at == null || freed == null) return null;
    return _LastClean(DateTime.fromMillisecondsSinceEpoch(at), freed, prefs.getInt(_itemsKey) ?? 0);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_atKey, at.millisecondsSinceEpoch);
    await prefs.setInt(_freedKey, freed);
    await prefs.setInt(_itemsKey, items);
  }
}

/// The cleaner's ring, like the RAM cleaner's gauge: a track, and an arc
/// that fills to [value]. It spins while [value] is null.
class _Ring extends StatelessWidget {
  const _Ring({required this.value, required this.track, required this.child, this.size = 200, this.stroke = 12});

  final double? value;
  final Color track;
  final Widget child;
  final double size;
  final double stroke;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    final color = context.colors.primary;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (value == null)
            CircularProgressIndicator(
              strokeWidth: stroke,
              strokeCap: StrokeCap.round,
              color: color,
              backgroundColor: track,
            )
          else
            TweenAnimationBuilder<double>(
              tween: Tween(end: value),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              builder: (_, value, _) => CustomPaint(
                painter: _RingPainter(value: value, track: track, color: color, stroke: stroke),
              ),
            ),
          Padding(
            padding: EdgeInsets.all(stroke + size * 0.06),
            child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: child)),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.value, required this.track, required this.color, required this.stroke});

  final double value;
  final Color track;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawOval(rect, paint);
    if (value <= 0) return;
    paint
      ..color = color
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * math.min(value, 1), false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.track != track || old.color != color || old.stroke != stroke;
}

/// An icon on a soft disc of the theme's colour, inside the ring.
class _Badge extends StatelessWidget {
  const _Badge(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: colors.primary.withValues(alpha: 0.12)),
      child: SizedBox.square(dimension: 112, child: Icon(icon, size: 48, color: colors.primary)),
    );
  }
}

/// A line in a soft pill under a state's words: the last clean-up, or what
/// couldn't be deleted, with a button.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.color, this.action});

  final IconData icon;
  final String text;
  final Color? color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tint = color ?? colors.mutedForeground;
    final action = this.action;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 8, action == null ? 14 : 6, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color ?? colors.foreground),
              ),
            ),
            if (action != null) ...[const SizedBox(width: 4), action],
          ],
        ),
      ),
    );
  }
}

/// Something that couldn't be deleted: its name, size and where it is.
class _NotDeletedRow extends StatelessWidget {
  const _NotDeletedRow(this.item);

  final JunkItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(item.isFolder ? LucideIcons.folder : LucideIcons.file, size: 18, color: colors.mutedForeground),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.basename(item.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                Text(p.dirname(item.path), maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(EntityFormat.size(item.size), style: text.bodySmall),
        ],
      ),
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
