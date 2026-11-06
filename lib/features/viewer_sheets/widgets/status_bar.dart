import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../controller/spreadsheet_controller.dart';
import '../model/number_format.dart';

String formatStat(double v) {
  final a = v.abs();
  if (a != 0 && (a >= 1e12 || a < 1e-4)) return NumberFormats.formatGeneral(v);
  final decimals = a >= 1000 ? 2 : 4;
  var s = NumberFormats.format(v, '#,##0.${'#' * decimals}').text;
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// Selection statistics (count / sum / average) and zoom controls.
class SheetStatusBar extends StatelessWidget {
  const SheetStatusBar({super.key, required this.controller});

  final SpreadsheetController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stats = controller.selectionStats();
        final parts = <String>[];
        if (stats.cells > 1 && stats.count > 0) {
          if (stats.numericCount > 0) {
            parts.add('Sum ${formatStat(stats.sum)}');
            parts.add('Average ${formatStat(stats.average!)}');
            if (stats.numericCount > 1) {
              parts.add('Min ${formatStat(stats.min!)}');
              parts.add('Max ${formatStat(stats.max!)}');
            }
          }
          parts.add('Count ${stats.count}');
        }
        return SizedBox(
          height: 32,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: SelectableText(
                    parts.isEmpty ? (controller.dirty ? 'Edited' : 'Ready') : parts.join('   ·   '),
                    style: style,
                    maxLines: 1,
                  ),
                ),
              ),
              ViewerAction(
                tooltip: 'Zoom out',
                icon: LucideIcons.minus,
                size: 28,
                iconSize: 14,
                onPressed: controller.zoom > 0.41 ? () => controller.setZoom(controller.zoom - 0.1) : null,
              ),
              Tooltip(
                message: 'Reset zoom',
                child: InkWell(
                  onTap: () => controller.setZoom(1),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Text('${(controller.zoom * 100).round()}%', style: style),
                  ),
                ),
              ),
              ViewerAction(
                tooltip: 'Zoom in',
                icon: LucideIcons.plus,
                size: 28,
                iconSize: 14,
                onPressed: controller.zoom < 2.99 ? () => controller.setZoom(controller.zoom + 0.1) : null,
              ),
              const SizedBox(width: 6),
            ],
          ),
        );
      },
    );
  }
}
