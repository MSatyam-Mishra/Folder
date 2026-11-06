import 'package:folders/shared/icons/app_icons.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';

export 'package:folders/shared/liquid_glass/explorer_liquid_glass.dart';

typedef DockedTopBarScaffold = AppTopBarScaffold;

/// Header row: menu/back button, title, actions. Shown by
/// [AppTopBarScaffold] (via ExplorerScaffold) at the top of each page.
class DockedGlossyTopBar extends StatelessWidget {
  const DockedGlossyTopBar({
    super.key,
    required this.title,
    this.onMenuPressed,
    this.onMorePressed,
    this.leading,
    this.trailing,
    this.height = AppTopBarScaffold.defaultBarHeight,
  });

  final String title;
  final VoidCallback? onMenuPressed;
  final VoidCallback? onMorePressed;
  final Widget? leading;
  final Widget? trailing;
  final double height;

  static double totalHeight(EdgeInsets margin, double barHeight) =>
      barHeight + 1;

  /// Space above the first row of scrolling content.
  static double contentTopInset(
    BuildContext context, {
    EdgeInsets? barMargin,
    double barHeight = AppTopBarScaffold.defaultBarHeight,
  }) =>
      AppTopBarScaffold.contentTopInset(context, barHeight: barHeight);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final titleStyle = AppForeground.title(context);

    return IconTheme(
      data: IconThemeData(color: colors.foreground, size: 20),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              leading ??
                  // Only with a menu to open: on a screen with none, the icon
                  // would do nothing.
                  (onMenuPressed != null || (Scaffold.maybeOf(context)?.hasDrawer ?? false)
                      ? AppIconButton(
                          icon: AppIcons.drawerMenu(color: colors.foreground),
                          tooltip: 'Open menu',
                          onPressed:
                              onMenuPressed ?? () => Scaffold.of(context).openDrawer(),
                        )
                      : const SizedBox.shrink()),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              trailing ??
                  (onMorePressed != null
                      ? AppIconButton(
                          icon: AppIcons.optionsMenu(color: colors.foreground),
                          tooltip: 'Options',
                          onPressed: onMorePressed,
                        )
                      : const SizedBox(width: 8)),
            ],
          ),
        ),
      ),
    );
  }
}
