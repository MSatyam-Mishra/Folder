import 'dart:math' as math;

import 'package:folders/shared/ui/app_glass.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// How a sheet appears on computers and wide screens, where bottom sheets
/// look out of place: a centred [dialog] (choices, short forms) or a
/// [side] sheet from the right (details, settings). Phones keep the bottom
/// sheet.
enum SheetStyle { dialog, side }

/// Bottom sheet with the app's sheet styling (drag handle, rounded top,
/// border; see the bottomSheetTheme in AppTheme) and scrolling content, or
/// on computers and wide screens a dialog or side sheet ([SheetStyle]).
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.child,
    this.maxHeightFraction = 0.85,
    // Kept for callers of the previous glass sheet; unused.
    this.horizontalMargin,
    this.bottomMargin,
    this.cornerRadius,
  });

  final Widget child;
  final double maxHeightFraction;
  final double? horizontalMargin;
  final double? bottomMargin;
  final double? cornerRadius;

  /// Whether sheets come up from the bottom here: phones and narrow
  /// windows on touch devices.
  static bool usesBottomSheet(BuildContext context) =>
      !const {TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS}
          .contains(defaultTargetPlatform) &&
      MediaQuery.sizeOf(context).width < 720;

  static Future<T?> show<T>(
    BuildContext context, {
    required Widget child,
    double maxHeightFraction = 0.85,
    SheetStyle style = SheetStyle.dialog,
  }) {
    if (!usesBottomSheet(context)) {
      return showRaw<T>(
        context,
        style: style,
        builder: (_) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: child,
        ),
      );
    }
    final liquid = AppGlass.isLiquid(context);
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: liquid ? Colors.transparent : null,
      elevation: liquid ? 0 : null,
      // The glass has its own edge; the theme's would show as a second one.
      shape: liquid ? const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))) : null,
      showDragHandle: liquid ? false : null,
      barrierColor: liquid ? Colors.black.withValues(alpha: 0.2) : null,
      builder: (sheet) {
        final content = AppSheet(maxHeightFraction: maxHeightFraction, child: child);
        if (!liquid) return content;
        // The handle goes on the glass, which the sheet's own would be beside.
        final colors = Theme.of(sheet).colorScheme;
        return LiquidGlass(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          // The sheet's own colour (iOS: its grouped grey).
          tint: Theme.of(sheet).bottomSheetTheme.backgroundColor,
          opacity: 0.72,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Flexible(child: content),
            ],
          ),
        );
      },
    );
  }

  /// A dialog or side sheet holding [builder]'s content as it is (it
  /// scrolls itself, if needed); for content made for a bottom sheet,
  /// check [usesBottomSheet] first.
  static Future<T?> showRaw<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    SheetStyle style = SheetStyle.dialog,
  }) {
    // With the window effect on, a lighter shade behind and a blurred,
    // see-through surface like the window's.
    final glass = AppGlass.isOn(context);
    final barrier = Colors.black.withValues(alpha: glass ? 0.15 : 0.35);
    if (style == SheetStyle.dialog) {
      return showDialog<T>(
        context: context,
        barrierColor: glass ? barrier : null,
        builder: (dialog) {
          final size = MediaQuery.sizeOf(dialog);
          final theme = Theme.of(dialog);
          final content = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 560, maxHeight: size.height * 0.85),
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: builder(dialog),
            ),
          );
          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            clipBehavior: Clip.antiAlias,
            backgroundColor: glass ? Colors.transparent : null,
            elevation: glass ? 0 : null,
            child: glass
                ? GlassSurface(
                    color: theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
                    child: content,
                  )
                : content,
          );
        },
      );
    }
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: barrier,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (sheet, _, _) => _SideSheet(child: Builder(builder: builder)),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: media.size.height * maxHeightFraction,
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + media.viewInsets.bottom + media.padding.bottom,
        ),
        child: child,
      ),
    );
  }
}

/// A rounded panel floating along the window's right edge, the full height,
/// with a close button.
class _SideSheet extends StatelessWidget {
  const _SideSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = math.min(460.0, MediaQuery.sizeOf(context).width * 0.9);
    final glass = AppGlass.isOn(context);
    final solid = theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
    final radius = BorderRadius.circular(24);
    final sheet = SizedBox(
      width: width,
      height: double.infinity,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: IconButton(
                  icon: const Icon(LucideIcons.x, size: 20),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.maybePop(context),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: glass ? Colors.transparent : solid,
          elevation: glass ? 0 : 8,
          shadowColor: Colors.black45,
          clipBehavior: Clip.antiAlias,
          // Liquid glass draws its own edge.
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: AppGlass.isLiquid(context) ? BorderSide.none : BorderSide(color: theme.dividerColor),
          ),
          child: glass ? GlassSurface(color: solid, borderRadius: radius, child: sheet) : sheet,
        ),
      ),
    );
  }
}
