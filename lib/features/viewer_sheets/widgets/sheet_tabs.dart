import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/workbook.dart';

/// Scrollable sheet tabs at the bottom of the screen.
class SheetTabs extends StatefulWidget {
  const SheetTabs({
    super.key,
    required this.controller,
    required this.onTabMenu,
    this.onAdd,
  });

  final SpreadsheetController controller;

  /// Long-press / right-click on a tab.
  final void Function(int index, Offset globalPosition) onTabMenu;

  /// Null hides the add button (formats with a single sheet).
  final VoidCallback? onAdd;

  @override
  State<SheetTabs> createState() => _SheetTabsState();
}

class _SheetTabsState extends State<SheetTabs> {
  final _scroll = ScrollController();
  final _activeKey = GlobalKey();
  int _lastActive = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _ensureActiveVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _activeKey.currentContext;
      if (ctx != null && mounted) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200), alignment: 0.5);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final wb = widget.controller.workbook;
        final active = wb.activeSheet;
        if (active != _lastActive) {
          _lastActive = active;
          _ensureActiveVisible();
        }
        return SizedBox(
          height: 44,
          child: Row(
            children: [
              if (widget.onAdd != null) ...[
                const SizedBox(width: 4),
                ViewerAction(
                  tooltip: 'Add sheet',
                  icon: LucideIcons.plus,
                  size: 36,
                  iconSize: 18,
                  onPressed: widget.onAdd,
                ),
              ],
              Expanded(
                child: ListView.separated(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  itemCount: wb.sheets.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 2),
                  itemBuilder: (context, i) {
                    final s = wb.sheets[i];
                    final isActive = i == active;
                    final hidden = s.visibility != SheetVisibility.visible;
                    final fg = isActive ? colors.accentForeground : colors.mutedForeground;
                    return GestureDetector(
                      key: isActive ? _activeKey : null,
                      onLongPressStart: (d) => widget.onTabMenu(i, d.globalPosition),
                      onSecondaryTapUp: (d) => widget.onTabMenu(i, d.globalPosition),
                      child: Material(
                        color: isActive ? colors.accent : Colors.transparent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => widget.controller.activateSheet(i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hidden) ...[
                                  Icon(LucideIcons.eyeOff, size: 14, color: fg),
                                  const SizedBox(width: 6),
                                ],
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 160),
                                  child: Text(
                                    s.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.labelLarge?.copyWith(
                                      color: fg,
                                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                                      fontStyle: hidden ? FontStyle.italic : FontStyle.normal,
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
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
