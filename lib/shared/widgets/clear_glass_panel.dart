import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';

/// Panel floating over content (translucent card); see [AppPanel].
class ClearGlassPanel extends StatelessWidget {
  const ClearGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = 12,
    this.margin,
    this.padding,
    // Kept for existing callers; unused.
    this.blurSigma,
    this.rimWidth,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final double? blurSigma;
  final double? rimWidth;

  @override
  Widget build(BuildContext context) => AppPanel(
        borderRadius: borderRadius.clamp(0, 16).toDouble(),
        margin: margin,
        padding: padding,
        translucent: true,
        child: child,
      );
}

typedef ClearGlassForeground = AppForeground;
