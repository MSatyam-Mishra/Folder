import 'package:folder/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Interface icons: Lucide, the icon set of shadcn/ui.
abstract final class AppIcons {
  static const double sm = AppTheme.iconSize;
  static const double md = 22;

  static Widget icon(IconData icon, {double? size, Color? color}) =>
      Icon(icon, size: size ?? sm, color: color);

  static Widget back({Color? color}) =>
      icon(LucideIcons.arrowLeft, color: color);

  static Widget cancel({Color? color}) => icon(LucideIcons.x, color: color);

  static Widget archive({Color? color}) =>
      icon(LucideIcons.archive, color: color);

  static Widget delete({Color? color}) =>
      icon(LucideIcons.trash2, color: color);

  static Widget globe({Color? color}) => icon(LucideIcons.globe, color: color);

  static Widget grid({Color? color}) =>
      icon(LucideIcons.layoutGrid, color: color);

  static Widget sort({Color? color}) =>
      icon(LucideIcons.arrowUpDown, color: color);

  /// Drawer menu.
  static Widget drawerMenu({Color? color}) =>
      icon(LucideIcons.panelLeft, color: color);

  /// Options (more) menu.
  static Widget optionsMenu({Color? color}) =>
      icon(LucideIcons.ellipsisVertical, color: color);

  @Deprecated('Use drawerMenu or optionsMenu')
  static Widget menu({Color? color}) => optionsMenu(color: color);

  static Widget clipboard({Color? color}) =>
      icon(LucideIcons.clipboardList, color: color);

  static Widget sun({Color? color}) => icon(LucideIcons.sun, color: color);

  static Widget moon({Color? color}) => icon(LucideIcons.moon, color: color);

  static Widget listView({Color? color}) =>
      icon(LucideIcons.list, color: color);

  static Widget check({Color? color, double? size}) =>
      icon(LucideIcons.check, color: color, size: size ?? 18);

  static Widget bookmark({Color? color}) =>
      icon(LucideIcons.bookmark, color: color);
}
