import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/spreadsheet_controller.dart';

/// Address box + formula/value editor for the active cell.
class FormulaBar extends StatelessWidget {
  const FormulaBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onCommit,
    required this.onCancel,
    required this.onGoTo,
    this.dense = false,
  });

  final SpreadsheetController controller;
  final FocusNode focusNode;

  /// Commit and move by (dr, dc).
  final void Function(int dr, int dc) onCommit;
  final VoidCallback onCancel;
  final VoidCallback onGoTo;
  final bool dense;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (alt) {
        final t = controller.editText;
        final sel = t.selection;
        final pos = sel.isValid ? sel.start : t.text.length;
        final end = sel.isValid ? sel.end : pos;
        if (!controller.editing) controller.beginEdit(origin: EditOrigin.formulaBar);
        t.value = TextEditingValue(
          text: t.text.replaceRange(pos, end, '\n'),
          selection: TextSelection.collapsed(offset: pos + 1),
        );
        return KeyEventResult.handled;
      }
      onCommit(shift ? -1 : 1, 0);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.tab) {
      onCommit(0, shift ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      onCancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textTheme = Theme.of(context).textTheme;
    final h = dense ? 40.0 : 44.0;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final editing = controller.editing;
        return SizedBox(
          height: h,
          child: Row(
            children: [
              const SizedBox(width: 6),
              Tooltip(
                message: 'Go to cell',
                child: InkWell(
                  onTap: onGoTo,
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    height: h - 12,
                    constraints: const BoxConstraints(minWidth: 64, maxWidth: 110),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colors.input),
                    ),
                    child: Text(
                      controller.selectionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'fx',
                  style: textTheme.titleSmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: editing ? colors.primary : colors.mutedForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Focus(
                  onKeyEvent: _onKey,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: TextField(
                    controller: controller.editText,
                    focusNode: focusNode,
                    maxLines: 1,
                    style: textTheme.bodyMedium?.copyWith(
                      fontFamily: 'packages/shadcn_ui/GeistMono',
                      fontFamilyFallback: const ['monospace'],
                      fontSize: 14,
                    ),
                    cursorColor: colors.foreground,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      hintText: 'Value or =formula',
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                    onTap: () {
                      if (!controller.editing) {
                        controller.beginEdit(origin: EditOrigin.formulaBar);
                      } else if (controller.editOrigin != EditOrigin.formulaBar) {
                        controller.beginEdit(origin: EditOrigin.formulaBar);
                      }
                    },
                    onChanged: (_) {
                      if (!controller.editing) {
                        final v = controller.editText.value;
                        controller.beginEdit(origin: EditOrigin.formulaBar);
                        controller.editText.value = v;
                      }
                    },
                    onSubmitted: (_) => onCommit(1, 0),
                  ),
                ),
              ),
              if (editing) ...[
                ViewerAction(
                  tooltip: 'Cancel',
                  icon: LucideIcons.x,
                  size: 36,
                  iconSize: 18,
                  color: colors.destructive,
                  onPressed: onCancel,
                ),
                ViewerAction(
                  tooltip: 'Enter',
                  icon: LucideIcons.check,
                  size: 36,
                  iconSize: 18,
                  color: colors.primary,
                  onPressed: () => onCommit(0, 0),
                ),
                const SizedBox(width: 4),
              ],
            ],
          ),
        );
      },
    );
  }
}
