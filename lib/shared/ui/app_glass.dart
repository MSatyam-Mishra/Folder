import 'dart:ui' show ImageFilter;

import 'package:explorer/core/platform/window_effects.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Menus and sheets over a window with an effect on (Acrylic, vibrancy...):
/// see-through and blurred like the window, so they look part of it.
abstract final class AppGlass {
  /// Whether the window effect is on.
  static bool isOn(BuildContext context) =>
      WindowEffects.supported && context.read<ThemeCubit>().state.windowEffect;

  /// How solid a surface is at the window's [transparency]: more than the
  /// window itself, as text sits on it over the app's own content.
  static double opacityFor(double transparency) => (1 - transparency * 0.6).clamp(0.4, 1.0);
}

/// [child] on a surface of [color], see-through and blurring what's behind
/// it while the window effect is on, else solid.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
