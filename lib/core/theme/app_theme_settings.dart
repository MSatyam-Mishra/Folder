import 'package:explorer/core/platform/window_effects.dart';
import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/shared/file_icons/file_icon_style.dart';
import 'package:flutter/material.dart';

/// User-facing theme configuration (style, light/dark/system, colours,
/// icons).
class AppThemeSettings {
  const AppThemeSettings({
    required this.themeMode,
    required this.colorThemeId,
    this.fileIconStyle = FileIconStyle.solid,
    this.backdrop = WindowBackdrop.off,
    this.transparency = 0.5,
    this.style = AppStyle.standard,
  });

  final ThemeMode themeMode;
  final String colorThemeId;
  final FileIconStyle fileIconStyle;

  /// What shows behind the window on computers (Mica, Acrylic,
  /// vibrancy...); see WindowEffects.
  final WindowBackdrop backdrop;

  /// How see-through the app's backgrounds are over [backdrop], 0 (solid)
  /// to 1 (clear).
  final double transparency;

  bool get windowEffect => backdrop != WindowBackdrop.off;

  /// The overall look: the app's own, or macOS, Windows, Sweet, Dracula.
  final AppStyle style;

  /// Light, dark or the system's: Sweet and Dracula are always dark.
  ThemeMode get effectiveThemeMode => style.darkOnly ? ThemeMode.dark : themeMode;

  AppColorThemeSpec get colorTheme => AppColorThemes.byId(colorThemeId);

  AppThemeSettings copyWith({
    ThemeMode? themeMode,
    String? colorThemeId,
    FileIconStyle? fileIconStyle,
    WindowBackdrop? backdrop,
    double? transparency,
    AppStyle? style,
  }) {
    return AppThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      colorThemeId: colorThemeId ?? this.colorThemeId,
      fileIconStyle: fileIconStyle ?? this.fileIconStyle,
      backdrop: backdrop ?? this.backdrop,
      transparency: transparency ?? this.transparency,
      style: style ?? this.style,
    );
  }

  static AppThemeSettings defaults() => const AppThemeSettings(
        themeMode: ThemeMode.system,
        colorThemeId: AppColorThemes.defaultId,
      );
}
