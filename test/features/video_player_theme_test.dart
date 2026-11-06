import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/theme/app_color_theme.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/features/video_player/video_library_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Someone who only uses the video player changes the app's look from its own
/// settings, the same choices as in Options.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Player settings change the theme, the colour and the style', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext page;
    await tester.pumpWidget(themedApp(Builder(builder: (context) {
      page = context;
      return const Scaffold(body: SizedBox());
    })));
    await settle(tester);
    final cubit = page.read<ThemeCubit>();

    final opening = showPlayerDefaults(page);
    await settle(tester);
    expect(find.text('Player settings'), findsOneWidget);

    await tester.ensureVisible(find.text('Dark'));
    await tester.tap(find.text('Dark'));
    await settle(tester);
    expect(cubit.state.themeMode, ThemeMode.dark);

    final other = AppColorThemes.all.firstWhere((spec) => spec.id != cubit.state.colorThemeId);
    await tester.ensureVisible(find.byTooltip(other.name));
    await tester.tap(find.byTooltip(other.name));
    await settle(tester);
    expect(cubit.state.colorThemeId, other.id);

    await tester.ensureVisible(find.text(AppStyle.dracula.label));
    await tester.tap(find.text(AppStyle.dracula.label));
    await settle(tester);
    expect(cubit.state.style, AppStyle.dracula);
    expect(find.text('${AppStyle.dracula.label} is a dark theme.'), findsOneWidget);
    expect(find.text('Color'), findsNothing, reason: 'Dracula brings its own colours');

    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await opening;
    await tester.pumpWidget(const SizedBox());
  });
}
