/// Building blocks shared by the media, code and tool viewers (text/code
/// editor, image, media, hex, font, HTML, 3D, archive, comic, design,
/// vector, LocalSend and the video downloader), in the shadcn/ui style of
/// `package:folder/shared/ui/app_ui.dart`.
///
/// Everything here takes its colours from `context.colors`, so it works in
/// light and dark mode with every colour scheme.
library;

import 'package:folder/core/theme/app_theme.dart';
import 'package:folder/core/theme/app_theme_settings.dart';
import 'package:folder/core/theme/theme_cubit.dart';
import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shadcn_ui/shadcn_ui.dart'
    show LucideIcons, ShadTheme, ShadThemeData, kDefaultFontFamilyMono;

export 'package:folder/shared/ui/app_ui.dart';
export 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/// Monospaced text (code, hex dumps, logs): Geist Mono, bundled by shadcn_ui.
abstract final class CodeFont {
  static const String family = kDefaultFontFamilyMono;

  /// For scripts Geist Mono doesn't cover.
  static const List<String> fallback = [
    'Consolas',
    'Menlo',
    'Roboto Mono',
    'Noto Sans Mono',
    'monospace',
  ];

  static TextStyle style({
    double fontSize = 13,
    Color? color,
    double? height,
    FontWeight? fontWeight,
  }) =>
      TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontSize: fontSize,
        color: color,
        height: height,
        fontWeight: fontWeight,
        letterSpacing: 0,
      );
}

/// Meaning of a badge, notice or message.
enum Tone { neutral, info, success, warning, destructive }

/// Status colours the shadcn palette lacks (success, warning), tuned for
/// contrast on the light and dark backgrounds.
extension ToneColors on BuildContext {
  Color toneColor(Tone tone) {
    final dark = isDarkMode;
    return switch (tone) {
      Tone.neutral => colors.foreground,
      Tone.info => colors.primary,
      Tone.success => dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
      Tone.warning => dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309),
      Tone.destructive => colors.destructive,
    };
  }
}

// ---------------------------------------------------------------------------
// Immersive (media) screens
// ---------------------------------------------------------------------------

/// Gives [child] the app's dark theme (same colour scheme), whatever the
/// app's mode: for screens whose canvas is black (photos, video, comics,
/// photo editing), so their header, sheets and menus read as one dark
/// surface instead of a light bar over a black picture.
class ImmersiveTheme extends StatelessWidget {
  const ImmersiveTheme({super.key, required this.child});

  final Widget child;

  static AppThemeSettings _settings(BuildContext context, {bool listen = true}) {
    try {
      final cubit = listen
          ? context.watch<ThemeCubit>()
          : context.read<ThemeCubit>();
      return cubit.state;
    } catch (_) {
      // No ThemeCubit above (isolated widget tests).
      return AppThemeSettings.defaults();
    }
  }

  /// Slider thumbs in the background colour vanish over black media.
  static ThemeData _withMediaSliders(ThemeData theme, ShadThemeData shad) {
    final c = shad.colorScheme;
    return theme.copyWith(
      sliderTheme: theme.sliderTheme.copyWith(
        thumbColor: c.foreground,
        inactiveTrackColor: c.foreground.withValues(alpha: 0.22),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (context.isDarkMode) {
      return Theme(
        data: _withMediaSliders(Theme.of(context), ShadTheme.of(context)),
        child: child,
      );
    }
    final shad = AppTheme.shad(_settings(context), Brightness.dark);
    final c = shad.colorScheme;
    final base = ThemeData(
      fontFamily: shad.textTheme.family,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: c.primary,
        onPrimary: c.primaryForeground,
        secondary: c.secondary,
        onSecondary: c.secondaryForeground,
        error: c.destructive,
        onError: c.destructiveForeground,
        surface: c.background,
        onSurface: c.foreground,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.primary,
        selectionColor: c.selection,
        selectionHandleColor: c.primary,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(999),
        thumbColor: WidgetStatePropertyAll(c.border),
      ),
    );
    return ShadTheme(
      data: shad,
      child: Theme(
        data: _withMediaSliders(AppTheme.material(base, shad), shad),
        child: child,
      ),
    );
  }
}

/// Resolved dark shad theme, for code that needs the tokens outside the
/// [ImmersiveTheme] subtree (e.g. when configuring a player). Doesn't
/// subscribe to theme changes.
ShadThemeData immersiveShadTheme(BuildContext context) =>
    context.isDarkMode
        ? ShadTheme.of(context)
        : AppTheme.shad(
            ImmersiveTheme._settings(context, listen: false),
            Brightness.dark,
          );

/// shadcn slider look: background-coloured thumb with a primary ring, so
/// the thumb stays visible in dark mode (the app theme's plain thumb blends
/// into dark pages).
class ShadSliderTheme extends StatelessWidget {
  const ShadSliderTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        thumbShape: _RingThumbShape(
          fill: colors.background,
          ring: colors.primary,
        ),
        inactiveTrackColor: colors.muted,
      ),
      child: child,
    );
  }
}

class _RingThumbShape extends SliderComponentShape {
  const _RingThumbShape({required this.fill, required this.ring});

  final Color fill;
  final Color ring;

  static const double _radius = 9;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final enabled = enableAnimation.value > 0.5;
    canvas.drawCircle(center, _radius, Paint()..color = fill);
    canvas.drawCircle(
      center,
      _radius - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = enabled ? ring : ring.withValues(alpha: 0.4),
    );
  }
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

/// Empty, error and "can't show this" states: a muted icon in a circle, a
/// title, a description and actions.
class ViewerMessage extends StatelessWidget {
  const ViewerMessage({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.details,
    this.actions = const [],
    this.tone = Tone.neutral,
    this.padding = const EdgeInsets.all(24),
    this.maxWidth = 420,
    this.shrinkWrap = false,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// Sizes to its content instead of centring itself in the available
  /// space (e.g. inside a card).
  final bool shrinkWrap;

  /// Technical details, shown collapsed.
  final String? details;
  final List<Widget> actions;
  final Tone tone;
  final EdgeInsetsGeometry padding;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final iconColor = tone == Tone.neutral
        ? colors.mutedForeground
        : context.toneColor(tone);
    final content = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: tone == Tone.neutral
                      ? colors.muted
                      : iconColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 24, color: iconColor),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: text.titleMedium,
              ),
              if (message != null && message!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.mutedForeground,
                    height: 1.45,
                  ),
                ),
              ],
              if (details != null && details!.trim().isNotEmpty)
                _Details(details!),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ],
          ),
        );
    if (shrinkWrap) return Padding(padding: padding, child: content);
    return Center(
      child: SingleChildScrollView(padding: padding, child: content),
    );
  }
}

class _Details extends StatefulWidget {
  const _Details(this.text);

  final String text;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          TextButton.icon(
            onPressed: () => setState(() => _open = !_open),
            style: TextButton.styleFrom(
              foregroundColor: colors.mutedForeground,
              minimumSize: const Size(0, 32),
            ),
            icon: Icon(
              _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              size: 16,
            ),
            label: const Text('Technical details'),
          ),
          if (_open)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.muted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                widget.text,
                maxLines: 10,
                style: CodeFont.style(
                  fontSize: 12,
                  color: colors.mutedForeground,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Centred spinner with an optional label and determinate [progress].
class ViewerLoading extends StatelessWidget {
  const ViewerLoading({super.key, this.label, this.progress, this.padding});

  final String? label;
  final double? progress;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2.5,
                strokeCap: StrokeCap.round,
                backgroundColor: progress == null ? null : colors.muted,
              ),
            ),
            if (label != null) ...[
              const SizedBox(height: 12),
              Text(
                label!,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colors.mutedForeground),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Inline alert (shadcn Alert): icon, text and actions, bordered.
class ViewerNotice extends StatelessWidget {
  const ViewerNotice({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.actions = const [],
    this.tone = Tone.neutral,
    this.margin = const EdgeInsets.fromLTRB(12, 8, 12, 0),
  });

  final IconData icon;
  final String? title;
  final String message;
  final List<Widget> actions;
  final Tone tone;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final accent = tone == Tone.neutral ? colors.foreground : context.toneColor(tone);
    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tone == Tone.neutral
              ? colors.muted.withValues(alpha: 0.5)
              : accent.withValues(alpha: context.isDarkMode ? 0.12 : 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: tone == Tone.neutral
                ? colors.border
                : accent.withValues(alpha: 0.35),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 10, actions.isEmpty ? 12 : 6, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null)
                      Text(
                        title!,
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: tone == Tone.neutral ? colors.foreground : accent,
                        ),
                      ),
                    Text(
                      message,
                      style: text.bodySmall?.copyWith(
                        color: tone == Tone.neutral || tone == Tone.info
                            ? colors.mutedForeground
                            : colors.foreground.withValues(alpha: 0.8),
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(width: 4),
                ...actions,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Toolbars
// ---------------------------------------------------------------------------

/// Square ghost button for toolbars, with an optional pressed ("toggle on")
/// state shown as an accent background.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.size = 36,
    this.iconSize = 18,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onPressed != null;
    final fg = !enabled
        ? colors.mutedForeground.withValues(alpha: 0.45)
        : selected
            ? colors.accentForeground
            : (color ?? colors.foreground);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: selected ? true : null,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: selected ? colors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: size,
              child: Icon(icon, size: iconSize, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin vertical separator between toolbar groups.
class ToolDivider extends StatelessWidget {
  const ToolDivider({super.key, this.height = 20});

  final double height;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            width: 1,
            height: height,
            child: ColoredBox(color: context.colors.border),
          ),
        ),
      );
}

/// Subtle pill for counters ("3 / 12", "42 matches").
class CountPill extends StatelessWidget {
  const CountPill(this.label, {super.key, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: colors.mutedForeground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.mutedForeground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ],
      ),
    );
  }
}

/// shadcn Badge: small rounded label for a state ("Encrypted", "Done").
class StatusBadge extends StatelessWidget {
  const StatusBadge(
    this.label, {
    super.key,
    this.icon,
    this.tone = Tone.neutral,
    this.outline = false,
  });

  final String label;
  final IconData? icon;
  final Tone tone;

  /// Bordered instead of tinted.
  final bool outline;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = tone == Tone.neutral ? colors.secondaryForeground : context.toneColor(tone);
    final bg = outline
        ? Colors.transparent
        : tone == Tone.neutral
            ? colors.secondary
            : fg.withValues(alpha: context.isDarkMode ? 0.16 : 0.1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: outline ? Border.all(color: colors.border) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lists and panels
// ---------------------------------------------------------------------------

/// Muted heading above a group of rows or settings.
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.label, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(4, 20, 4, 8),
  });

  final String label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: context.colors.mutedForeground,
                    letterSpacing: 0.2,
                  ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 40-px rounded square with an icon, for list rows.
class IconBox extends StatelessWidget {
  const IconBox(
    this.icon, {
    super.key,
    this.size = 40,
    this.color,
    this.background,
  });

  final IconData icon;
  final double size;
  final Color? color;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? colors.muted,
        borderRadius: BorderRadius.circular(size >= 36 ? 8 : 6),
      ),
      child: Icon(icon, size: size * 0.45, color: color ?? colors.foreground),
    );
  }
}

/// List row: leading (icon box, file icon…), title, muted subtitle and
/// trailing widget; 8-px rounded ink.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.enabled = true,
    this.titleMaxLines = 1,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.titleStyle,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;

  /// Replaces [subtitle] (e.g. a progress bar).
  final Widget? subtitleWidget;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool enabled;
  final int titleMaxLines;
  final EdgeInsetsGeometry padding;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final row = Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: titleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle ??
                      text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (subtitleWidget != null) ...[
                  const SizedBox(height: 4),
                  subtitleWidget!,
                ] else if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: row,
        ),
      ),
    );
  }
}

/// Bordered card surface (shadcn Card) for grouping content on a page.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // A Material (not a decorated box) so list tiles inside show their ink.
    return Padding(
      padding: margin,
      child: Material(
        color: colors.card,
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.border),
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Header of a docked side panel or sheet: title, optional subtitle and a
/// close button.
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
    this.closeTooltip = 'Close',
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium,
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: text.bodySmall),
                ],
              ],
            ),
          ),
        ),
        if (onClose != null)
          AppIconButton(
            icon: const Icon(LucideIcons.x, size: 18),
            tooltip: closeTooltip,
            onPressed: onClose,
          ),
      ],
    );
  }
}

/// Label/value pairs (file details, metadata), values selectable.
class DetailList extends StatelessWidget {
  const DetailList({super.key, required this.entries, this.labelWidth});

  final Iterable<MapEntry<String, String>> entries;

  /// Label column width; null stacks label above value.
  final double? labelWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final list = entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < list.length; i++)
          DecoratedBox(
            decoration: BoxDecoration(
              border: i == list.length - 1
                  ? null
                  : Border(bottom: BorderSide(color: colors.border)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: labelWidth == null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(list[i].key, style: text.labelMedium),
                        const SizedBox(height: 2),
                        SelectableText(list[i].value, style: text.bodyMedium),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: labelWidth,
                          child: Text(
                            list[i].key,
                            style: text.bodyMedium
                                ?.copyWith(color: colors.mutedForeground),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SelectableText(
                            list[i].value,
                            style: text.bodyMedium,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
      ],
    );
  }
}

/// Popup menu entry with a leading Lucide icon (shadcn DropdownMenuItem).
PopupMenuItem<T> menuItem<T>({
  required T value,
  required String label,
  IconData? icon,
  bool enabled = true,
  bool destructive = false,
  bool checked = false,
}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    height: 40,
    child: Builder(
      builder: (context) {
        final colors = context.colors;
        final fg = destructive ? colors.destructive : colors.popoverForeground;
        return Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: enabled ? fg : colors.mutedForeground),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: enabled ? fg : colors.mutedForeground,
                    ),
              ),
            ),
            if (checked) ...[
              const SizedBox(width: 12),
              Icon(LucideIcons.check, size: 16, color: fg),
            ],
          ],
        );
      },
    ),
  );
}

/// Header icon button that opens a popup menu.
class MenuIconButton<T> extends StatelessWidget {
  const MenuIconButton({
    super.key,
    required this.itemBuilder,
    required this.onSelected,
    this.icon = LucideIcons.ellipsisVertical,
    this.tooltip = 'More',
    this.enabled = true,
    this.color,
    this.child,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final Color? color;

  /// Replaces the icon button (e.g. a labelled trigger).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled,
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 300),
      icon: child == null ? Icon(icon, size: 20, color: color) : null,
      iconSize: 20,
      padding: EdgeInsets.zero,
      style: child == null
          ? IconButton.styleFrom(
              minimumSize: const Size(40, 40),
              fixedSize: const Size(40, 40),
              padding: EdgeInsets.zero,
            )
          : null,
      child: child,
    );
  }
}
