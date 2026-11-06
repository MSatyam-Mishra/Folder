import 'dart:ui';

import 'package:folders/shared/ui/app_tokens.dart';
import 'package:flutter/material.dart';

/// Card surface (border, soft shadow) for panels floating over content.
/// With [translucent] the page behind shows through a blur.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.borderRadius = 12,
    this.margin,
    this.padding,
    this.translucent = false,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(borderRadius);
    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        color: translucent
            ? colors.background.withValues(alpha: 0.85)
            : colors.card,
        borderRadius: radius,
        border: Border.all(color: colors.border),
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
    if (translucent) {
      content = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: content,
        ),
      );
    }
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: context.isDarkMode ? 0.35 : 0.08,
              ),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: content,
      ),
    );
  }
}
