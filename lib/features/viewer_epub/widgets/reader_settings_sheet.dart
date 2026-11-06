import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../reader/reader_settings.dart';

/// Appearance settings; every change is applied live through [onChanged].
class ReaderSettingsSheet extends StatefulWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.initial,
    required this.onChanged,
    this.fixedLayout = false,
  });

  final ReaderSettings initial;
  final ValueChanged<ReaderSettings> onChanged;

  /// Fixed-layout books ignore most typography settings.
  final bool fixedLayout;

  static Future<void> show(
    BuildContext context, {
    required ReaderSettings initial,
    required ValueChanged<ReaderSettings> onChanged,
    bool fixedLayout = false,
  }) {
    return AppSheet.show<void>(
      context,
    style: SheetStyle.side,
      maxHeightFraction: 0.85,
      child: ReaderSettingsSheet(
        initial: initial,
        onChanged: onChanged,
        fixedLayout: fixedLayout,
      ),
    );
  }

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  late ReaderSettings _s = widget.initial;

  void _set(ReaderSettings s) {
    if (s == _s) return;
    setState(() => _s = s);
    widget.onChanged(s);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ViewerSliderTheme(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ViewerSheetHeader(
            title: 'Reading settings',
            description: widget.fixedLayout
                ? 'This book has a fixed layout, so only the theme applies.'
                : null,
            trailing: TextButton.icon(
              icon: const Icon(LucideIcons.rotateCcw, size: 16),
              label: const Text('Reset'),
              onPressed: _s == const ReaderSettings()
                  ? null
                  : () => _set(const ReaderSettings()),
            ),
          ),
          _label(context, 'Theme'),
          Row(
            children: [
              for (final t in ReaderTheme.values) ...[
                if (t != ReaderTheme.values.first) const SizedBox(width: 8),
                Expanded(child: _themeSwatch(context, t)),
              ],
            ],
          ),
          if (!widget.fixedLayout) ...[
            const SizedBox(height: 20),
            _label(
              context,
              'Text size',
              value: '${(_s.fontScale * 100).round()}%',
            ),
            Row(
              children: [
                _stepButton(
                  icon: LucideIcons.minus,
                  tooltip: 'Smaller text',
                  onPressed: _s.fontScale <= 0.6
                      ? null
                      : () => _set(
                          _s.copyWith(
                            fontScale: _round(_s.fontScale - 0.1, 0.6, 2.5),
                          ),
                        ),
                ),
                Expanded(
                  child: Slider(
                    value: _s.fontScale.clamp(0.6, 2.5),
                    min: 0.6,
                    max: 2.5,
                    divisions: 19,
                    label: '${(_s.fontScale * 100).round()}%',
                    onChanged: (v) =>
                        _set(_s.copyWith(fontScale: _round(v, 0.6, 2.5))),
                  ),
                ),
                _stepButton(
                  icon: LucideIcons.plus,
                  tooltip: 'Larger text',
                  onPressed: _s.fontScale >= 2.5
                      ? null
                      : () => _set(
                          _s.copyWith(
                            fontScale: _round(_s.fontScale + 0.1, 0.6, 2.5),
                          ),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _label(context, 'Font'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in ReaderFont.values)
                  ChoiceChip(
                    label: Text(f.label),
                    selected: _s.font == f,
                    onSelected: (_) => _set(_s.copyWith(font: f)),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _label(context, 'Line spacing'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final lh in ReaderSettings.lineHeights)
                  ChoiceChip(
                    label: Text(
                      lh == null ? 'Publisher' : lh.toStringAsFixed(1),
                    ),
                    selected: _s.lineHeight == lh,
                    onSelected: (_) => _set(_s.copyWith(lineHeight: () => lh)),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _label(context, 'Margins', value: '${_s.margin.round()} px'),
            Slider(
              value: _s.margin.clamp(0, 80),
              min: 0,
              max: 80,
              divisions: 10,
              label: '${_s.margin.round()} px',
              onChanged: (v) => _set(_s.copyWith(margin: v.roundToDouble())),
            ),
            const SizedBox(height: 12),
            _label(context, 'Alignment'),
            SegmentedButton<ReaderAlign>(
              segments: [
                for (final a in ReaderAlign.values)
                  ButtonSegment(
                    value: a,
                    label: Text(a.label),
                    icon: Icon(switch (a) {
                      ReaderAlign.publisher => LucideIcons.bookOpen,
                      ReaderAlign.justify => LucideIcons.alignJustify,
                      ReaderAlign.left => LucideIcons.alignLeft,
                    }, size: 16),
                  ),
              ],
              selected: {_s.align},
              showSelectedIcon: false,
              onSelectionChanged: (v) => _set(_s.copyWith(align: v.first)),
            ),
            const SizedBox(height: 20),
            _label(context, 'Layout'),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(LucideIcons.bookOpenText, size: 16),
                  label: Text('Pages'),
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(LucideIcons.scrollText, size: 16),
                  label: Text('Scroll'),
                ),
              ],
              selected: {_s.paginated},
              showSelectedIcon: false,
              onSelectionChanged: (v) => _set(_s.copyWith(paginated: v.first)),
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.border),
              ),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                title: const Text('Two-page spreads'),
                subtitle: const Text(
                  'On wide screens, landscape and unfolded foldables',
                ),
                value: _s.spreads,
                onChanged: _s.paginated
                    ? (v) => _set(_s.copyWith(spreads: v))
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static double _round(double v, double min, double max) =>
      ((v * 10).round() / 10).clamp(min, max);

  Widget _label(BuildContext context, String text, {String? value}) {
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(text, style: theme.titleSmall)),
          if (value != null)
            Text(
              value,
              style: theme.bodySmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stepButton({
    required IconData icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    return IconButton.outlined(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        side: BorderSide(color: context.colors.input),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 16),
    );
  }

  Widget _themeSwatch(BuildContext context, ReaderTheme t) {
    final selected = _s.theme == t;
    final colors = context.colors;
    final shown = t.resolve(Theme.of(context).brightness);
    final radius = BorderRadius.circular(10);
    return Semantics(
      button: true,
      selected: selected,
      label: '${t.label} theme',
      child: Column(
        children: [
          InkWell(
            borderRadius: radius,
            onTap: () => _set(_s.copyWith(theme: t)),
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: shown.background,
                borderRadius: radius,
                border: Border.all(
                  color: selected ? colors.ring : colors.border,
                  width: selected ? 2 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: t == ReaderTheme.system
                  ? Icon(LucideIcons.sunMoon, size: 18, color: shown.foreground)
                  : Text(
                      'Aa',
                      style: TextStyle(
                        color: shown.foreground,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t.label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: selected ? colors.foreground : colors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}
