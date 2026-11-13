import 'dart:io';

import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/pane_settings.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// Screenshots of dual pane and the preview pane in [styles] (one icon set
/// per test file: a font can't be swapped once loaded), written to
/// build/screenshots/panes_*.png. With [more], also a narrower window, the
/// View menu, a picture and several items selected.
void panesShots(List<AppStyle> styles, {bool more = false}) {
  late Directory root;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts(icons: styles.first.iconSet);
    // One folder per test file: they may run at the same time.
    root = Directory(p.join(Directory.systemTemp.path, 'Panes shots ${styles.first.name}', 'Projects'));
    if (await root.exists()) await root.delete(recursive: true);
    for (final d in ['Designs', 'Invoices', 'Photos 2026']) {
      await Directory(p.join(root.path, d)).create(recursive: true);
    }
    for (final name in ['Logo final.png', 'Banner.png', 'Icons.svg', 'Brief.pdf']) {
      await File(p.join(root.path, 'Designs', name)).writeAsBytes(List.filled(18 * 1024, 120));
    }
    await File(p.join(root.path, 'Notes.md')).writeAsString('''# Launch notes

- Ship the dual pane view to everyone on Monday
- Preview pane: pictures, PDFs, songs and text
- Check the Windows title bar with tabs

## Open questions

1. Should Tab move between panes? Yes, as in Total Commander.
2. Shift+F5 copies to the other pane, Shift+F6 moves.
''');
    const files = {'Roadmap.pdf': 184, 'Budget.xlsx': 46, 'Song.mp3': 2100, 'Backup.zip': 640, 'main.dart': 6};
    for (final MapEntry(key: name, value: kb) in files.entries) {
      await File(p.join(root.path, name)).writeAsBytes(List.filled(kb * 1024, 120));
    }
    // A colourful picture for the preview.
    final picture = img.Image(width: 480, height: 320);
    for (final pixel in picture) {
      final x = pixel.x / picture.width, y = pixel.y / picture.height;
      pixel.setRgb((40 + 200 * x).round(), (90 + 120 * y).round(), (230 - 150 * x * y).round());
    }
    await File(p.join(root.path, 'Sunset.png')).writeAsBytes(img.encodePng(picture));
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

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await frames(tester, count: 1);
    }
    await frames(tester);
  }

  Future<void> click(WidgetTester tester, Finder finder, {bool control = false}) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(finder, kind: PointerDeviceKind.mouse);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 320)));
    await frames(tester);
  }

  /// The window with two panes (the second one on Designs) and the preview.
  Future<DualPaneController> window(
    WidgetTester tester,
    AppStyle style,
    ThemeMode mode, {
    Size size = const Size(1600, 900),
    bool preview = true,
  }) async {
    SharedPreferences.setMockInitialValues({'app_style': style.name, 'theme_mode': mode.name});
    ExplorerTabs.instance.reset();
    PaneSettings.instance.reset();
    PaneSettings.instance.setPreview(preview);
    TabbedExplorer.customTitleBar = true;
    addTearDown(() {
      TabbedExplorer.customTitleBar = false;
      ExplorerTabs.instance.reset();
      PaneSettings.instance.reset();
    });
    setScreenSize(tester, size, pixelRatio: 1.5);
    debugDisableShadows = false;
    await tester.pumpWidget(
      screenshotFrame(themedApp(TabbedExplorer(startFolder: root.path), themeMode: mode, style: style)),
    );
    await until(tester, () => find.text('Backup.zip').evaluate().isNotEmpty);
    final panes = DualPanes.read(tester.element(find.text('Backup.zip')))!;
    panes.open();
    await until(tester, () => panes.second != null);
    panes.second!.add(LoadDirectory(p.join(root.path, 'Designs')));
    await until(tester, () => find.text('Brief.pdf').evaluate().isNotEmpty);
    return panes;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    debugDisableShadows = true;
  }

  for (final style in styles) {
    final modes = more ? [ThemeMode.light, ThemeMode.dark] : [ThemeMode.light];
    for (final mode in modes) {
      testWidgets('${style.name} dual pane with the preview, ${mode.name}', (tester) async {
        await window(tester, style, mode);
        await click(tester, find.text('Notes.md'));
        await until(tester, () => find.textContaining('Launch notes').evaluate().isNotEmpty);
        await saveScreenshot(tester, 'panes_${style.name}_${mode.name}');
        await close(tester);
      }, skip: !screenshotsEnabled);
    }

    if (!more) continue;

    testWidgets('${style.name} a picture in the preview', (tester) async {
      await window(tester, style, ThemeMode.light);
      await click(tester, find.text('Sunset.png'));
      await until(tester, () => find.text('480 × 320 pixels').evaluate().isNotEmpty);
      await saveScreenshot(tester, 'panes_${style.name}_picture');
      await close(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('${style.name} several selected, second pane active', (tester) async {
      final panes = await window(tester, style, ThemeMode.dark);
      await click(tester, find.text('Logo final.png'));
      await click(tester, find.text('Banner.png'), control: true);
      await click(tester, find.text('Icons.svg'), control: true);
      expect(panes.active, 1);
      await saveScreenshot(tester, 'panes_${style.name}_several');
      await close(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('${style.name} narrower window, View menu', (tester) async {
      await window(tester, style, ThemeMode.light, size: const Size(1280, 800), preview: false);
      await tester.tap(find.byTooltip('View').last, kind: PointerDeviceKind.mouse);
      await frames(tester);
      await saveScreenshot(tester, 'panes_${style.name}_menu');
      await close(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('${style.name} one pane with the preview', (tester) async {
      SharedPreferences.setMockInitialValues({'app_style': style.name});
      ExplorerTabs.instance.reset();
      PaneSettings.instance.reset();
      PaneSettings.instance.setPreview(true);
      TabbedExplorer.customTitleBar = true;
      addTearDown(() {
        TabbedExplorer.customTitleBar = false;
        ExplorerTabs.instance.reset();
        PaneSettings.instance.reset();
      });
      setScreenSize(tester, const Size(1280, 800), pixelRatio: 1.5);
      await tester.pumpWidget(screenshotFrame(themedApp(TabbedExplorer(startFolder: root.path), style: style)));
      await until(tester, () => find.text('Backup.zip').evaluate().isNotEmpty);
      await click(tester, find.text('Designs'));
      await until(tester, () => find.text('4 files').evaluate().isNotEmpty);
      await saveScreenshot(tester, 'panes_${style.name}_single');
      await close(tester);
    }, skip: !screenshotsEnabled);
  }
}
