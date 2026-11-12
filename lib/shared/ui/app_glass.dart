import 'dart:ui' show ColorFilter, ImageFilter;

import 'package:folders/core/platform/window_effects.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Glass surfaces: over a window with an effect on (Acrylic, vibrancy...), so
/// menus and sheets look part of it, and on phones with Liquid glass on.
abstract final class AppGlass {
  /// Whether menus and sheets are glass.
  static bool isOn(BuildContext context) =>
      (WindowEffects.supported && context.read<ThemeCubit>().state.windowEffect) || isLiquid(context);

  /// Whether Liquid glass is on (Options, on phones; always in the iOS
  /// style, on every system; never in the Android style, which is
  /// Material's): bars, sheets, menus and the round button float over the
  /// content and let it show through. With [listen], the caller rebuilds
  /// when it's switched.
  static bool isLiquid(BuildContext context, {bool listen = false}) {
    try {
      final settings = (listen ? context.watch<ThemeCubit>() : context.read<ThemeCubit>()).state;
      if (settings.style.glass) return true;
      if (settings.style == AppStyle.android) return false;
      if (const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform)) {
        return false;
      }
      return settings.liquidGlass;
    } on ProviderNotFoundException {
      return false;
    }
  }

  /// How solid a surface is at the window's [transparency]: more than the
  /// window itself, as text sits on it over the app's own content.
  static double opacityFor(double transparency) => (1 - transparency * 0.6).clamp(0.4, 1.0);
}

/// [child] on a surface of [color], see-through and blurring what's behind
/// it while the glass is on, else solid.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.color, required this.child, this.borderRadius});

  final Color color;
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    if (AppGlass.isLiquid(context, listen: true)) {
      return LiquidGlass(tint: color, borderRadius: borderRadius ?? BorderRadius.zero, child: child);
    }
    final settings = WindowEffects.supported ? context.watch<ThemeCubit>().state : null;
    // Its own Material: ink (hover, press) shows above the colour.
    final content = Material(type: MaterialType.transparency, child: child);
    if (settings == null || !settings.windowEffect) return ColoredBox(color: color, child: content);
    final blurred = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: ColoredBox(
        color: color.withValues(alpha: AppGlass.opacityFor(settings.transparency)),
        child: content,
      ),
    );
    final radius = borderRadius;
    return radius == null ? ClipRect(child: blurred) : ClipRRect(borderRadius: radius, child: blurred);
  }
}

/// The Liquid glass material: what's behind blurred and a little more vivid,
/// under a thin tint, with a bright rim and a soft sheen from the top left.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({super.key, required this.child, this.tint, this.borderRadius = BorderRadius.zero, this.opacity});

  final Widget child;

  /// The colour of the tint; the page background if left out.
  final Color? tint;
  final BorderRadius borderRadius;

  /// How strong the tint is; by default enough for text over anything.
  final double? opacity;

  /// More colourful behind the blur, as real glass seems to be.
  static final _filter = ImageFilter.compose(
    outer: const ColorFilter.matrix([
      1.26, -0.22, -0.04, 0, 0,
      -0.07, 1.11, -0.04, 0, 0,
      -0.07, -0.22, 1.29, 0, 0,
      0, 0, 0, 1, 0,
    ]),
    inner: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = tint ?? theme.colorScheme.surface;
    final color = base.withValues(alpha: opacity ?? (dark ? 0.55 : 0.62));
    final sheen = Colors.white.withValues(alpha: dark ? 0.09 : 0.3);
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: _filter,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color),
          child: CustomPaint(
            foregroundPainter: GlassRimPainter(borderRadius: borderRadius, dark: dark, width: 1),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [sheen, sheen.withValues(alpha: 0)],
                  stops: const [0, 0.55],
                ),
              ),
              // Its own Material: ink (hover, press) shows above the colour.
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// A large pane of Liquid glass for the iOS style's sidebar: frosted over the
/// wallpaper, lifted by a soft shadow, with a rim that catches the light at
/// the top left and fades towards the bottom right.
class GlassPane extends StatelessWidget {
  const GlassPane({super.key, required this.child, this.borderRadius = const BorderRadius.all(Radius.circular(18))});

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.35 : 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: LiquidGlass._filter,
          child: CustomPaint(
            foregroundPainter: GlassRimPainter(borderRadius: borderRadius, dark: dark),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: dark
                      ? [Colors.white.withValues(alpha: 0.13), Colors.white.withValues(alpha: 0.05)]
                      : [Colors.white.withValues(alpha: 0.72), Colors.white.withValues(alpha: 0.42)],
                ),
              ),
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Liquid glass's rim: bright where the light comes from (the top left),
/// fading round to the bottom right, as on the edge of real glass.
class GlassRimPainter extends CustomPainter {
  const GlassRimPainter({required this.borderRadius, required this.dark, this.width = 1.2});

  final BorderRadius borderRadius;
  final bool dark;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final rrect = borderRadius.toRRect(rect);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [Colors.white.withValues(alpha: 0.42), Colors.white.withValues(alpha: 0.06), Colors.white.withValues(alpha: 0.2)]
              : [Colors.white, Colors.white.withValues(alpha: 0.35), Colors.white.withValues(alpha: 0.8)],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(GlassRimPainter old) => old.dark != dark || old.borderRadius != borderRadius || old.width != width;
}

/// What Liquid glass floats over in the iOS style: soft colour, like iOS's
/// own wallpapers, so the glass has something to bend and blur. Glass over a
/// plain white page looks like a white page.
class LiquidWallpaper extends StatelessWidget {
  const LiquidWallpaper({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(painter: _WallpaperPainter(dark), child: child);
  }
}

class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter(this.dark);

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final whole = Offset.zero & size;
    canvas.drawRect(whole, Paint()..color = dark ? const Color(0xFF05070E) : const Color(0xFFE9EEF8));
    final longest = size.longestSide;
    // (centre as a fraction of the size, radius as a fraction of the longest side, colour)
    final blobs = dark
        ? const [
            (Offset(0.08, 0.05), 0.75, Color(0x8C1F5BFF)),
            (Offset(0.95, 0.35), 0.65, Color(0x737A3CFF)),
            (Offset(0.35, 1.0), 0.7, Color(0x4D00A6C8)),
          ]
        : const [
            (Offset(0.05, 0.0), 0.8, Color(0xE07FB0FF)),
            (Offset(1.0, 0.3), 0.7, Color(0xCCB49CFF)),
            (Offset(0.3, 1.05), 0.75, Color(0xB3FFBE9C)),
            (Offset(0.75, 0.95), 0.45, Color(0x8C8FE3D0)),
          ];
    for (final (centre, radius, color) in blobs) {
      final c = Offset(centre.dx * size.width, centre.dy * size.height);
      final r = radius * longest;
      canvas.drawRect(
        whole,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_WallpaperPainter old) => old.dark != dark;
}

/// The round button of a page: on Liquid glass, tinted glass with the content
/// passing behind it.
class AppFab extends StatelessWidget {
  const AppFab({super.key, required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  static const _radius = 20.0;

  @override
  Widget build(BuildContext context) {
    final liquid = AppGlass.isLiquid(context, listen: true);
    final primary = Theme.of(context).colorScheme.primary;
    final button = FloatingActionButton(
      tooltip: tooltip,
      onPressed: onPressed,
      backgroundColor: liquid ? Colors.transparent : null,
      foregroundColor: liquid ? Colors.white : null,
      elevation: liquid ? 0 : null,
      focusElevation: liquid ? 0 : null,
      hoverElevation: liquid ? 0 : null,
      highlightElevation: liquid ? 0 : null,
      shape: liquid ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)) : null,
      child: Icon(icon),
    );
    if (!liquid) return button;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_radius),
        boxShadow: [BoxShadow(color: primary.withValues(alpha: 0.3), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: LiquidGlass(
        tint: primary,
        opacity: 0.72,
        borderRadius: BorderRadius.circular(_radius),
        child: button,
      ),
    );
  }
}
