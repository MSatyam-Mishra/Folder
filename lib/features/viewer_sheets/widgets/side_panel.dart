import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/input_parser.dart' show formulaDisplayText;
import '../model/workbook.dart';
import 'format_toolbar.dart' show numberFormatLabel;
import 'status_bar.dart' show formatStat;

/// Docked pane for wide screens: sheet list and a cell inspector.
class SheetSidePanel extends StatelessWidget {
  const SheetSidePanel({
    super.key,
    required this.controller,
    required this.onTabMenu,
    this.onAdd,
  });

  final SpreadsheetController controller;
  final void Function(int index, Offset globalPosition) onTabMenu;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.colors.background,
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final wb = controller.workbook;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: ViewerPanelHeader(
                  title: 'Sheets',
                  subtitle: '${wb.sheets.length} sheet${wb.sheets.length == 1 ? '' : 's'}',
                  actions: [
                    if (onAdd != null)
                      ViewerAction(
                        tooltip: 'Add sheet',
                        icon: LucideIcons.plus,
                        iconSize: 18,
                        onPressed: onAdd,
                      ),
                  ],
                ),
              ),
              SliverList.builder(
                itemCount: wb.sheets.length,
                itemBuilder: (context, i) {
                  final s = wb.sheets[i];
                  final hidden = s.visibility != SheetVisibility.visible;
                  return GestureDetector(
                    onSecondaryTapUp: (d) => onTabMenu(i, d.globalPosition),
                    onLongPressStart: (d) => onTabMenu(i, d.globalPosition),
                    child: ViewerListTile(
                      leading: Icon(hidden ? LucideIcons.eyeOff : LucideIcons.sheet),
                      title: s.name,
                      subtitle: s.usedRows == 0 ? 'Empty' : '${s.usedRows} rows · ${s.usedCols} columns',
                      selected: i == wb.activeSheet,
                      maxLines: 1,
                      onTap: () => controller.activateSheet(i),
                    ),
                  );
                },
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1, color: context.colors.border),
                ),
              ),
              SliverToBoxAdapter(child: _Inspector(controller: controller)),
            ],
          );
        },
      ),
    );
  }
}

class _Inspector extends StatelessWidget {
  const _Inspector({required this.controller});
  final SpreadsheetController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final c = controller;
    final cell = c.activeCell;
    final st = cell?.style ?? CellStyle.plain;
    final v = cell?.value;
    final type = cell == null || cell.isBlank
        ? 'Empty'
        : cell.formula != null
            ? 'Formula'
            : v is double
                ? (numberFormatLabel(st.numFmt) == 'Date' ? 'Date' : 'Number')
                : v is bool
                    ? 'Boolean'
                    : v is CellError
                        ? 'Error'
                        : 'Text';
    final rows = <(String, String)>[
      ('Cell', '${c.sheet.name}!${cellName(c.selRow, c.selCol)}'),
      ('Type', type),
      if (cell?.formula != null) ('Formula', formulaDisplayText(cell!.formula!)),
      if (v != null) ('Value', v is double ? v.toString() : v.toString()),
      if (v != null) ('Shows', c.display(cell).text),
      ('Format', '${numberFormatLabel(st.numFmt)}${st.numFmt == 'General' ? '' : '  (${st.numFmt})'}'),
      if (st.bold || st.italic || st.underline)
        ('Font', [if (st.bold) 'Bold', if (st.italic) 'Italic', if (st.underline) 'Underline'].join(', ')),
      if (st.fontColor != null) ('Text color', _hex(st.fontColor!)),
      if (st.fillColor != null) ('Fill', _hex(st.fillColor!)),
      if (st.hAlign != HAlign.general) ('Align', st.hAlign.name),
      if (c.sheet.mergeAt(c.selRow, c.selCol) != null) ('Merged', c.sheet.mergeAt(c.selRow, c.selCol)!.toA1()),
    ];
    final stats = c.selectionStats();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cell', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                children: [
                  for (final (k, val) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 84,
                            child: Text(k, style: theme.textTheme.bodySmall),
                          ),
                          Expanded(
                            child: SelectableText(
                              val,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.foreground,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (stats.cells > 1) ...[
            const SizedBox(height: 16),
            Text('Selection', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              [
                '${stats.cells} cells, ${stats.count} with values',
                if (stats.numericCount > 0) 'Sum ${formatStat(stats.sum)}',
                if (stats.numericCount > 0) 'Average ${formatStat(stats.average!)}',
                if (stats.numericCount > 0) 'Min ${formatStat(stats.min!)} · Max ${formatStat(stats.max!)}',
              ].join('\n'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  static String _hex(int c) => '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
