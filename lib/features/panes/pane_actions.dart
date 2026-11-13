import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/pane_menu.dart';
import 'package:folders/features/panes/pane_settings.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What a browser does with its panes: the keys, the header's switches and
/// the menus' "Copy to other pane" and "Move to other pane".
abstract final class PaneActions {
  static String get dualShortcut => Platform.isMacOS ? '⌘\\' : 'Ctrl+\\';
  static String get previewShortcut => Platform.isMacOS ? '⇧⌘P' : 'Alt+P';
  static String get swapShortcut => Platform.isMacOS ? '⌘U' : 'Ctrl+U';
  static String get copyShortcut => Platform.isMacOS ? '⇧F5' : 'Shift+F5';
  static String get moveShortcut => Platform.isMacOS ? '⇧F6' : 'Shift+F6';

  /// Whether the header of the pane [context] is in has room for its wide
  /// layout (the breadcrumb, New folder, with Back, Forward and Up before
  /// them): from 700 px with the room to itself, as in a small window beside
  /// the sidebar; beside another pane or the preview pane, from 760 px.
  static bool roomyHeader(BuildContext context) {
    final slot = PaneSlot.of(context);
    return slot == null || slot.width >= (slot.shared ? 760 : 700);
  }

  /// The preview pane is for computers and tablets, not phones.
  static bool previewAllowed(BuildContext context) =>
      Desktop.isDesktop || MediaQuery.sizeOf(context).shortestSide >= 600;

  /// The header's switches for the pane [context] is in. Their buttons are
  /// in the rightmost pane's header only; every pane's View menu has them.
  static List<PaneToggle> toggles(BuildContext context) {
    final panes = DualPanes.of(context);
    if (panes == null) return const [];
    final slot = PaneSlot.of(context);
    final buttons = slot == null || slot.rightmost;
    final settings = PaneSettings.instance;
    return [
      if (panes.roomForTwo)
        PaneToggle(
          label: 'Dual pane',
          icon: LucideIcons.columns2,
          on: panes.showing,
          shortcut: dualShortcut,
          button: buttons,
          onPressed: panes.toggle,
        ),
      if (panes.showing)
        PaneToggle(
          label: 'Swap panes',
          icon: LucideIcons.arrowLeftRight,
          shortcut: swapShortcut,
          button: false,
          onPressed: panes.swap,
        ),
      if (panes.roomForPreview && previewAllowed(context))
        PaneToggle(
          label: 'Preview pane',
          icon: LucideIcons.panelRight,
          on: settings.preview,
          shortcut: previewShortcut,
          button: buttons,
          onPressed: settings.togglePreview,
        ),
    ];
  }

  /// The browser's keys for its panes, asked before its own: null when
  /// [event] isn't one of them. Alt+P (⇧⌘P) shows the preview pane and
  /// Ctrl+\ (⌘\) two panes; with two, Tab goes to the other pane, Shift+F5
  /// copies there and Shift+F6 moves there, Ctrl+U (⌘U) swaps them.
  static KeyEventResult? onKey(BuildContext context, KeyEvent event) {
    final panes = DualPanes.read(context);
    if (panes == null) return null;
    final pane = DualPanes.paneOf(context);
    // The first pane's keys sit above the second pane: what the second one
    // left isn't for the first.
    if (pane == 0 && panes.focusInSecond) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    final command = Platform.isMacOS ? keys.isMetaPressed : keys.isControlPressed;
    final plain = !keys.isControlPressed && !keys.isMetaPressed && !keys.isAltPressed;

    final VoidCallback? action;
    final previewKey = Platform.isMacOS
        ? keys.isMetaPressed && keys.isShiftPressed && !keys.isAltPressed
        : keys.isAltPressed && !keys.isControlPressed && !keys.isMetaPressed;
    if (key == LogicalKeyboardKey.keyP && previewKey) {
      // Off is always possible; on where it fits.
      final settings = PaneSettings.instance;
      action = settings.preview || (panes.roomForPreview && previewAllowed(context)) ? settings.togglePreview : () {};
    } else if (command && !keys.isShiftPressed && key == LogicalKeyboardKey.backslash) {
      action = panes.enabled || panes.roomForTwo ? panes.toggle : () {};
    } else if (!panes.showing) {
      action = null;
    } else if (key == LogicalKeyboardKey.tab && plain) {
      action = () => panes.activate(1 - pane);
    } else if (key == LogicalKeyboardKey.f5 && keys.isShiftPressed && plain) {
      action = () => transfer(context, move: false);
    } else if (key == LogicalKeyboardKey.f6 && keys.isShiftPressed && plain) {
      action = () => transfer(context, move: true);
    } else if (key == LogicalKeyboardKey.keyU && command && !keys.isShiftPressed && !keys.isAltPressed) {
      action = panes.swap;
    } else {
      action = null;
    }
    if (action == null) return null;
    if (event is KeyDownEvent) action();
    return KeyEventResult.handled;
  }

  /// "Copy to other pane" and "Move to other pane" for [items] in the pane
  /// [context] is in, while two panes show and the other one is a folder.
  static List<PaneMenuAction> menuActions(BuildContext context, List<FileSystemEntity> items) {
    final panes = DualPanes.read(context);
    if (panes == null || !panes.showing || items.isEmpty) return const [];
    final target = pathOfBrowser(panes.blocOf(1 - DualPanes.paneOf(context)));
    if (target == null || ExplorerPaths.isVirtual(target)) return const [];
    return [
      PaneMenuAction(
        label: 'Copy to other pane',
        icon: LucideIcons.copyPlus,
        shortcut: copyShortcut,
        run: () => transfer(context, move: false, items: items),
      ),
      PaneMenuAction(
        label: 'Move to other pane',
        icon: LucideIcons.folderInput,
        shortcut: moveShortcut,
        run: () => transfer(context, move: true, items: items),
      ),
    ];
  }

  /// [menuActions] as menu rows; their value is the [PaneMenuAction].
  static List<PopupMenuEntry<Object>> menuEntries(BuildContext context, List<FileSystemEntity> items) => [
        for (final action in menuActions(context, items))
          ExplorerMenu.item<Object>(
            context,
            value: action,
            label: action.label,
            icon: action.icon,
            shortcut: action.shortcut,
          ),
      ];

  /// Whether the selection bar offers copying and moving to the other pane.
  static bool canTransfer(BuildContext context) {
    final panes = DualPanes.of(context);
    if (panes == null || !panes.showing) return false;
    final target = pathOfBrowser(panes.blocOf(1 - DualPanes.paneOf(context)));
    return target != null && !ExplorerPaths.isVirtual(target);
  }

  /// Copies (or with [move], moves) [items], else what's selected in the
  /// pane [context] is in, into the other pane's folder.
  static void transfer(BuildContext context, {required bool move, List<FileSystemEntity>? items}) {
    final panes = DualPanes.read(context);
    if (panes == null || !panes.showing) return;
    final pane = DualPanes.paneOf(context);
    final from = panes.blocOf(pane)?.state;
    final target = pathOfBrowser(panes.blocOf(1 - pane));
    final chosen = items ??
        (from is FileExplorerLoaded
            ? [for (final e in from.displayEntities) if (from.selectedItems.contains(e)) e]
            : const <FileSystemEntity>[]);
    void say(String message) => ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    if (chosen.isEmpty) return say(move ? 'Select what to move first' : 'Select what to copy first');
    if (target == null || ExplorerPaths.isVirtual(target)) {
      return say('Open a folder in the other pane first');
    }
    if (from is FileExplorerLoaded && ExplorerPaths.isWindowsRoots(from.path)) {
      return say("Drives can't be copied or moved");
    }
    final sources = [for (final e in chosen) e.path];
    if (sources.every((s) => p.equals(p.dirname(s), target))) {
      return say('Both panes show this folder');
    }
    if (sources.any((s) => p.equals(s, target) || p.isWithin(s, target))) {
      return say("A folder can't go inside itself");
    }
    context.read<ClipboardBloc>().add(TransferFiles(sources, target, move: move));
  }
}

/// The header's buttons for [toggles]: each one, or on a narrow pane
/// ([compact]) one button with them in a menu.
class PaneToggleButtons extends StatelessWidget {
  const PaneToggleButtons({super.key, required this.toggles, this.compact = false});

  final List<PaneToggle> toggles;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final shown = [for (final t in toggles) if (t.button && t.on != null) t];
    if (shown.isEmpty) return const SizedBox.shrink();
    // The wide header already has its New folder button: on a narrow page
    // (a wide sidebar in a small window) one button, or none.
    final width = PaneSlot.of(context)?.width ?? double.infinity;
    if (!compact && width < 500) return const SizedBox.shrink();
    final merged = compact || width < 760;
    if (!merged || shown.length == 1) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final t in shown) _ToggleButton(toggle: t)],
      );
    }
    final anyOn = shown.any((t) => t.on!);
    return Builder(
      builder: (anchor) => _ToggleButton(
        toggle: PaneToggle(
          label: 'Panes',
          icon: LucideIcons.columns2,
          on: anyOn,
          onPressed: () async {
            final picked = await ExplorerMenu.show<PaneToggle>(
              anchor,
              minWidth: 220,
              items: [
                ExplorerMenu.label(anchor, 'Panes'),
                for (final t in toggles)
                  ExplorerMenu.item(
                    anchor,
                    value: t,
                    label: t.label,
                    icon: t.icon,
                    checked: t.on ?? false,
                    shortcut: t.shortcut,
                  ),
              ],
            );
            picked?.onPressed();
          },
        ),
      ),
    );
  }
}

/// A 40 px header button that stays tinted while its switch is on.
class _ToggleButton extends StatelessWidget {
  const _ToggleButton({required this.toggle});

  final PaneToggle toggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final on = toggle.on ?? false;
    final shortcut = toggle.shortcut;
    return IconButton(
      onPressed: toggle.onPressed,
      tooltip: shortcut == null ? toggle.label : '${toggle.label} ($shortcut)',
      isSelected: on,
      icon: Icon(toggle.icon, color: on ? colors.primary : context.look.tint(toggle.icon)),
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: WidgetStatePropertyAll(on ? colors.primary.withValues(alpha: 0.12) : null),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
    );
  }
}
