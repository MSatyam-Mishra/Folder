import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/theme_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The styles in Options > Style: Explorer, macOS, Windows, Sweet, Dracula.
void main() {
  test('the style is saved and read back; unknown names are the default', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppThemeSettings.defaults().copyWith(style: AppStyle.dracula);
    await ThemePreferences.save(settings);
    expect((await ThemePreferences.load()).style, AppStyle.dracula);
    expect(AppStyle.parse('nope'), AppStyle.standard);
    expect(AppStyle.parse(null), AppStyle.standard);
  });

  test('Sweet and Dracula are always dark', () {
    final light = AppThemeSettings.defaults().copyWith(themeMode: ThemeMode.light);
    expect(light.copyWith(style: AppStyle.sweet).effectiveThemeMode, ThemeMode.dark);
    expect(light.copyWith(style: AppStyle.dracula).effectiveThemeMode, ThemeMode.dark);
    expect(light.copyWith(style: AppStyle.macos).effectiveThemeMode, ThemeMode.light);
    final shad = AppTheme.shad(light.copyWith(style: AppStyle.dracula), Brightness.light);
    expect(shad.brightness, Brightness.dark);
    expect(shad.colorScheme.background, const Color(0xFF282A36));
  });

  test('each style brings its colours; the app\'s own keeps the colour picked', () {
    final settings = AppThemeSettings.defaults().copyWith(colorThemeId: 'green');
    expect(
      AppTheme.shad(settings, Brightness.light).colorScheme.primary,
      ShadColorScheme.fromName('green').primary,
    );
    expect(
      AppTheme.shad(settings.copyWith(style: AppStyle.windows), Brightness.light).colorScheme.accent,
      const Color(0xFFCCE8FF),
      reason: 'File Explorer\'s selection blue',
    );
    expect(
      AppTheme.shad(settings.copyWith(style: AppStyle.macos), Brightness.dark).colorScheme.primary,
      const Color(0xFF0A84FF),
    );
  });

  test('colourful icons: the same icon, the same colour; fitting ones for actions', () {
    final dracula = AppStyle.dracula.look(Brightness.dark);
    const plain = Color(0xFF000000);
    expect(dracula.iconColor(LucideIcons.trash2, plain), const Color(0xFFFF5555));
    expect(dracula.iconColor(LucideIcons.download, plain), const Color(0xFF50FA7B));
    expect(dracula.iconColor(LucideIcons.wind, plain), dracula.iconColor(LucideIcons.wind, plain));
    expect(dracula.iconColor(LucideIcons.wind, plain), isNot(plain));
    expect(AppStyle.windows.look(Brightness.light).iconColor(LucideIcons.trash2, plain), plain);
    expect(AppStyle.standard.look(Brightness.light).folder, isNull, reason: 'the glass folder');
    expect(AppStyle.windows.look(Brightness.dark).folder, isNotNull);
  });
}
