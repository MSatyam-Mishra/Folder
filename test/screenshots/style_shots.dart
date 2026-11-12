import 'dart:io';

import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// Screenshots of one style with its own icons, on a computer and a phone, in
/// light and dark: the window with its tabs, Options, a menu, the phone's
/// list and grid, its menu, Options and a dialog. Each style with icons of
/// its own has its own test file, as a font can't be swapped once loaded.
void styleShots(AppStyle style) {
  late Directory root;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts(icons: style.iconSet);
    root = Directory(p.join(Directory.systemTemp.path, '${style.label} shots', 'Projects'));
    if (await root.exists()) await root.delete(recursive: true);
    for (final d in ['Designs', 'Documents', 'Downloads', 'Invoices', 'Music', 'Photos 2026']) {
      await Directory(p.join(root.path, d)).create(recursive: true);
    }
    const files = {
      'Roadmap.pdf': 184, 'Notes.md': 3, 'Budget.xlsx': 46, 'Pitch deck.pptx': 1240, 'Logo.png': 24,
      'Song.mp3': 2100, 'Trailer.mp4': 3900, 'Backup.zip': 640, 'Letter.docx': 32, 'main.dart': 6,
      'Data.bin': 12,
    };
    for (final MapEntry(key: name, value: kb) in files.entries) {
      await File(p.join(root.path, name)).writeAsBytes(List.filled(kb * 1024, 120));
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

  final name = style.name;

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('$name desktop ${mode.name}', (tester) async {
      SharedPreferences.setMockInitialValues({'app_style': style.name, 'theme_mode': mode.name});
      ExplorerTabs.instance.reset();
      TabbedExplorer.customTitleBar = true;
      addTearDown(() {
        TabbedExplorer.customTitleBar = false;
        ExplorerTabs.instance.reset();
      });
      setScreenSize(tester, const Size(1280, 800));
      debugDisableShadows = false;
      await tester.pumpWidget(
        screenshotFrame(themedApp(TabbedExplorer(startFolder: root.path), themeMode: mode, style: style)),
      );
      ExplorerTabs.instance.open(p.join(root.path, 'Designs'), inBackground: true, atEnd: true);
      for (var i = 0; i < 40 && find.text('Backup.zip').evaluate().isEmpty; i++) {
        await frames(tester, count: 1);
      }
      await frames(tester);
      await tester.tap(find.text('Invoices'), kind: PointerDeviceKind.mouse);
      await frames(tester, count: 2);
      await saveScreenshot(tester, 'style_${name}_${mode.name}');

      // The grid.
      BlocProvider.of<FileExplorerBloc>(tester.element(find.text('Backup.zip'))).add(ChangeViewMode(ViewMode.grid));
      await frames(tester);
      await saveScreenshot(tester, 'style_${name}_grid_${mode.name}');
      BlocProvider.of<FileExplorerBloc>(tester.element(find.text('Backup.zip'))).add(ChangeViewMode(ViewMode.list));
      await frames(tester);

      // A menu.
      await tester.tap(find.text('Designs').last, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await frames(tester, count: 8);
      await saveScreenshot(tester, 'style_${name}_menu_${mode.name}');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames(tester);

      // Options, at the top and further down.
      await tester.tap(find.byTooltip('Options'));
      await frames(tester, count: 6);
      await saveScreenshot(tester, 'style_${name}_options_${mode.name}');
      await tester.drag(find.text('Options').last, const Offset(0, -700));
      await frames(tester, count: 4);
      await saveScreenshot(tester, 'style_${name}_options_more_${mode.name}');
      debugDisableShadows = true;
    }, skip: !screenshotsEnabled);

    testWidgets('$name phone ${mode.name}', (tester) async {
      SharedPreferences.setMockInitialValues({'app_style': style.name, 'theme_mode': mode.name});
      setScreenSize(tester, const Size(390, 844), pixelRatio: 2.5);
      debugDisableShadows = false;
      await tester.pumpWidget(screenshotFrame(themedApp(const FileExplorerScreen(), themeMode: mode, style: style)));
      await frames(tester);
      final context = tester.element(find.byType(Scaffold).first);
      final bloc = BlocProvider.of<FileExplorerBloc>(context);
      bloc.add(LoadDirectory(root.path));
      for (var i = 0; i < 40 && find.text('Backup.zip').evaluate().isEmpty; i++) {
        await frames(tester, count: 1);
      }
      await frames(tester);
      await saveScreenshot(tester, 'style_${name}_phone_${mode.name}');

      bloc.add(ChangeViewMode(ViewMode.grid));
      await frames(tester);
      await saveScreenshot(tester, 'style_${name}_phone_grid_${mode.name}');
      bloc.add(ChangeViewMode(ViewMode.list));
      await frames(tester);

      await tester.tap(find.byTooltip('Open menu').first);
      await frames(tester, count: 6);
      await saveScreenshot(tester, 'style_${name}_phone_drawer_${mode.name}');
      Navigator.of(tester.element(find.byType(Drawer))).pop();
      await frames(tester);

      await tester.tap(find.byTooltip('Options').first);
      await frames(tester, count: 6);
      await saveScreenshot(tester, 'style_${name}_phone_options_${mode.name}');
      Navigator.of(tester.element(find.byType(Scaffold).first)).pop();
      await frames(tester);

      // A dialog.
      showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Delete "Roadmap.pdf"?'),
          content: const Text('It goes for good: there is no Recycle Bin here.'),
          actions: [
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(onPressed: () {}, child: const Text('Delete')),
          ],
        ),
      );
      await frames(tester, count: 4);
      await saveScreenshot(tester, 'style_${name}_phone_dialog_${mode.name}');
      debugDisableShadows = true;
    }, skip: !screenshotsEnabled);
  }
}
