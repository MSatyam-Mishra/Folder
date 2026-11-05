import 'dart:async';

import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// shadcn-style dropdown menus (compact rows, muted icons, check marks)
/// anchored under the widget that opened them.
abstract final class ExplorerMenu {
  /// Opens [items] under the widget owning [anchorContext].
  static Future<T?> show<T>(
    BuildContext anchorContext, {
    required List<PopupMenuEntry<T>> items,
    double minWidth = 200,
  }) {
    final anchor = anchorContext.findRenderObject()! as RenderBox;
    final overlay = Navigator.of(anchorContext).overlay!.context
        .findRenderObject()! as RenderBox;
    final gap = Offset(0, anchor.size.height + 4);
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        anchor.localToGlobal(gap, ancestor: overlay),
        anchor.localToGlobal(
          anchor.size.bottomRight(Offset.zero) + gap,
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    return _open<T>(anchorContext, position, items, minWidth);
  }

  /// Opens [items]; with the window effect on, on a blurred, see-through
  /// surface like the window's.
  static Future<T?> _open<T>(
    BuildContext context,
    RelativeRect position,
    List<PopupMenuEntry<T>> items,
    double minWidth,
  ) {
    final constraints = BoxConstraints(minWidth: minWidth, maxWidth: 320);
    if (!AppGlass.isOn(context)) {
      return showMenu<T>(
        context: context,
        position: position,
        items: items,
        constraints: constraints,
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
      );
    }
    final colors = context.colors;
    return showMenu<T>(
      context: context,
      position: position,
      items: [_GlassMenuBody<T>(items: items)],
      constraints: constraints,
      menuPadding: EdgeInsets.zero,
      color: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.border),
      ),
      // At once: a blur can't fade in with the rest of the menu.
      popUpAnimationStyle: AnimationStyle.noAnimation,
    );
  }

  /// Where a submenu of the menu row [row] opens in a window of [window]: on
  /// its right if it fits, else on its left, and never over the menu. A popup
  /// grows from the side it has less room on, so that's what the two sides say.
  @visibleForTesting
  static RelativeRect besideMenu(Rect row, Size window, {double width = 320}) {
    final top = row.top - 4;
    final bottom = window.height - row.bottom;
    if (window.width - row.right >= width) {
      final left = row.right - 4;
      return RelativeRect.fromLTRB(left, top, left + 1, bottom);
    }
    final right = window.width - row.left - 4;
    return RelativeRect.fromLTRB(right + 1, top, right, bottom);
  }

  /// Opens [items] at [globalPosition], e.g. where a right-click happened.
  static Future<T?> showAt<T>(
    BuildContext context,
    Offset globalPosition, {
    required List<PopupMenuEntry<T>> items,
    double minWidth = 220,
  }) {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(globalPosition);
    return _open<T>(
      context,
      RelativeRect.fromRect(
        point & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items,
      minWidth,
    );
  }

  /// A row with an optional leading icon, and a trailing check mark or
  /// keyboard [shortcut] hint ("Ctrl+C").
  static PopupMenuItem<T> item<T>(
    BuildContext context, {
    required T value,
    required String label,
    IconData? icon,
    String? shortcut,
    bool checked = false,
    bool destructive = false,
    bool enabled = true,
  }) {
    final colors = context.colors;
    final fg = destructive ? colors.destructive : colors.popoverForeground;
    return PopupMenuItem<T>(
      value: value,
      enabled: enabled,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 16,
              color: destructive ? colors.destructive : context.look.iconColor(icon, colors.mutedForeground),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: enabled ? fg : colors.mutedForeground),
            ),
          ),
          if (checked) ...[
            const SizedBox(width: 12),
            Icon(LucideIcons.check, size: 16, color: colors.foreground),
          ],
          if (shortcut != null) ...[
            const SizedBox(width: 16),
            Text(
              shortcut,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.mutedForeground),
            ),
          ],
        ],
      ),
    );
  }

  /// A row that opens [items] beside it (on hover with a mouse, or when
  /// chosen); what's picked there closes the whole menu with its value.
  static PopupMenuEntry<T> submenu<T>(
    BuildContext context, {
    required String label,
    required List<PopupMenuEntry<T>> items,
    IconData? icon,
  }) =>
      _Submenu<T>(label: label, icon: icon, items: items);

  /// Muted heading inside a menu ("Sort by").
  static PopupMenuItem<T> label<T>(BuildContext context, String text) {
    return PopupMenuItem<T>(
      enabled: false,
      height: 28,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Text(text, style: Theme.of(context).textTheme.labelMedium),
    );
  }

  static PopupMenuEntry<T> divider<T>() => const PopupMenuDivider(height: 9);
}

/// All of a menu's rows on one blurred surface: the menu itself has no room
/// for a blur behind its rows.
class _GlassMenuBody<T> extends PopupMenuEntry<T> {
  const _GlassMenuBody({required this.items});

  final List<PopupMenuEntry<T>> items;

  @override
  double get height => items.fold(8, (sum, item) => sum + item.height);

  @override
  bool represents(T? value) => items.any((item) => item.represents(value));

  @override
  State<_GlassMenuBody<T>> createState() => _GlassMenuBodyState<T>();
}

class _GlassMenuBodyState<T> extends State<_GlassMenuBody<T>> {
  @override
  Widget build(BuildContext context) => GlassSurface(
        color: context.colors.popover,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: widget.items,
          ),
        ),
      );
}

class _Submenu<T> extends PopupMenuEntry<T> {
  const _Submenu({required this.label, required this.items, this.icon});

  final String label;
  final IconData? icon;
  final List<PopupMenuEntry<T>> items;

  @override
  double get height => 36;

  @override
  bool represents(T? value) => false;

  @override
  State<_Submenu<T>> createState() => _SubmenuState<T>();
}

class _SubmenuState<T> extends State<_Submenu<T>> {
  Timer? _hover;
  bool _open = false;

  @override
  void dispose() {
    _hover?.cancel();
    super.dispose();
  }

  Future<void> _show() async {
    _hover?.cancel();
    if (_open || !mounted) return;
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final row = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    setState(() => _open = true);
    final value = await ExplorerMenu._open<T>(
      context,
      ExplorerMenu.besideMenu(row, overlay.size),
      widget.items,
      200,
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (value != null) Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MouseRegion(
      // When the mouse moves onto it, not when the menu opens under a mouse
      // that's still: then it would open by itself, without being asked.
      onHover: (_) {
        if (_open || (_hover?.isActive ?? false)) return;
        _hover = Timer(const Duration(milliseconds: 250), _show);
      },
      onExit: (_) => _hover?.cancel(),
      child: InkWell(
        onTap: _show,
        child: Container(
          height: widget.height,
          color: _open ? colors.accent : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: context.look.iconColor(widget.icon, colors.mutedForeground)),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: colors.popoverForeground),
                ),
              ),
              const SizedBox(width: 16),
              Icon(LucideIcons.chevronRight, size: 16, color: colors.mutedForeground),
            ],
          ),
        ),
      ),
    );
  }
}
