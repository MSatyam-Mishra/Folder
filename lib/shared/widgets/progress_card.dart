import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';

/// Floating card showing a running file operation (copy, move…).
///
/// Returns a [Positioned], so place it directly in a [Stack]: it sits at the
/// bottom of the stack, full width on phones and bottom-right on wide
/// screens. The cancel / hide buttons only appear when their callbacks are
/// given. Several tasks at once: ProgressDock.
class ProgressCard extends StatelessWidget {
  final String title;
  final String message;
  final double progress;
  final VoidCallback? onCancel;
  final VoidCallback? onHide;

  const ProgressCard({
    super.key,
    required this.title,
    required this.message,
    required this.progress,
    this.onCancel,
    this.onHide,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom + 16;
    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom,
      child: Align(
        alignment: Alignment.bottomRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ProgressTile(
            title: title,
            message: message,
            progress: progress,
            onCancel: onCancel,
            onHide: onHide,
          ),
        ),
      ),
    );
  }
}

/// The panel of a running task: title, percentage, message and a progress
/// bar. [progress] is 0–1, or NaN when it can't be measured.
class ProgressTile extends StatelessWidget {
  const ProgressTile({
    super.key,
    required this.title,
    required this.message,
    required this.progress,
    this.onCancel,
    this.onHide,
    this.onTap,
  });

  final String title;
  final String message;
  final double progress;
  final VoidCallback? onCancel;
  final VoidCallback? onHide;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final value = progress.isFinite ? progress.clamp(0.0, 1.0) : null;
    final percent = value == null ? null : '${(value * 100).round()}%';

    final panel = AppPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
              ),
              if (percent != null)
                Text(
                  percent,
                  style: text.labelMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: value, minHeight: 6),
          if (onCancel != null || onHide != null) ...[
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onHide != null)
                  TextButton(
                    onPressed: onHide,
                    child: const Text('Hide'),
                  ),
                if (onCancel != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return panel;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: onTap, child: panel),
    );
  }
}
