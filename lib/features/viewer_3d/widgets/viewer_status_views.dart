import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

/// Loading card shown over the 3D canvas while a model is read and parsed.
///
/// An opaque card instead of a blur because backdrop filters can't sample
/// platform views (the WebView) on Android.
class ViewerProgressCard extends StatelessWidget {
  const ViewerProgressCard({super.key, required this.label, this.progress});

  final String label;

  /// 0..1, or null for an indeterminate spinner.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final percent = progress == null ? null : (progress! * 100).clamp(0, 100).round();
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
      child: AppPanel(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const IconBox(LucideIcons.box, size: 44),
            const SizedBox(height: 14),
            Text(
              '$label…',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: LinearProgressIndicator(value: progress)),
                if (percent != null) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '$percent%',
                      textAlign: TextAlign.right,
                      style: text.labelMedium?.copyWith(
                        color: colors.foreground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Friendly error state with "Open with another app" and optional retry.
class ViewerErrorView extends StatelessWidget {
  const ViewerErrorView({
    super.key,
    required this.message,
    required this.onOpenWith,
    this.detail,
    this.onRetry,
  });

  final String message;
  final String? detail;
  final VoidCallback onOpenWith;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: AppPanel(
          child: ViewerMessage(
            shrinkWrap: true,
            icon: LucideIcons.box,
            tone: Tone.destructive,
            title: "Can't display this model",
            message: message,
            details: detail != null && detail!.trim().isNotEmpty && detail != message
                ? detail
                : null,
            actions: [
              if (onRetry != null)
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: const Text('Retry'),
                ),
              FilledButton.icon(
                onPressed: onOpenWith,
                icon: const Icon(LucideIcons.externalLink, size: 16),
                label: const Text('Open with another app'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
