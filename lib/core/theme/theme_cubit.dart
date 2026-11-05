import 'package:folder/core/platform/window_effects.dart';
import 'package:folder/core/theme/app_style.dart';
import 'package:folder/core/theme/app_theme_settings.dart';
import 'package:folder/core/theme/theme_preferences.dart';
import 'package:folder/shared/file_icons/file_icon_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class ThemeCubit extends Cubit<AppThemeSettings> {
  ThemeCubit() : super(AppThemeSettings.defaults()) {
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final saved = await ThemePreferences.load();
    emit(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final next = state.copyWith(themeMode: mode);
    emit(next);
    await ThemePreferences.save(next);
  }

  Future<void> toggleBrightness() async {
    final nextMode =
        state.themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await setThemeMode(nextMode);
  }

  Future<void> setFileIconStyle(FileIconStyle style) async {
    final next = state.copyWith(fileIconStyle: style);
    emit(next);
    await ThemePreferences.save(next);
  }

  Future<void> setBackdrop(WindowBackdrop backdrop) async {
    final next = state.copyWith(backdrop: backdrop);
    emit(next);
    await ThemePreferences.save(next);
  }

  /// Shown while a slider moves; saved when [save] (the slider let go).
  Future<void> setTransparency(double value, {bool save = true}) async {
    final next = state.copyWith(transparency: value.clamp(0.0, 1.0));
    emit(next);
    if (save) await ThemePreferences.save(next);
  }

  Future<void> setShowThumbnails(bool show) async {
    final next = state.copyWith(showThumbnails: show);
    emit(next);
    await ThemePreferences.save(next);
  }

  Future<void> setLiquidGlass(bool on) async {
    final next = state.copyWith(liquidGlass: on);
    emit(next);
    await ThemePreferences.save(next);
  }

  Future<void> setStyle(AppStyle style) async {
    final next = state.copyWith(style: style);
    emit(next);
    await ThemePreferences.save(next);
  }

  Future<void> setColorTheme(String colorThemeId) async {
    final next = state.copyWith(colorThemeId: colorThemeId);
    emit(next);
    await ThemePreferences.save(next);
  }
}
