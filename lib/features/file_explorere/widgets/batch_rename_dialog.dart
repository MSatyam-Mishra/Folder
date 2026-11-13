import 'dart:io';
import 'dart:math' as math;

import 'package:folders/core/services/batch_rename.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Renames several items at once (Rename or F2 with more than one
/// selected): a pattern with `{name}`, `{ext}`, `{n}` and `{date}`, find
/// and replace, case, prefix and suffix, with every new name shown and
/// checked before anything changes. Pops the plans to apply.
class BatchRenameDialog extends StatefulWidget {
  const BatchRenameDialog({super.key, required this.sources, this.namesIn});

  final List<RenameSource> sources;

  /// A folder's names; read from the disk unless given (tests).
  final Set<String> Function(String folder)? namesIn;

  /// Asks for the new names of [entities] and renames them; the folder shows
  /// them, and the message after has Undo.
  static Future<void> run(BuildContext context, List<FileSystemEntity> entities) async {
    if (entities.isEmpty) return;
    final bloc = context.read<FileExplorerBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final sources = [for (final e in entities) RenameSource.of(e)];
    final plans = await showDialog<List<RenamePlan>>(
      context: context,
      builder: (_) => BatchRenameDialog(sources: sources),
    );
    if (plans == null) return;
    final result = await BatchRename.apply(plans);
    _refresh(bloc);
    final done = result.done.length;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(result.failed.isEmpty
            ? 'Renamed $done ${done == 1 ? 'item' : 'items'}'
            : "Renamed $done; ${result.failed.length} couldn't be: ${result.failed.values.first}"),
        action: done == 0
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  final back = await BatchRename.undo(result);
                  _refresh(bloc);
                  if (back.failed.isNotEmpty) {
                    messenger.showSnackBar(
                      SnackBar(content: Text("${back.failed.length} couldn't get their names back")),
                    );
                  }
                },
              ),
      ));
  }

  static void _refresh(FileExplorerBloc bloc) {
    if (bloc.isClosed) return;
    final state = bloc.state;
    bloc.add(ToggleSelectionMode(enable: false));
    if (state is FileExplorerLoaded) bloc.add(LoadDirectory(state.path));
  }

  @override
  State<BatchRenameDialog> createState() => _BatchRenameDialogState();
}

class _BatchRenameDialogState extends State<BatchRenameDialog> {
  final _pattern = TextEditingController(text: '{name}');
  final _find = TextEditingController();
  final _replace = TextEditingController();
  final _prefix = TextEditingController();
  final _suffix = TextEditingController();
  final _start = TextEditingController(text: '1');
  final _step = TextEditingController(text: '1');
  final _digits = TextEditingController(text: '2');
  final _dateFormat = TextEditingController(text: 'yyyy-MM-dd');
  final _patternFocus = FocusNode();
  bool _regex = false;
  bool _matchCase = false;
  bool _keepExtension = true;
  NameCase _case = NameCase.keep;

  final _names = <String, Set<String>>{};
  late List<RenamePlan> _plans = _plan();

  /// The most rows the preview shows.
  static const _shown = 200;

  @override
  void dispose() {
    for (final c in [_pattern, _find, _replace, _prefix, _suffix, _start, _step, _digits, _dateFormat]) {
      c.dispose();
    }
    _patternFocus.dispose();
    super.dispose();
  }

  BatchRenameOptions get _options => BatchRenameOptions(
        pattern: _pattern.text,
        find: _find.text,
        replace: _replace.text,
        regex: _regex,
        matchCase: _matchCase,
        nameCase: _case,
        prefix: _prefix.text,
        suffix: _suffix.text,
        keepExtension: _keepExtension,
        start: int.tryParse(_start.text) ?? 1,
        step: int.tryParse(_step.text) ?? 1,
        digits: int.tryParse(_digits.text) ?? 1,
        dateFormat: _dateFormat.text.isEmpty ? 'yyyy-MM-dd' : _dateFormat.text,
      );

  List<RenamePlan> _plan() => BatchRename.plan(
        widget.sources,
        _options,
        namesIn: (folder) => _names.putIfAbsent(
          folder,
          () => widget.namesIn?.call(folder) ?? _listNames(folder),
        ),
      );

  static Set<String> _listNames(String folder) {
    try {
      return {for (final e in Directory(folder).listSync(followLinks: false)) p.basename(e.path)};
    } catch (_) {
      return const {};
    }
  }

  void _changed([Object? _]) => setState(() => _plans = _plan());

  void _insert(String token) {
    final text = _pattern.text;
    final selection = _pattern.selection;
    final at = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    _pattern.value = TextEditingValue(
      text: text.replaceRange(at, end, token),
      selection: TextSelection.collapsed(offset: at + token.length),
    );
    _patternFocus.requestFocus();
    _changed();
  }

  int get _problems => _plans.where((p) => !p.ok).length;
  int get _changes => _plans.where((p) => p.ok && p.changed).length;
  bool get _canApply => _problems == 0 && _changes > 0;

  void _submit() {
    if (_canApply) Navigator.pop(context, _plans);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final width = math.min(640.0, MediaQuery.sizeOf(context).width - 48);
    final usesNumbers = _pattern.text.contains('{n');
    final usesDate = _pattern.text.contains('{date');

    Widget field(TextEditingController controller, String label, {String? hint, List<TextInputFormatter>? only, TextInputType? keyboard}) =>
        TextField(
          controller: controller,
          onChanged: _changed,
          onSubmitted: (_) => _submit(),
          inputFormatters: only,
          keyboardType: keyboard,
          decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
        );
    final number = [FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,6}'))];
    Widget gap([double h = 12]) => SizedBox(height: h, width: h);

    final problems = [for (final p in _plans) if (!p.ok) p];
    final rest = [for (final p in _plans) if (p.ok) p];
    final rows = [...problems, ...rest].take(_shown).toList();

    return AlertDialog(
      title: Text('Rename ${widget.sources.length} items'),
      scrollable: true,
      content: SizedBox(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('batch-pattern'),
              controller: _pattern,
              focusNode: _patternFocus,
              autofocus: true,
              onChanged: _changed,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'New name', isDense: true),
            ),
            gap(8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (token, label, icon) in [
                  ('{name}', 'Name', LucideIcons.letterText),
                  ('{ext}', 'Extension', LucideIcons.fileType),
                  ('{n}', 'Number', LucideIcons.hash),
                  ('{date}', 'Date modified', LucideIcons.calendar),
                ])
                  ActionChip(
                    avatar: Icon(icon, size: 14),
                    label: Text(label),
                    tooltip: 'Add $token',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _insert(token),
                  ),
              ],
            ),
            if (usesNumbers) ...[
              gap(),
              Row(children: [
                Expanded(child: field(_start, 'Start at', only: number, keyboard: TextInputType.number)),
                gap(),
                Expanded(child: field(_step, 'Step', only: number, keyboard: TextInputType.number)),
                gap(),
                Expanded(child: field(_digits, 'Digits', only: number, keyboard: TextInputType.number)),
              ]),
            ],
            if (usesDate) ...[
              gap(),
              field(_dateFormat, 'Date format', hint: 'yyyy-MM-dd'),
            ],
            gap(16),
            Row(children: [
              Expanded(child: field(_find, 'Find')),
              gap(),
              Expanded(child: field(_replace, 'Replace with')),
            ]),
            gap(8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilterChip(
                  avatar: const Icon(LucideIcons.regex, size: 14),
                  label: const Text('Regular expression'),
                  selected: _regex,
                  showCheckmark: false,
                  onSelected: (v) => _changed(_regex = v),
                ),
                FilterChip(
                  avatar: const Icon(LucideIcons.caseSensitive, size: 14),
                  label: const Text('Match case'),
                  selected: _matchCase,
                  showCheckmark: false,
                  onSelected: (v) => _changed(_matchCase = v),
                ),
                FilterChip(
                  avatar: const Icon(LucideIcons.fileCheck2, size: 14),
                  label: const Text('Keep extensions'),
                  selected: _keepExtension,
                  showCheckmark: false,
                  onSelected: (v) => _changed(_keepExtension = v),
                ),
              ],
            ),
            gap(16),
            Row(children: [
              Expanded(child: field(_prefix, 'Add before')),
              gap(),
              Expanded(child: field(_suffix, 'Add after')),
            ]),
            gap(12),
            SegmentedButton<NameCase>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: NameCase.keep, icon: Icon(LucideIcons.type, size: 14), label: Text('As is')),
                ButtonSegment(value: NameCase.lower, icon: Icon(LucideIcons.caseLower, size: 14), label: Text('lower')),
                ButtonSegment(value: NameCase.upper, icon: Icon(LucideIcons.caseUpper, size: 14), label: Text('UPPER')),
                ButtonSegment(value: NameCase.title, icon: Icon(LucideIcons.caseSensitive, size: 14), label: Text('Title')),
              ],
              selected: {_case},
              onSelectionChanged: (s) => _changed(_case = s.first),
            ),
            gap(16),
            Row(
              children: [
                Text('Preview', style: text.titleSmall),
                const Spacer(),
                Text(
                  problems.isNotEmpty
                      ? '${problems.length} ${problems.length == 1 ? 'problem' : 'problems'}'
                      : '$_changes will change',
                  style: text.bodySmall?.copyWith(color: problems.isNotEmpty ? colors.destructive : null),
                ),
              ],
            ),
            gap(6),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.border),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (final plan in rows) _PreviewRow(plan: plan),
                    if (_plans.length > rows.length)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text('and ${_plans.length - rows.length} more', style: text.bodySmall),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _canApply ? _submit : null, child: const Text('Rename')),
      ],
    );
  }
}

/// "old name → new name", the problem under it if there's one.
class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.plan});

  final RenamePlan plan;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final bad = !plan.ok;
    final same = plan.ok && !plan.changed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              bad ? LucideIcons.circleAlert : (same ? LucideIcons.minus : LucideIcons.arrowRight),
              size: 14,
              color: bad ? colors.destructive : colors.mutedForeground,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.source.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                Text(
                  same ? 'Unchanged' : plan.newName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(
                    color: bad ? colors.destructive : (same ? colors.mutedForeground : null),
                    fontWeight: same ? null : FontWeight.w500,
                  ),
                ),
                if (bad && plan.message != null)
                  Text(plan.message!, style: text.bodySmall?.copyWith(color: colors.destructive)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
