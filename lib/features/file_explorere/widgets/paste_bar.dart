import 'package:folders/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Floating bar shown while files are on the clipboard: what they are,
/// whether they will be copied or moved, Cancel and Paste.
class PasteBar extends StatelessWidget {
  const PasteBar({
    super.key,
    required this.clipboard,
    required this.onPaste,
    required this.onCancel,
  });

  final ClipboardReadyToPaste clipboard;
  final VoidCallback? onPaste;
  final VoidCallback onCancel;

  /// Space the bar covers at the bottom of the list (for list padding).
  static const double reservedHeight = 88;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final entities = clipboard.entities;
    final move = clipboard.operation == ClipboardOperation.cut;
    final name = entities.length == 1
        ? p.basename(entities.single.path)
        : '${entities.length} items';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: AppPanel(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            if (entities.length == 1)
              EntityIcon(entity: entities.single, size: 32)
            else
              SizedBox.square(
                dimension: 32,
                child: Icon(LucideIcons.files, size: 24, color: colors.primary),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    move ? 'Ready to move here' : 'Ready to copy here',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AppIconButton(
              icon: Icon(LucideIcons.x, color: colors.mutedForeground),
              tooltip: 'Cancel',
              onPressed: onCancel,
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: onPaste,
              icon: const Icon(LucideIcons.clipboardPaste, size: 16),
              label: const Text('Paste'),
            ),
          ],
        ),
      ),
    );
  }
}
