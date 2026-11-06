import 'package:folders/shared/icons/app_icons.dart';
import 'package:folders/shared/widgets/clear_glass_panel.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:flutter/material.dart';
/// App-wide page shell with the docked clear-glass top bar.
class ExplorerScaffold extends StatelessWidget {
  const ExplorerScaffold({
    super.key,
    required this.title,
    required this.body,
    this.leading,
    this.trailing,
    this.onMorePressed,
    this.drawer,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.backgroundColor,
    this.automaticallyImplyBack = true,
    this.topBarBuilder,
  });

  final String title;
  final Widget body;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onMorePressed;
  final Widget? drawer;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Color? backgroundColor;
  final bool automaticallyImplyBack;

  /// Full override (e.g. file explorer selection mode).
  final Widget Function(BuildContext scaffoldContext)? topBarBuilder;

  @override
  Widget build(BuildContext context) {
    return DockedTopBarScaffold(
      drawer: drawer,
      backgroundColor: backgroundColor,
      topBarBuilder: topBarBuilder ??
          (scaffoldContext) => DockedGlossyTopBar(
                title: title,
                leading: _resolveLeading(scaffoldContext),
                trailing: trailing,
                onMorePressed: onMorePressed,
                onMenuPressed: drawer != null &&
                        _resolveLeading(scaffoldContext) == null
                    ? () => Scaffold.of(scaffoldContext).openDrawer()
                    : null,
              ),
      body: body,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
    );
  }

  Widget? _resolveLeading(BuildContext context) {
    if (leading != null) return leading;
    if (automaticallyImplyBack && Navigator.canPop(context)) {
      return ExplorerTopBar.backButton(context);
    }
    return null;
  }
}

/// Helpers for building docked top bar actions.
abstract final class ExplorerTopBar {
  static Widget backButton(BuildContext context) {
    return IconButton(
      icon: AppIcons.back(color: ClearGlassForeground.icon(context)),
      tooltip: 'Back',
      onPressed: () => Navigator.maybePop(context),
    );
  }

  static Widget iconButton({
    required BuildContext context,
    required Widget icon,
    required String tooltip,
    VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
  }

  static Widget actions(BuildContext context, List<Widget> children) {
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  static TextStyle pageIndicatorStyle(BuildContext context) =>
      ClearGlassForeground.title(context).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      );
}
