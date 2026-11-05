import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/number_format.dart';
import '../model/workbook.dart';
import 'color_palette.dart';
import 'text_prompt.dart';

/// Number format presets offered in the toolbar.
const kNumberFormatPresets = <(String, String)>[
  ('General', 'General'),
  ('Number', '#,##0.00'),
  ('Currency', r'"$"#,##0.00'),
  ('Percent', '0.00%'),
  ('Date', 'yyyy-mm-dd'),
  ('Date & time', 'yyyy-mm-dd h:mm'),
  ('Time', 'h:mm:ss'),
  ('Scientific', '0.00E+00'),
  ('Text', '@'),
];

String numberFormatLabel(String code) {
  for (final p in kNumberFormatPresets) {
    if (p.$2 == code) return p.$1;
  }
  if (NumberFormats.isDateFormat(code)) {
    return NumberFormats.isTimeOnlyFormat(code) ? 'Time' : 'Date';
  }
  if (code.contains('%')) return 'Percent';
  if (code.contains(r'$') || code.contains('€') || code.contains('£')) return 'Currency';
  if (code == '@') return 'Text';
  return 'Custom';
}

//// Cell formatting controls: bold/italic/underline, colours, alignment,
/// wrap, number format, decimals and merge.
class FormatToolbar extends StatelessWidget {
  const FormatToolbar({
    super.key,
    required this.controller,
    this.showUndoRedo = false,
    this.scrollable = true,
  });

  final SpreadsheetController controller;
  final bool showUndoRedo;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final st = c.activeStyle;
        final colors = context.colors;
        final items = <Widget>[
          if (showUndoRedo) ...[
            _ToolButton(
              icon: LucideIcons.undo2,
              tooltip: c.undoLabel == null ? 'Undo' : 'Undo ${c.undoLabel}',
              onPressed: c.canUndo ? c.undo : null,
            ),
            _ToolButton(
              icon: LucideIcons.redo2,
              tooltip: c.redoLabel == null ? 'Redo' : 'Redo ${c.redoLabel}',
              onPressed: c.canRedo ? c.redo : null,
            ),
            const _Sep(),
          ],
          _ToolButton(icon: LucideIcons.bold, tooltip: 'Bold', selected: st.bold, onPressed: c.toggleBold),
          _ToolButton(icon: LucideIcons.italic, tooltip: 'Italic', selected: st.italic, onPressed: c.toggleItalic),
          _ToolButton(
            icon: LucideIcons.underline,
            tooltip: 'Underline',
            selected: st.underline,
            onPressed: c.toggleUnderline,
          ),
          _ColorButton(
            icon: LucideIcons.baseline,
            tooltip: 'Text color',
            color: st.fontColor == null ? colors.foreground : Color(st.fontColor!),
            onPressed: () async {
              final choice = await showColorPalette(context,
                  title: 'Text color', noneLabel: 'Automatic', current: st.fontColor);
              if (choice != null) c.setFontColor(choice.color);
            },
          ),
          _ColorButton(
            icon: LucideIcons.paintBucket,
            tooltip: 'Fill color',
            color: st.fillColor == null ? Colors.transparent : Color(st.fillColor!),
            onPressed: () async {
              final choice = await showColorPalette(context,
                  title: 'Fill color', noneLabel: 'No fill', current: st.fillColor);
              if (choice != null) c.setFillColor(choice.color);
            },
          ),
          const _Sep(),
          _ToolButton(
            icon: LucideIcons.alignLeft,
            tooltip: 'Align left',
            selected: st.hAlign == HAlign.left,
            onPressed: () => c.setAlignment(st.hAlign == HAlign.left ? HAlign.general : HAlign.left),
          ),
          _ToolButton(
            icon: LucideIcons.alignCenter,
            tooltip: 'Center',
            selected: st.hAlign == HAlign.center,
            onPressed: () => c.setAlignment(st.hAlign == HAlign.center ? HAlign.general : HAlign.center),
          ),
          _ToolButton(
            icon: LucideIcons.alignRight,
            tooltip: 'Align right',
            selected: st.hAlign == HAlign.right,
            onPressed: () => c.setAlignment(st.hAlign == HAlign.right ? HAlign.general : HAlign.right),
          ),
          _ToolButton(icon: LucideIcons.wrapText, tooltip: 'Wrap text', selected: st.wrap, onPressed: c.toggleWrap),
          _ToolButton(
            icon: c.selectionHasMerge ? LucideIcons.tableCellsSplit : LucideIcons.tableCellsMerge,
            tooltip: c.selectionHasMerge ? 'Unmerge cells' : 'Merge cells',
            onPressed: c.selectionHasMerge
                ? c.unmergeSelection
                : (c.selection.isSingle ? null : c.mergeSelection),
          ),
          const _Sep(),
          _NumberFormatButton(controller: c, current: st.numFmt),
          _ToolButton(
            icon: LucideIcons.decimalsArrowLeft,
            tooltip: 'Decrease decimals',
            onPressed: () => c.changeDecimals(-1),
          ),
          _ToolButton(
            icon: LucideIcons.decimalsArrowRight,
            tooltip: 'Increase decimals',
            onPressed: () => c.changeDecimals(1),
          ),
        ];
        final row = Row(mainAxisSize: MainAxisSize.min, children: items);
        if (!scrollable) return row;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: row,
        );
      },
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) => const ViewerToolDivider();
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return ViewerAction(
      tooltip: tooltip,
      icon: icon,
      selected: selected,
      size: 36,
      iconSize: 18,
      onPressed: onPressed,
    );
  }
}

class _ColorButton extends StatelessWidget {
  const _ColorButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colors.foreground),
          const SizedBox(height: 2),
          Container(
            width: 16,
            height: 3,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
              border: Border.all(color: colors.border, width: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberFormatButton extends StatelessWidget {
  const _NumberFormatButton({required this.controller, required this.current});

  final SpreadsheetController controller;
  final String current;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = numberFormatLabel(current);
    return ViewerMenuButton<String>(
      tooltip: 'Number format',
      minMenuWidth: 240,
      onSelected: (code) async {
        if (code == '__custom') {
          final custom = await _askCustom(context, current);
          if (custom != null && custom.isNotEmpty) controller.setNumberFormat(custom);
        } else {
          controller.setNumberFormat(code);
        }
      },
      itemBuilder: (context) => [
        for (final p in kNumberFormatPresets)
          viewerMenuItem(
            value: p.$2,
            label: p.$1,
            icon: LucideIcons.hash,
            hint: _sample(p.$2),
            checked: p.$2 == current,
          ),
        viewerMenuDivider(),
        viewerMenuItem(
          value: '__custom',
          icon: LucideIcons.slidersHorizontal,
          label: 'Custom format…',
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.hash, size: 16, color: colors.foreground),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 84),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            const SizedBox(width: 2),
            Icon(LucideIcons.chevronDown, size: 14, color: colors.mutedForeground),
          ],
        ),
      ),
    );
  }

  static String _sample(String code) {
    if (code == 'General') return '1234.5';
    if (code == '@') return 'abc';
    final v = NumberFormats.isDateFormat(code) ? 45322.5625 : 1234.5;
    return NumberFormats.format(code == '0.00%' ? 0.125 : v, code).text;
  }

  Future<String?> _askCustom(BuildContext context, String current) => showTextPrompt(
        context,
        title: 'Custom number format',
        initial: current,
        label: 'Format code',
        helper: 'e.g. #,##0.000  or  dd/mm/yyyy',
        action: 'Apply',
      );
}
