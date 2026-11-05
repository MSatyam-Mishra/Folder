import 'dart:math' as math;

import 'package:folder/features/viewer_3d/models/viewer_3d_models.dart';
import 'package:folder/features/viewer_3d/services/three_d_viewer_controller.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Model details and scene controls.
///
/// Used as the docked side pane on wide screens and inside a bottom sheet on
/// phones. Rebuilds itself from [controller].
class ModelInfoPanel extends StatelessWidget {
  const ModelInfoPanel({
    super.key,
    required this.controller,
    required this.fileName,
    required this.fileSize,
    required this.onScreenshot,
    this.scrollable = true,
    this.onClose,
  });

  final ThreeDViewerController controller;
  final String fileName;
  final int? fileSize;
  final VoidCallback onScreenshot;

  /// False when the parent already scrolls (bottom sheet).
  final bool scrollable;

  /// Shows a close button in the header (docked pane).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final children = _buildChildren(context);
        if (!scrollable) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 24),
          children: children,
        );
      },
    );
  }

  List<Widget> _buildChildren(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final stats = controller.stats;
    final ready = controller.isReady;

    final subtitle = [
      if (stats != null && stats.format.isNotEmpty) stats.format,
      if (fileSize != null) filesize(fileSize),
    ].join(' · ');

    return [
      PanelHeader(
        title: fileName,
        subtitle: subtitle,
        onClose: onClose,
        closeTooltip: 'Hide details',
      ),
      if (!ready)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              if (controller.phase != ViewerPhase.error) ...[
                const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  controller.phase == ViewerPhase.error
                      ? (controller.errorMessage ??
                          'The model could not be displayed.')
                      : 'Loading model…',
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        ),
      if (controller.warnings.isNotEmpty)
        _WarningsBox(warnings: controller.warnings),
      if (stats != null) ...[
        const _SectionTitle('Model'),
        _StatsTable(stats: stats),
      ],
      if (ready && controller.clips.isNotEmpty) ...[
        const _SectionTitle('Animations'),
        _AnimationList(controller: controller),
      ],
      if (ready) ...[
        const _SectionTitle('View'),
        _ToggleRow(
          icon: LucideIcons.rotate3d,
          label: 'Auto-rotate',
          value: controller.autoRotate,
          onChanged: controller.setAutoRotate,
        ),
        if (controller.hasMeshes)
          _ToggleRow(
            icon: LucideIcons.box,
            label: 'Wireframe',
            value: controller.wireframe,
            onChanged: controller.setWireframe,
          ),
        _ToggleRow(
          icon: LucideIcons.grid3x3,
          label: 'Ground grid',
          value: controller.grid,
          onChanged: controller.setGrid,
        ),
        _ToggleRow(
          icon: LucideIcons.move3d,
          label: 'Axes',
          value: controller.axes,
          onChanged: controller.setAxes,
        ),
        _ToggleRow(
          icon: LucideIcons.axis3d,
          label: 'Z axis is up',
          value: controller.zUp,
          onChanged: controller.setZUp,
        ),
        if (controller.hasMeshes) ...[
          const _SectionTitle('Shading'),
          SegmentedButton<ViewerShading>(
            segments: [
              for (final s in ViewerShading.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {controller.shading},
            showSelectedIcon: false,
            onSelectionChanged: (v) => controller.setShading(v.first),
          ),
        ],
        if (controller.hasPoints) ...[
          const _SectionTitle('Point size'),
          ShadSliderTheme(
            child: Slider(
              // Logarithmic scale: -2..2 maps to 0.25×..4×.
              value: (math.log(controller.pointScale) / math.ln2).clamp(-2.0, 2.0),
              min: -2,
              max: 2,
              divisions: 16,
              label: '${controller.pointScale.toStringAsFixed(2)}×',
              onChanged: (v) => controller.setPointScale(
                double.parse(math.pow(2, v).toStringAsFixed(3)),
              ),
            ),
          ),
        ],
        const _SectionTitle('Background'),
        SegmentedButton<ViewerBackground>(
          segments: [
            for (final b in ViewerBackground.values)
              ButtonSegment(value: b, label: Text(b.label)),
          ],
          selected: {controller.background},
          showSelectedIcon: false,
          onSelectionChanged: (v) => controller.setBackground(v.first),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: controller.resetView,
                icon: const Icon(LucideIcons.scan, size: 16),
                label: const Text('Reset view'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onScreenshot,
                icon: const Icon(LucideIcons.camera, size: 16),
                label: const Text('Screenshot'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Drag to rotate · pinch to zoom · two fingers to pan · double-tap to reset',
          style: text.bodySmall?.copyWith(color: colors.mutedForeground),
        ),
      ],
    ];
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      SectionLabel(text, padding: const EdgeInsets.fromLTRB(0, 20, 0, 8));
}

class _WarningsBox extends StatelessWidget {
  const _WarningsBox({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    return ViewerNotice(
      icon: LucideIcons.triangleAlert,
      tone: Tone.warning,
      margin: const EdgeInsets.only(top: 12),
      title: warnings.length == 1
          ? 'Part of the model is missing'
          : '${warnings.length} problems',
      message: warnings.join('\n'),
    );
  }
}

class _StatsTable extends StatelessWidget {
  const _StatsTable({required this.stats});

  final ModelStats stats;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final n = NumberFormat.decimalPattern();
    final rows = <(String, String)>[
      if (stats.meshes > 0) ('Meshes', n.format(stats.meshes)),
      ('Vertices', n.format(stats.vertices)),
      if (stats.meshes > 0) ('Triangles', n.format(stats.triangles)),
      if (stats.points > 0) ('Points', n.format(stats.points)),
      if (stats.lines > 0) ('Line segments', n.format(stats.lines)),
      if (stats.meshes > 0) ('Materials', n.format(stats.materials)),
      if (stats.meshes > 0) ('Textures', n.format(stats.textures)),
      if (stats.skinnedMeshes > 0) ('Skinned meshes', n.format(stats.skinnedMeshes)),
      ('Animations', n.format(stats.animations)),
      (
        'Size (W × H × D)',
        '${_dim(stats.sizeX)} × ${_dim(stats.sizeY)} × ${_dim(stats.sizeZ)}',
      ),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                border: i == 0
                    ? null
                    : Border(top: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      rows[i].$1,
                      style: text.bodySmall?.copyWith(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      textAlign: TextAlign.right,
                      style: text.bodyMedium?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            decoration: BoxDecoration(
              color: colors.muted.withValues(alpha: 0.5),
              border: Border(top: BorderSide(color: colors.border)),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(8)),
            ),
            child: Text(
              'Sizes are in model units',
              textAlign: TextAlign.right,
              style: text.bodySmall?.copyWith(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  static String _dim(double v) {
    final a = v.abs();
    if (a == 0) return '0';
    if (a >= 1000) return v.toStringAsFixed(0);
    if (a >= 100) return v.toStringAsFixed(1);
    if (a >= 1) return _trim(v.toStringAsFixed(2));
    return _trim(v.toStringAsPrecision(3));
  }

  static String _trim(String s) =>
      s.contains('.') && !s.contains('e') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

class _AnimationList extends StatelessWidget {
  const _AnimationList({required this.controller});

  final ThreeDViewerController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final clips = controller.clips;
    Widget tile({
      required int index,
      required String title,
      String? subtitle,
    }) {
      final active = controller.animationIndex == index;
      final playing = active && controller.animationPlaying;
      return ListRow(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        selected: active,
        leading: IconBox(
          playing ? LucideIcons.pause : LucideIcons.play,
          size: 32,
          color: active ? colors.primary : colors.foreground,
        ),
        title: title,
        subtitle: subtitle,
        onTap: () => active
            ? controller.toggleAnimation()
            : controller.playAnimation(index),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final clip in clips)
          tile(
            index: clip.index,
            title: clip.name,
            subtitle: '${clip.duration.toStringAsFixed(2)} s',
          ),
        if (clips.length > 1) tile(index: -1, title: 'Play all together'),
        if (controller.animationIndex != -2)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: controller.stopAnimation,
              icon: const Icon(LucideIcons.square, size: 14),
              label: const Text('Stop'),
            ),
          ),
      ],
    );
  }
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors.mutedForeground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}
