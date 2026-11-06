import 'dart:math' as math;

import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:folders/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:folders/features/viewer_pdf/services/pdf_page_rasterizer.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_page_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Page organiser: select, reorder (drag or move up/down), rotate, delete and
/// insert blank pages. Changes are collected locally and applied in one go
/// with [onApply]; extracting and inserting another PDF act immediately.
class PdfPageManager extends StatefulWidget {
  const PdfPageManager({
    super.key,
    required this.metas,
    required this.rasterizer,
    required this.currentPage,
    required this.busy,
    required this.onOpenPage,
    required this.onApply,
    required this.onExtract,
    required this.onInsertPdf,
    required this.onNeedData,
  });

  /// Pages of the current document; null while loading.
  final List<PdfPageMeta>? metas;
  final PdfPageRasterizer? rasterizer;

  /// 1-based page shown in the viewer.
  final ValueListenable<int> currentPage;
  final bool busy;
  final ValueChanged<int> onOpenPage;
  final ValueChanged<List<PagePlanEntry>> onApply;
  final ValueChanged<Set<int>> onExtract;
  final VoidCallback onInsertPdf;

  /// Asks the owner to load [metas]/[rasterizer]; called while they're null
  /// and the manager is on screen.
  final VoidCallback onNeedData;

  @override
  State<PdfPageManager> createState() => _PdfPageManagerState();
}

class _PlanItem {
  _PlanItem(this.id, this.entry);

  final int id;
  PagePlanEntry entry;
}

enum _MoreAction { moveUp, moveDown, moveFirst, moveLast, extract, insertPdf }

class _PdfPageManagerState extends State<PdfPageManager> {
  List<_PlanItem> _items = [];
  final Set<int> _selected = {};
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    _reset();
    _requestDataIfNeeded();
  }

  @override
  void didUpdateWidget(PdfPageManager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.metas, widget.metas)) _reset();
    _requestDataIfNeeded();
  }

  void _requestDataIfNeeded() {
    if (widget.metas != null && widget.rasterizer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onNeedData();
    });
  }

  void _reset() {
    final metas = widget.metas ?? const <PdfPageMeta>[];
    _nextId = 0;
    _items = [
      for (var i = 0; i < metas.length; i++)
        _PlanItem(_nextId++, PagePlanEntry.source(i)),
    ];
    _selected.clear();
  }

  bool get _hasChanges {
    final metas = widget.metas;
    if (metas == null) return false;
    if (_items.length != metas.length) return true;
    for (var i = 0; i < _items.length; i++) {
      final entry = _items[i].entry;
      if (entry.isBlank || entry.sourceIndex != i || entry.quarterTurns != 0) {
        return true;
      }
    }
    return false;
  }

  List<int> get _selectedPositions => [
    for (var i = 0; i < _items.length; i++)
      if (_selected.contains(_items[i].id)) i,
  ];

  void _toggle(_PlanItem item) => setState(() {
    if (!_selected.remove(item.id)) _selected.add(item.id);
  });

  void _rotateSelected(int turns) => setState(() {
    for (final item in _items) {
      if (_selected.contains(item.id)) {
        item.entry = item.entry.rotated(turns);
      }
    }
  });

  void _deleteSelected() {
    if (_selected.length >= _items.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A PDF needs at least one page')),
      );
      return;
    }
    setState(() {
      _items.removeWhere((item) => _selected.contains(item.id));
      _selected.clear();
    });
  }

  void _insertBlank() {
    final positions = _selectedPositions;
    final metas = widget.metas ?? const <PdfPageMeta>[];
    final at = positions.isEmpty ? _items.length : positions.last + 1;
    final neighbour = _items.isEmpty
        ? null
        : _items[(at - 1).clamp(0, _items.length - 1)];
    var size = const Size(595, 842);
    final source = neighbour?.entry.sourceIndex;
    if (neighbour != null && neighbour.entry.isBlank) {
      size = neighbour.entry.blankSize!;
    } else if (source != null && source < metas.length) {
      size = metas[source].displaySize;
      if ((neighbour!.entry.quarterTurns).isOdd) size = size.flipped;
    }
    setState(() {
      final item = _PlanItem(_nextId++, PagePlanEntry.blank(size));
      _items.insert(at, item);
      _selected
        ..clear()
        ..add(item.id);
    });
  }

  void _move(_MoreAction action) {
    final positions = _selectedPositions;
    if (positions.isEmpty) return;
    setState(() {
      final moving = [for (final i in positions) _items[i]];
      switch (action) {
        case _MoreAction.moveFirst:
          _items.removeWhere(moving.contains);
          _items.insertAll(0, moving);
        case _MoreAction.moveLast:
          _items.removeWhere(moving.contains);
          _items.addAll(moving);
        case _MoreAction.moveUp:
          for (final i in positions) {
            if (i == 0 || _selected.contains(_items[i - 1].id)) continue;
            final item = _items.removeAt(i);
            _items.insert(i - 1, item);
          }
        case _MoreAction.moveDown:
          for (final i in positions.reversed) {
            if (i >= _items.length - 1 ||
                _selected.contains(_items[i + 1].id)) {
              continue;
            }
            final item = _items.removeAt(i);
            _items.insert(i + 1, item);
          }
        default:
          break;
      }
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final item = _items.removeAt(oldIndex);
      _items.insert(newIndex, item);
    });
  }

  void _onMore(_MoreAction action) {
    switch (action) {
      case _MoreAction.extract:
        final pages = {
          for (final item in _items)
            if (_selected.contains(item.id) && !item.entry.isBlank)
              item.entry.sourceIndex!,
        };
        if (pages.isNotEmpty) widget.onExtract(pages);
      case _MoreAction.insertPdf:
        widget.onInsertPdf();
      default:
        _move(action);
    }
  }

  @override
  Widget build(BuildContext context) {
    final metas = widget.metas;
    if (metas == null) {
      return const Center(child: ViewerSpinner(size: 20));
    }
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final hasSelection = _selected.isNotEmpty;
    final hasChanges = _hasChanges;
    final enabled = !widget.busy;
    final selectedRealPages = _items.any(
      (item) => _selected.contains(item.id) && !item.entry.isBlank,
    );
    final allSelected = hasSelection && _selected.length == _items.length;

    Widget tool(
      IconData icon,
      String tooltip,
      VoidCallback? onPressed, {
      bool destructive = false,
    }) {
      return ViewerAction(
        icon: icon,
        tooltip: tooltip,
        size: 36,
        iconSize: 18,
        color: destructive && onPressed != null ? colors.destructive : null,
        onPressed: onPressed,
      );
    }

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          Checkbox(
            tristate: true,
            value: allSelected ? true : (hasSelection ? null : false),
            onChanged: enabled
                ? (_) => setState(() {
                    if (hasSelection) {
                      _selected.clear();
                    } else {
                      _selected.addAll(_items.map((item) => item.id));
                    }
                  })
                : null,
          ),
          Expanded(
            child: Text(
              hasSelection
                  ? '${_selected.length} selected'
                  : '${_items.length} pages',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelLarge,
            ),
          ),
          tool(
            LucideIcons.rotateCcw,
            'Rotate left',
            enabled && hasSelection ? () => _rotateSelected(3) : null,
          ),
          tool(
            LucideIcons.rotateCw,
            'Rotate right',
            enabled && hasSelection ? () => _rotateSelected(1) : null,
          ),
          tool(
            LucideIcons.trash2,
            'Delete pages',
            enabled && hasSelection ? _deleteSelected : null,
            destructive: true,
          ),
          tool(
            LucideIcons.filePlus2,
            hasSelection
                ? 'Insert blank page after selection'
                : 'Add blank page at the end',
            enabled ? _insertBlank : null,
          ),
          ViewerMenuButton<_MoreAction>(
            tooltip: 'More page actions',
            size: 36,
            enabled: enabled,
            onSelected: _onMore,
            itemBuilder: (context) => [
              viewerMenuItem(
                value: _MoreAction.moveUp,
                icon: LucideIcons.arrowUp,
                label: 'Move up',
                enabled: hasSelection,
              ),
              viewerMenuItem(
                value: _MoreAction.moveDown,
                icon: LucideIcons.arrowDown,
                label: 'Move down',
                enabled: hasSelection,
              ),
              viewerMenuItem(
                value: _MoreAction.moveFirst,
                icon: LucideIcons.arrowUpToLine,
                label: 'Move to start',
                enabled: hasSelection,
              ),
              viewerMenuItem(
                value: _MoreAction.moveLast,
                icon: LucideIcons.arrowDownToLine,
                label: 'Move to end',
                enabled: hasSelection,
              ),
              viewerMenuDivider(),
              viewerMenuItem(
                value: _MoreAction.extract,
                icon: LucideIcons.fileOutput,
                label: hasChanges
                    ? 'Extract (apply changes first)'
                    : 'Extract to new PDF',
                enabled: selectedRealPages && !hasChanges,
              ),
              viewerMenuItem(
                value: _MoreAction.insertPdf,
                icon: LucideIcons.fileInput,
                label: 'Insert PDF…',
                enabled: !hasChanges,
              ),
            ],
          ),
        ],
      ),
    );

    final list = ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: _items.length,
      onReorderItem: enabled ? _onReorder : (_, _) {},
      proxyDecorator: (child, index, animation) => Material(
        color: Colors.transparent,
        child: AppPanel(child: child),
      ),
      itemBuilder: (context, index) {
        final item = _items[index];
        final entry = item.entry;
        final source = entry.sourceIndex;
        final meta = source != null && source < metas.length
            ? metas[source]
            : null;
        final selected = _selected.contains(item.id);
        final displaySize =
            meta?.displaySize ?? entry.blankSize ?? const Size(595, 842);
        final aspect = displaySize.isEmpty
            ? 0.7
            : displaySize.width / displaySize.height;
        // Keep a turned page inside the thumbnail column.
        final thumbWidth = entry.quarterTurns.isOdd
            ? math.min(52.0, 68 * aspect)
            : 52.0;
        final notes = <String>[
          if (entry.isBlank) 'New blank page',
          if (source != null && source != index) 'Was page ${source + 1}',
          if (entry.quarterTurns != 0) 'Rotated ${entry.quarterTurns * 90}°',
        ];
        return Padding(
          key: ValueKey(item.id),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Material(
            color: selected ? colors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: !enabled
                  ? null
                  : hasSelection
                  ? () => _toggle(item)
                  : source != null
                  ? () => widget.onOpenPage(source)
                  : null,
              onLongPress: enabled ? () => _toggle(item) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 6, 4, 6),
                child: Row(
                  children: [
                    Checkbox(
                      value: selected,
                      onChanged: enabled ? (_) => _toggle(item) : null,
                    ),
                    SizedBox(
                      width: 68,
                      child: Center(
                        child: ValueListenableBuilder<int>(
                          valueListenable: widget.currentPage,
                          builder: (context, current, _) => PdfPageThumbnail(
                            rasterizer: widget.rasterizer,
                            pageNumber: source == null ? null : source + 1,
                            displaySize: displaySize,
                            width: thumbWidth,
                            quarterTurns: entry.quarterTurns,
                            highlighted:
                                source != null && current == source + 1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Page ${index + 1}',
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: selected
                                  ? colors.accentForeground
                                  : colors.foreground,
                            ),
                          ),
                          if (notes.isNotEmpty)
                            Text(
                              notes.join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    ReorderableDragStartListener(
                      index: index,
                      enabled: enabled,
                      child: Tooltip(
                        message: 'Drag to reorder',
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Icon(
                            LucideIcons.gripVertical,
                            size: 18,
                            color: colors.mutedForeground,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    return Column(
      children: [
        header,
        Divider(height: 1, color: colors.border),
        Expanded(child: list),
        if (hasChanges)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.border)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: enabled ? () => setState(_reset) : null,
                      child: const Text('Discard'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: enabled
                          ? () => widget.onApply([
                              for (final item in _items) item.entry,
                            ])
                          : null,
                      child: const Text('Apply changes'),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
