import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/bloc/folder_history.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Back, Forward and Up for a browser (a tab), by its history.
extension FolderNavigation on FileExplorerBloc {
  /// Goes [steps] folders back (negative) or forward; false if there's
  /// nothing that far.
  bool goInHistory(int steps) {
    final target = history.go(steps);
    if (target == null) return false;
    add(LoadDirectory(target, step: HistoryStep.keep));
    return true;
  }

  bool goBack() => goInHistory(-1);
  bool goForward() => goInHistory(1);

  /// Opens the folder above the one shown; with [replace] it takes that
  /// one's place in the history (Back on a phone, past the history's start).
  bool goUp({bool replace = false}) {
    final path = history.current;
    final parent = path == null ? null : ExplorerPaths.parentOf(path);
    if (parent == null) return false;
    add(LoadDirectory(parent, step: replace ? HistoryStep.replace : HistoryStep.record));
    return true;
  }

  /// The mouse's back and forward buttons: true if [buttons] had one.
  bool sideButton(int buttons) {
    if (buttons & kBackMouseButton != 0) {
      goBack();
      return true;
    }
    if (buttons & kForwardMouseButton != 0) {
      goForward();
      return true;
    }
    return false;
  }
}

/// Back, Forward and Up in the header on computers. A right-click or a long
/// press on Back or Forward lists the folders that way.
class HistoryButtons extends StatelessWidget {
  const HistoryButtons({super.key, required this.history, required this.onGo, this.onUp});

  final FolderHistory history;

  /// Goes that many folders back (negative) or forward.
  final ValueChanged<int> onGo;

  /// Opens the folder above; null at the top.
  final VoidCallback? onUp;

  static String get backKeys => Platform.isMacOS ? '⌘[' : 'Alt+Left';
  static String get forwardKeys => Platform.isMacOS ? '⌘]' : 'Alt+Right';
  static String get upKeys => Platform.isMacOS ? '⌘↑' : 'Alt+Up';

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HistoryButton(
          icon: LucideIcons.arrowLeft,
          tooltip: 'Back ($backKeys)',
          entries: history.backEntries,
          back: true,
          onGo: onGo,
        ),
        _HistoryButton(
          icon: LucideIcons.arrowRight,
          tooltip: 'Forward ($forwardKeys)',
          entries: history.forwardEntries,
          back: false,
          onGo: onGo,
        ),
        AppIconButton(
          icon: const Icon(LucideIcons.arrowUp),
          tooltip: 'Up ($upKeys)',
          onPressed: onUp,
        ),
      ],
    );
  }
}

class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    required this.icon,
    required this.tooltip,
    required this.entries,
    required this.back,
    required this.onGo,
  });

  final IconData icon;
  final String tooltip;

  /// The folders that way, nearest first.
  final List<String> entries;
  final bool back;
  final ValueChanged<int> onGo;

  /// The most folders the list shows.
  static const _listed = 12;

  Future<void> _list(BuildContext context, Offset? at) async {
    if (entries.isEmpty) return;
    final items = <PopupMenuEntry<int>>[
      ExplorerMenu.label(context, back ? 'Go back to' : 'Go forward to'),
      for (var i = 0; i < entries.length && i < _listed; i++)
        ExplorerMenu.item(
          context,
          value: back ? -(i + 1) : i + 1,
          label: ExplorerPaths.titleForPath(entries[i]),
          icon: ExplorerPaths.isVirtual(entries[i]) ? LucideIcons.layoutGrid : LucideIcons.folder,
        ),
    ];
    final steps = at == null
        ? await ExplorerMenu.show<int>(context, items: items)
        : await ExplorerMenu.showAt<int>(context, at, items: items);
    if (steps != null) onGo(steps);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = entries.isNotEmpty;
    return Builder(
      builder: (anchor) => GestureDetector(
        onSecondaryTapUp: enabled ? (details) => _list(anchor, details.globalPosition) : null,
        onLongPress: enabled ? () => _list(anchor, null) : null,
        child: AppIconButton(
          icon: Icon(icon),
          tooltip: tooltip,
          onPressed: enabled ? () => onGo(back ? -1 : 1) : null,
        ),
      ),
    );
  }
}
