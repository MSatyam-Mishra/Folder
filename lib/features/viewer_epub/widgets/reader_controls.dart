import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../reader/reader_settings.dart';

/// Always-visible slim status line under the page, in the page's colours.
class ReaderFooter extends StatelessWidget {
  const ReaderFooter({
    super.key,
    required this.theme,
    required this.title,
    required this.status,
  });

  /// The resolved page theme (not [ReaderTheme.system]).
  final ReaderTheme theme;
  final String title;
  final String status;

  static const height = 26.0;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: theme.foreground.withValues(alpha: 0.62),
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Container(
      color: theme.background,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 12),
          Text(status, style: style),
        ],
      ),
    );
  }
}

/// Bottom controls shown when the centre of the page is tapped: chapter
/// title, page in chapter, overall progress and a scrubber. Drawn as app
/// chrome (a floating card), readable on every page theme.
class ReaderControlsPanel extends StatelessWidget {
  const ReaderControlsPanel({
    super.key,
    required this.theme,
    required this.title,
    required this.detail,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
    required this.labelFor,
    this.onPrevChapter,
    this.onNextChapter,
  });

  /// The page theme behind the panel.
  final ReaderTheme theme;
  final String title;
  final String detail;

  /// Overall progress 0..1.
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final String Function(double) labelFor;
  final VoidCallback? onPrevChapter;
  final VoidCallback? onNextChapter;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppPanel(
      translucent: true,
      borderRadius: 16,
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                ViewerAction(
                  tooltip: 'Previous chapter',
                  icon: LucideIcons.skipBack,
                  iconSize: 18,
                  onPressed: onPrevChapter,
                ),
                Expanded(
                  child: ViewerSliderTheme(
                    child: Slider(
                      value: value.clamp(0.0, 1.0),
                      label: labelFor(value),
                      divisions: 1000,
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    ),
                  ),
                ),
                ViewerAction(
                  tooltip: 'Next chapter',
                  icon: LucideIcons.skipForward,
                  iconSize: 18,
                  onPressed: onNextChapter,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
