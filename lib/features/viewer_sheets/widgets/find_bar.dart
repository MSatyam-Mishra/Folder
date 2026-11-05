import 'dart:async';

import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/spreadsheet_controller.dart';

/// Docked find & replace panel.
class FindReplaceBar extends StatefulWidget {
  const FindReplaceBar({
    super.key,
    required this.controller,
    required this.onClose,
    required this.onMessage,
    this.replaceMode = false,
  });

  final SpreadsheetController controller;
  final VoidCallback onClose;
  final void Function(String message) onMessage;
  final bool replaceMode;

  @override
  State<FindReplaceBar> createState() => _FindReplaceBarState();
}

class _FindReplaceBarState extends State<FindReplaceBar> {
  final _find = TextEditingController();
  final _replace = TextEditingController();
  final _findFocus = FocusNode();
  late bool _replaceMode = widget.replaceMode;
  bool _matchCase = false;
  bool _wholeCell = false;
  bool _allSheets = false;
  List<FindMatch> _matches = const [];
  int _index = -1;
  Timer? _debounce;
  int _searchedVersion = -1;

  FindOptions get _opts =>
      FindOptions(matchCase: _matchCase, wholeCell: _wholeCell, allSheets: _allSheets);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant FindReplaceBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.replaceMode != oldWidget.replaceMode && widget.replaceMode) {
      setState(() => _replaceMode = true);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _find.dispose();
    _replace.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  void _search({bool keepIndex = false}) {
    final m = widget.controller.findAll(_find.text, _opts);
    setState(() {
      _matches = m;
      _searchedVersion = widget.controller.contentVersion;
      if (!keepIndex || _index >= m.length) _index = m.isEmpty ? -1 : 0;
    });
    if (!keepIndex && _matches.isNotEmpty) widget.controller.goToMatch(_matches[0]);
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _search);
  }

  void _step(int delta) {
    if (_searchedVersion != widget.controller.contentVersion) _search(keepIndex: true);
    if (_matches.isEmpty) return;
    setState(() => _index = (_index + delta) % _matches.length);
    if (_index < 0) _index += _matches.length;
    widget.controller.goToMatch(_matches[_index]);
  }

  void _replaceCurrent() {
    if (_matches.isEmpty || _index < 0) return;
    final ok = widget.controller.replaceOne(_matches[_index], _find.text, _replace.text, _opts);
    if (!ok) widget.onMessage('Nothing to replace in this cell.');
    _search(keepIndex: true);
    if (_matches.isNotEmpty) widget.controller.goToMatch(_matches[_index.clamp(0, _matches.length - 1)]);
  }

  void _replaceAll() {
    if (_find.text.isEmpty) return;
    final n = widget.controller.replaceAll(_find.text, _replace.text, _opts);
    widget.onMessage(n == 0 ? 'No matches replaced.' : 'Replaced $n ${n == 1 ? 'cell' : 'cells'}.');
    _search(keepIndex: true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _step(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final status = _find.text.isEmpty
        ? ''
        : (_matches.isEmpty ? 'No results' : '${_index + 1} of ${_matches.length}');
    final options = _matchCase || _wholeCell || _allSheets;
    Widget field(TextEditingController ctrl, String hint,
        {FocusNode? focus, ValueChanged<String>? onChanged, IconData? icon}) {
      return SizedBox(
        height: 36,
        child: TextField(
          controller: ctrl,
          focusNode: focus,
          onChanged: onChanged,
          style: theme.textTheme.bodyMedium,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            prefixIcon: icon == null ? null : Icon(icon, size: 16),
            prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ),
      );
    }

    return Focus(
      onKeyEvent: _onKey,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ViewerAction(
                    tooltip: _replaceMode ? 'Hide replace' : 'Show replace',
                    icon: _replaceMode ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 36,
                    iconSize: 16,
                    color: colors.mutedForeground,
                    onPressed: () => setState(() => _replaceMode = !_replaceMode),
                  ),
                  Expanded(
                    child: field(
                      _find,
                      'Find',
                      focus: _findFocus,
                      onChanged: _onQueryChanged,
                      icon: LucideIcons.search,
                    ),
                  ),
                  if (status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        status,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ViewerAction(
                    tooltip: 'Previous',
                    icon: LucideIcons.chevronUp,
                    size: 36,
                    iconSize: 18,
                    onPressed: _matches.isEmpty ? null : () => _step(-1),
                  ),
                  ViewerAction(
                    tooltip: 'Next',
                    icon: LucideIcons.chevronDown,
                    size: 36,
                    iconSize: 18,
                    onPressed: _matches.isEmpty ? null : () => _step(1),
                  ),
                  ViewerMenuButton<String>(
                    tooltip: 'Options',
                    icon: LucideIcons.slidersHorizontal,
                    badge: options,
                    size: 36,
                    minMenuWidth: 190,
                    onSelected: (v) {
                      setState(() {
                        if (v == 'case') _matchCase = !_matchCase;
                        if (v == 'whole') _wholeCell = !_wholeCell;
                        if (v == 'all') _allSheets = !_allSheets;
                      });
                      _search();
                    },
                    itemBuilder: (_) => [
                      viewerMenuItem(
                        value: 'case',
                        icon: LucideIcons.caseSensitive,
                        label: 'Match case',
                        checked: _matchCase,
                      ),
                      viewerMenuItem(
                        value: 'whole',
                        icon: LucideIcons.squareDashed,
                        label: 'Entire cell',
                        checked: _wholeCell,
                      ),
                      viewerMenuItem(
                        value: 'all',
                        icon: LucideIcons.layers,
                        label: 'All sheets',
                        checked: _allSheets,
                      ),
                    ],
                  ),
                  ViewerAction(
                    tooltip: 'Close',
                    icon: LucideIcons.x,
                    size: 36,
                    iconSize: 18,
                    onPressed: widget.onClose,
                  ),
                ],
              ),
              if (_replaceMode)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 36, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: field(_replace, 'Replace with', icon: LucideIcons.replace),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: _matches.isEmpty ? null : _replaceCurrent,
                        child: const Text('Replace'),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: _find.text.isEmpty ? null : _replaceAll,
                        child: const Text('All'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
