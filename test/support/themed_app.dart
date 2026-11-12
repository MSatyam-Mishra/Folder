import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/shared/ui/app_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// [home] inside the app's real theme setup (shadcn/ui + Material bridge),
/// for widget and screenshot tests. Call SharedPreferences.setMockInitialValues
/// first: [ThemeCubit] reads saved settings.
Widget themedApp(
  Widget home, {
  ThemeMode themeMode = ThemeMode.light,
  String colorScheme = 'blue',
  AppStyle style = AppStyle.standard,
}) {
  final settings = AppThemeSettings.defaults()
      .copyWith(themeMode: themeMode, colorThemeId: colorScheme, style: style);
  return BlocProvider(
    create: (_) => ThemeCubit(),
    child: ShadApp.custom(
      themeMode: settings.effectiveThemeMode,
      theme: AppTheme.shad(settings, Brightness.light),
      darkTheme: AppTheme.shad(settings, Brightness.dark),
      appBuilder: (context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.material(Theme.of(context), ShadTheme.of(context), style: style),
        localizationsDelegates: const [
          GlobalShadLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        // As main.dart: iOS's pages are glass over the Liquid wallpaper.
        builder: (context, child) => style.glass
            ? ShadAppBuilder(backgroundColor: Colors.transparent, child: LiquidWallpaper(child: child!))
            : ShadAppBuilder(child: child!),
        home: home,
      ),
    ),
  );
}
