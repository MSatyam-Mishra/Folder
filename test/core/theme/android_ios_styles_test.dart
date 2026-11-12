import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/theme/app_color_theme.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/core/theme/icon_strokes.dart';
import 'package:folders/core/theme/ios_style.dart';
import 'package:folders/core/theme/material_style.dart';
import 'package:folders/core/theme/style_restart.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/file_icons/style_file_art.dart';
import 'package:folders/shared/ui/app_glass.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/shared/widgets/explorer_options_sheet.dart';
import 'package:folders/shared/widgets/theme_choices.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/themed_app.dart';

/// The Android (Material 3 Expressive) and iOS (Liquid glass) styles.
void main() {
  ThemeData materialFor(AppStyle style, Brightness brightness, {String color = 'blue'}) {
    final settings = AppThemeSettings.defaults().copyWith(style: style, colorThemeId: color);
    final shad = AppTheme.shad(settings, brightness);
    return AppTheme.material(ThemeData(brightness: shad.brightness), shad, style: style);
  }

  test('Android\'s colours grow from the Color picked, as tonal Material roles', () {
    for (final brightness in Brightness.values) {
      final green = AppStyle.android.schemeFor(brightness, color: AppColorThemes.byId('green'))!;
      final blue = AppStyle.android.schemeFor(brightness, color: AppColorThemes.byId('blue'))!;
      expect(green.primary, isNot(blue.primary));
      final m3 = MaterialStyle.scheme(AppColorThemes.byId('green'), brightness);
      expect(green.primary, m3.primary);
      expect(green.accent, m3.secondaryContainer, reason: 'a selection is the secondary container');
      // The Material theme finds the same scheme from its primary colour.
      expect(MaterialStyle.fromPrimary(m3.primary, brightness), same(m3));
      expect(HSLColor.fromColor(green.primary).hue, inInclusiveRange(80, 170), reason: 'green stays green');
    }
    // The neutral colours give greys.
    final zinc = MaterialStyle.scheme(AppColorThemes.byId('zinc'), Brightness.light);
    expect(HSLColor.fromColor(zinc.primary).saturation, lessThan(0.1));
    expect(AppStyle.android.takesColor, isTrue);
    expect(AppStyle.ios.takesColor, isFalse);
    expect(AppStyle.android.darkOnly || AppStyle.ios.darkOnly, isFalse);
  });

  test('Android\'s theme: tonal containers, pills, large rounded surfaces, a big rounded-square button', () {
    final theme = materialFor(AppStyle.android, Brightness.light);
    final m3 = MaterialStyle.fromPrimary(theme.colorScheme.primary, Brightness.light);
    expect(theme.colorScheme.primaryContainer, m3.primaryContainer);
    expect(theme.colorScheme.surfaceContainerHigh, m3.surfaceContainerHigh);
    expect(theme.filledButtonTheme.style!.shape!.resolve({}), isA<StadiumBorder>());
    expect(theme.segmentedButtonTheme.style!.shape!.resolve({}), isA<StadiumBorder>());
    expect(theme.chipTheme.shape, isA<StadiumBorder>());
    expect(theme.listTileTheme.shape, isA<StadiumBorder>());
    final dialog = theme.dialogTheme.shape! as RoundedRectangleBorder;
    expect(dialog.borderRadius, BorderRadius.circular(28));
    final fab = theme.floatingActionButtonTheme;
    expect(fab.sizeConstraints!.minWidth, 80);
    expect(fab.backgroundColor, m3.primaryContainer);
    expect(theme.sliderTheme.thumbShape, isA<HandleThumbShape>(), reason: 'the 2024 slider');
    expect(theme.textTheme.titleLarge!.fontWeight, FontWeight.w700);
    final look = theme.extension<AppLook>()!;
    expect(look.style, AppStyle.android);
    expect(look.folderArt, FolderArt.material);
    expect(look.fileArt, FileArt.material);
    expect(look.itemRadius, greaterThanOrEqualTo(20), reason: 'pill-shaped selections');
  });

  test('iOS\'s colours, separators, switches and round selection marks', () {
    final light = AppTheme.shad(AppThemeSettings.defaults().copyWith(style: AppStyle.ios), Brightness.light).colorScheme;
    expect(light.primary, const Color(0xFF007AFF));
    // The page and the panes are glass over the Liquid wallpaper: iOS's
    // colours, see-through.
    expect(light.muted.withValues(alpha: 1), const Color(0xFFF2F2F7));
    expect(light.muted.a, lessThan(1));
    expect(light.background.a, lessThan(1));
    expect(light.card, const Color(0xFFFFFFFF));
    final dark = AppTheme.shad(AppThemeSettings.defaults().copyWith(style: AppStyle.ios), Brightness.dark).colorScheme;
    expect(dark.primary, const Color(0xFF0A84FF));
    expect(dark.background.withValues(alpha: 1), const Color(0xFF000000));
    expect(dark.background.a, lessThan(1));
    expect(dark.card, const Color(0xFF1C1C1E));
    final theme = materialFor(AppStyle.ios, Brightness.light);
    expect(theme.dividerTheme.thickness, 0.5);
    expect(theme.switchTheme.trackColor!.resolve({WidgetState.selected}), IosStyle.green);
    expect(theme.checkboxTheme.shape, isA<CircleBorder>());
    expect(theme.dialogTheme.backgroundColor, IosStyle.groupedBackground(false));
    final look = theme.extension<AppLook>()!;
    expect(look.groupedLists, isTrue);
    expect(look.folderArt, FolderArt.files);
    expect(AppStyle.ios.glass, isTrue);
    expect(AppStyle.android.glass, isFalse);
  });

  for (final (style, glass) in [(AppStyle.ios, true), (AppStyle.android, false)]) {
    testWidgets('glass: always in the iOS style, never in the Android style (${style.label})', (tester) async {
      SharedPreferences.setMockInitialValues({'app_style': style.name});
      late BuildContext context;
      await tester.pumpWidget(themedApp(Builder(builder: (c) {
        context = c;
        return const SizedBox();
      }), style: style));
      // The cubit is made when first asked for, then reads what's saved.
      context.read<ThemeCubit>();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(AppGlass.isLiquid(context), glass);
    });
  }

  testWidgets('Android and iOS draw their own folders and files; logos stay', (tester) async {
    SharedPreferences.setMockInitialValues({'app_style': AppStyle.android.name});
    await tester.pumpWidget(themedApp(
      const Column(children: [
        FileIcon(path: 'Report.pdf'),
        FileIcon(path: 'main.dart'),
        FolderIcon(),
      ]),
      style: AppStyle.android,
    ));
    expect(find.byType(StyleFileArt), findsOneWidget, reason: 'the PDF; main.dart keeps its logo');
    expect(
      find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MaterialFolderPainter),
      findsOneWidget,
    );
  });

  testWidgets('a style with other icons offers a restart; one with the same doesn\'t', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await IconStrokes.use(IconSet.lucide);
    final launched = <List<String>>[];
    final launcher = Desktop.launcher;
    final close = StyleRestart.closeWindow;
    var closed = 0;
    Desktop.launcher = (executable, args) async => launched.add(args);
    StyleRestart.closeWindow = () async => closed++;
    addTearDown(() {
      Desktop.launcher = launcher;
      StyleRestart.closeWindow = close;
    });
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(
      Scaffold(body: SingleChildScrollView(child: ThemeChoices(heading: (label) => Text(label)))),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.textContaining('starts'), findsNothing);

    await tester.tap(find.text('Android'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    if (StyleRestart.supported) {
      expect(find.text("Android's icons show once Folders starts again."), findsOneWidget);
      await tester.tap(find.text('Restart'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(launched, hasLength(1), reason: 'a new window');
      expect(closed, 1, reason: 'then this one closes');
    } else {
      expect(find.text("Android's icons show the next time Folders starts."), findsOneWidget);
    }
    // The Color picked still applies to Android's style.
    expect(find.byTooltip('Green'), findsOneWidget);

    await tester.tap(find.text('macOS'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.textContaining('starts'), findsNothing);
  });

  for (final style in [AppStyle.ios, AppStyle.windows]) {
    testWidgets('Options in the ${style.label} style', (tester) async {
      SharedPreferences.setMockInitialValues({'app_style': style.name});
      tester.view.physicalSize = const Size(600, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(
        Scaffold(
          body: SingleChildScrollView(
            child: ExplorerOptionsSheet(
              fileState: FileExplorerLoaded(entities: const [], path: Directory.systemTemp.path),
              onHttpShare: () {},
              onSortChanged: (_, _) {},
              onViewModeChanged: (_) {},
              onShowHiddenChanged: () {},
            ),
          ),
        ),
        style: style,
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      if (style == AppStyle.ios) {
        // iOS's switches, section titles in capitals, its own file icons.
        expect(find.byType(CupertinoSwitch), findsWidgets);
        expect(find.byType(SwitchListTile), findsNothing);
        expect(find.text('LAYOUT'), findsOneWidget);
        expect(find.text('The iOS style draws its own file icons.'), findsOneWidget);
      } else {
        // The other styles as they were.
        expect(find.byType(CupertinoSwitch), findsNothing);
        expect(find.byType(SwitchListTile), findsWidgets);
        expect(find.text('Layout'), findsOneWidget);
        expect(find.text('Solid'), findsOneWidget);
      }
    });
  }
}
