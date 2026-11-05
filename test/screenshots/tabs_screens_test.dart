import 'dart:io';

import 'package:folder/features/explorer_tabs/explorer_tabs.dart';
import 'package:folder/features/explorer_tabs/tabbed_explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/tabs_screens_test.dart
/// The tabs in the title bar, as on Windows.
void main() {
  late Directory root;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    root = Directory(p.join(Directory.systemTemp.path, 'Tabs shots', 'Projects'));
    if (await root.exists()) await root.delete(recursive: true);
    for (final d in ['Designs', 'Invoices', 'Photos 2026']) {
      await Directory(p.join(root.path, d)).create(recursive: true);
    }
    for (final name in ['Roadmap.pdf', 'Notes.md', 'Budget.xlsx', 'Logo.png']) {
      await File(p.join(root.path, name)).writeAsBytes(List.filled(24 * 1024, 120));
    }
    // The window buttons ask whether the window is maximized.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isMaximized' ? false : null,
    );
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await root.parent.delete(recursive: true);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('tabs ${mode.name}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      ExplorerTabs.instance.reset();
      TabbedExplorer.customTitleBar = true;
      addTearDown(() {
        TabbedExplorer.customTitleBar = false;
        ExplorerTabs.instance.reset();
      });
      setScreenSize(tester, const Size(1280, 800));
      await tester.pumpWidget(
        screenshotFrame(themedApp(TabbedExplorer(startFolder: root.path), themeMode: mode)),
      );
      ExplorerTabs.instance.open(p.join(root.path, 'Designs'), inBackground: true, atEnd: true);
      ExplorerTabs.instance.open(p.join(root.path, 'Invoices'), inBackground: true, atEnd: true);
      await settleUntil(tester, () => find.text('Roadmap.pdf').evaluate().isNotEmpty);
      await saveScreenshot(tester, 'tabs_${mode.name}_desktop');
    }, skip: !screenshotsEnabled);
  }
}

/// Lets real I/O finish until [done], then a few more frames (file stats).
Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
  Future<void> frame() async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  for (var i = 0; i < 40 && !done(); i++) {
    await frame();
  }
  for (var i = 0; i < 4; i++) {
    await frame();
  }
}
