import 'package:explorer/core/platform/window_effects.dart';
import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/shared/file_icons/file_icon_style.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class ThemePreferences {
  static const _keyThemeMode = 'theme_mode';
  static const _keyColorThemeId = 'color_theme_id';
  static const _keyFileIconStyle = 'file_icon_style';
  // Up to 1.0.8: only on or off.
  static const _keyWindowEffect = 'window_effect';
  static const _keyBackdrop = 'window_backdrop';
  static const _keyTransparency = 'window_transparency';
  static const _keyStyle = 'app_style';
  static const _keyThumbnails = 'show_thumbnails';

  static Future<AppThemeSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppThemeSettings(
      themeMode: _parseThemeMode(prefs.getString(_keyThemeMode)),
      colorThemeId: AppColorThemes.migrate(prefs.getString(_keyColorThemeId)),
      fileIconStyle: FileIconStyle.parse(prefs.getString(_keyFileIconStyle)),
      backdrop: prefs.getBool(_keyWindowEffect) == false && prefs.getString(_keyBackdrop) == null
          ? WindowBackdrop.off
          : WindowBackdrop.parse(prefs.getString(_keyBackdrop)),
      transparency: (prefs.getDouble(_keyTransparency) ?? WindowBackdrop.standardTransparency).clamp(0.0, 1.0),
      style: AppStyle.parse(prefs.getString(_keyStyle)),
      showThumbnails: prefs.getBool(_keyThumbnails) ?? true,
    );
  }

  static Future<void> save(AppThemeSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, settings.themeMode.name);
    await prefs.setString(_keyColorThemeId, settings.colorThemeId);
    await prefs.setString(_keyFileIconStyle, settings.fileIconStyle.name);
    await prefs.setString(_keyBackdrop, settings.backdrop.name);
    await prefs.setDouble(_keyTransparency, settings.transparency);
    await prefs.setString(_keyStyle, settings.style.name);
    await prefs.setBool(_keyThumbnails, settings.showThumbnails);
  }

  static ThemeMode _parseThemeMode(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
