import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/trash/trash_actions.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Above what's in the Trash: how long things stay, Empty, and the Trash's
/// settings.
class TrashBar extends StatefulWidget {
  const TrashBar({super.key, required this.count});

  static const double height = 52;

  /// How many items are in it.
  final int count;

  @override
  State<TrashBar> createState() => _TrashBarState();
}

class _TrashBarState extends State<TrashBar> {
  int? _keepDays;
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final keep = await TrashSettings.keepDays();
    final enabled = await TrashSettings.enabled();
    if (mounted) {
      setState(() {
        _keepDays = keep;
        _enabled = enabled;
      });
    }
  }

  String get _note {
    if (_enabled == false) return 'Delete is set to delete for good';
    if (!Trash.instance.emptiesItself) return 'Deleted items stay here until you empty it';
    final days = _keepDays ?? 30;
    return days == 0 ? 'Deleted items stay here until you empty it' : 'Deleted for good after $days days';
  }

  Future<void> _settings(BuildContext anchor) async {
    final trash = Trash.instance;
    final keep = _keepDays ?? 30;
    final picked = await ExplorerMenu.show<String>(
      anchor,
      minWidth: 240,
      items: [
        ExplorerMenu.item(anchor,
            value: 'enabled',
            label: 'Delete moves to ${TrashActions.name}',
            icon: LucideIcons.trash2,
            checked: _enabled ?? true),
        if (trash.emptiesItself) ...[
          ExplorerMenu.divider(),
          ExplorerMenu.label(anchor, 'Keep deleted items'),
          ExplorerMenu.item(anchor, value: 'keep30', label: 'For 30 days', icon: LucideIcons.calendarClock, checked: keep == 30),
          ExplorerMenu.item(anchor, value: 'keep0', label: 'Until I empty it', icon: LucideIcons.infinity, checked: keep == 0),
        ],
      ],
    );
    switch (picked) {
      case 'enabled':
        await TrashSettings.setEnabled(!(_enabled ?? true));
      case 'keep30':
        await TrashSettings.setKeepDays(30);
      case 'keep0':
        await TrashSettings.setKeepDays(0);
      default:
        return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final open = Trash.instance.openInSystem;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: colors.background.withValues(alpha: colors.background.a * 0.82),
          child: SizedBox(
            height: TrashBar.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(LucideIcons.info, size: 16, color: colors.mutedForeground),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_note, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ),
                  if (open != null)
                    AppIconButton(
                      icon: const Icon(LucideIcons.squareArrowOutUpRight, size: 18),
                      tooltip: Platform.isMacOS ? 'Open in Finder' : 'Open in File Explorer',
                      onPressed: open,
                    ),
                  Builder(
                    builder: (anchor) => AppIconButton(
                      icon: const Icon(LucideIcons.settings2, size: 18),
                      tooltip: '${Trash.instance.label} settings',
                      onPressed: () => _settings(anchor),
                    ),
                  ),
                  const SizedBox(width: 4),
                  OutlinedButton.icon(
                    onPressed: widget.count == 0 ? null : () => TrashActions.empty(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: colors.destructive,
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    icon: const Icon(LucideIcons.trash2, size: 16),
                    label: const Text('Empty'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header while items in the Trash are selected.
class TrashSelectionHeader extends StatelessWidget {
  const TrashSelectionHeader({
    super.key,
    required this.count,
    required this.total,
    required this.onClose,
    required this.onRestore,
    required this.onDelete,
    required this.onSelectAll,
    this.wide = false,
  });

  final int count;
  final int total;
  final bool wide;
  final VoidCallback onClose;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final any = count > 0;
    return Theme(
      data: Theme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: IconTheme(
        data: IconThemeData(color: colors.foreground, size: 20),
        child: Padding(
          padding: EdgeInsets.only(left: wide ? 12 : 8, right: wide ? 12 : 8),
          child: Row(
            children: [
              AppIconButton(icon: const Icon(LucideIcons.x), tooltip: 'Cancel selection', onPressed: onClose),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  wide ? '$count of $total selected' : '$count selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppForeground.title(context),
                ),
              ),
              if (count < total)
                AppIconButton(icon: const Icon(LucideIcons.listChecks), tooltip: 'Select all', onPressed: onSelectAll),
              AppIconButton(icon: const Icon(LucideIcons.undo2), tooltip: 'Restore', onPressed: any ? onRestore : null),
              AppIconButton(
                icon: const Icon(LucideIcons.trash2),
                tooltip: 'Delete for good',
                color: any ? colors.destructive : null,
                onPressed: any ? onDelete : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
