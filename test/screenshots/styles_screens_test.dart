import 'dart:io';

import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/explorer_tabs/tabbed_explorer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/styles_screens_test.dart
/// The window in each style (Options > Style), with its tabs as on Windows.
void main() {
  late Directory root;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    root = Directory(p.join(Directory.systemTemp.path, 'Style shots', 'Projects'));
    if (await root.exists()) await root.delete(recursive: true);
    for (final d in ['Designs', 'Documents', 'Downloads', 'Invoices', 'Music', 'Photos 2026']) {
      await Directory(p.join(root.path, d)).create(recursive: true);
    }
    for (final name in ['Roadmap.pdf', 'Notes.md', 'Budget.xlsx', 'Logo.png', 'Song.mp3']) {
      await File(p.join(root.path, name)).writeAsBytes(List.filled(24 * 1024, 120));
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await root.parent.delete(recursive: true);
  });

  Future<void> frames(WidgetTester tester, {int count = 4}) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> window(WidgetTester tester, AppStyle style, ThemeMode mode) async {
    SharedPreferences.setMockInitialValues({'app_style': style.name, 'theme_mode': mode.name});
    ExplorerTabs.instance.reset();
    TabbedExplorer.customTitleBar = true;
    addTearDown(() {
      TabbedExplorer.customTitleBar = false;
      ExplorerTabs.instance.reset();
    });
    setScreenSize(tester, const Size(1280, 800));
    await tester.pumpWidget(
      screenshotFrame(themedApp(TabbedExplorer(startFolder: root.path), themeMode: mode, style: style)),
    );
    ExplorerTabs.instance.open(p.join(root.path, 'Designs'), inBackground: true, atEnd: true);
    for (var i = 0; i < 40 && find.text('Roadmap.pdf').evaluate().isEmpty; i++) {
      await frames(tester, count: 1);
    }
    await frames(tester);
    // A selected row, to show the style's selection.
    await tester.tap(find.text('Invoices'), kind: PointerDeviceKind.mouse);
    await frames(tester, count: 2);
  }

  for (final (style, mode) in [
    (AppStyle.standard, ThemeMode.light),
    (AppStyle.macos, ThemeMode.light),
    (AppStyle.macos, ThemeMode.dark),
    (AppStyle.windows, ThemeMode.light),
    (AppStyle.windows, ThemeMode.dark),
    (AppStyle.sweet, ThemeMode.dark),
    (AppStyle.dracula, ThemeMode.dark),
  ]) {
    testWidgets('style ${style.name} ${mode.name}', (tester) async {
      await window(tester, style, mode);
      await saveScreenshot(tester, 'style_${style.name}_${mode.name}');
    }, skip: !screenshotsEnabled);
  }

  testWidgets('style picker and a menu, Dracula', (tester) async {
    await window(tester, AppStyle.dracula, ThemeMode.dark);
    await tester.tap(find.text('Designs').last, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await frames(tester, count: 10);
    await saveScreenshot(tester, 'style_dracula_menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(tester);
    await tester.tap(find.byTooltip('Options'));
    await frames(tester, count: 6);
    await saveScreenshot(tester, 'style_dracula_options');
  }, skip: !screenshotsEnabled);
}
