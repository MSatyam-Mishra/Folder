import 'dart:ui';

import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/shared/ui/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Page shell: a translucent header (blurred, hairline bottom border) over a
/// full-screen body that scrolls underneath it.
///
/// Pad scrolling content with [contentTopInset] so its first row starts
/// below the header.
class AppTopBarScaffold extends StatelessWidget {
  const AppTopBarScaffold({
    super.key,
    required this.topBarBuilder,
    required this.body,
    this.drawer,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.backgroundColor,
    this.barHeight = defaultBarHeight,
    // Kept for callers of the previous glass top bar; unused.
    this.barMargin,
    this.barRadius,
    this.pixelRatio,
  });

  static const double defaultBarHeight = 56;

  final Widget Function(BuildContext scaffoldContext) topBarBuilder;
  final Widget body;
  final Widget? drawer;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Color? backgroundColor;
  final double barHeight;
  final EdgeInsets? barMargin;
  final double? barRadius;
  final double? pixelRatio;

  /// Space above the first row of scrolling content.
  static double contentTopInset(
    BuildContext context, {
    EdgeInsets? barMargin,
    double barHeight = defaultBarHeight,
  }) =>
      MediaQuery.paddingOf(context).top + barHeight + 1;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dark = context.isDarkMode;
    final topInset = MediaQuery.paddingOf(context).top;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: colors.background,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: backgroundColor ?? colors.background,
        drawer: drawer,
        floatingActionButton: floatingActionButton,
        floatingActionButtonLocation: floatingActionButtonLocation,
        body: Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.background.withValues(alpha: 0.82),
                      border: Border(bottom: BorderSide(color: colors.border)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.only(top: topInset),
                      child: SizedBox(
                        height: barHeight,
                        child: Builder(builder: topBarBuilder),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square ghost icon button used in headers and toolbars.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final glyph = icon;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      // Sweet and Dracula colour their icons.
      color: color ?? (glyph is Icon && glyph.color == null ? context.look.tint(glyph.icon) : null),
      icon: icon,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      // Exactly 40×40: Material would otherwise pad the tap target to 48.
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
