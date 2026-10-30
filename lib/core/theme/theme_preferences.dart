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
  static const _keyWindowEffect = 'window_effect';
  static const _keyStyle = 'app_style';

  static Future<AppThemeSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppThemeSettings(
      themeMode: _parseThemeMode(prefs.getString(_keyThemeMode)),
      colorThemeId: AppColorThemes.migrate(prefs.getString(_keyColorThemeId)),
      fileIconStyle: FileIconStyle.parse(prefs.getString(_keyFileIconStyle)),
      windowEffect: prefs.getBool(_keyWindowEffect) ?? true,
      style: AppStyle.parse(prefs.getString(_keyStyle)),
    );
  }

  static Future<void> save(AppThemeSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyThemeMode, settings.themeMode.name);
    await prefs.setString(_keyColorThemeId, settings.colorThemeId);
    await prefs.setString(_keyFileIconStyle, settings.fileIconStyle.name);
    await prefs.setBool(_keyWindowEffect, settings.windowEffect);
    await prefs.setString(_keyStyle, settings.style.name);
  }

  static ThemeMode _parseThemeMode(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
}
