import 'dart:ui' show ColorFilter, ImageFilter;

import 'package:explorer/core/platform/window_effects.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Glass surfaces: over a window with an effect on (Acrylic, vibrancy...), so
/// menus and sheets look part of it, and on phones with Liquid glass on.
abstract final class AppGlass {
  /// Whether menus and sheets are glass.
  static bool isOn(BuildContext context) =>
      (WindowEffects.supported && context.read<ThemeCubit>().state.windowEffect) || isLiquid(context);

  /// Whether Liquid glass is on (Options, on phones): bars, sheets, menus and
  /// the round button float over the content and let it show through.
  /// With [listen], the caller rebuilds when it's switched.
  static bool isLiquid(BuildContext context, {bool listen = false}) {
    if (const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}.contains(defaultTargetPlatform)) {
      return false;
    }
    try {
      final cubit = listen ? context.watch<ThemeCubit>() : context.read<ThemeCubit>();
      return cubit.state.liquidGlass;
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
  const GlassSurface({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (AppGlass.isLiquid(context, listen: true)) {
      return LiquidGlass(tint: color, child: child);
    }
    final settings = WindowEffects.supported ? context.watch<ThemeCubit>().state : null;
    // Its own Material: ink (hover, press) shows above the colour.
    final content = Material(type: MaterialType.transparency, child: child);
    if (settings == null || !settings.windowEffect) return ColoredBox(color: color, child: content);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: ColoredBox(
          color: color.withValues(alpha: AppGlass.opacityFor(settings.transparency)),
          child: content,
        ),
      ),
    );
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
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.16 : 0.6)),
            ),
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
