import 'dart:io';

import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';
import 'explorer_screens_test.dart' show settle;

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
/// On computers sheets are side sheets or dialogs, and menus have icons.
void main() {
  late Directory root;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    root = await Directory.systemTemp.createTemp('desktop_sheets_');
    for (final d in ['Documents', 'Pictures']) {
      await Directory(p.join(root.path, d)).create();
    }
    await File(p.join(root.path, 'Quarterly report.pdf')).writeAsBytes(List.filled(184 * 1024, 1));
    await File(p.join(root.path, 'Holiday.jpg')).writeAsBytes(List.filled(870 * 1024, 1));
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await root.delete(recursive: true);
  });

  testWidgets('desktop: options side sheet, sort menu, properties', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    setScreenSize(tester, const Size(1280, 800), pixelRatio: 1);
    ExplorerPaths.startFolder = root.path;
    await tester.pumpWidget(screenshotFrame(themedApp(const FileExplorerScreen())));
    await settle(tester);
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    for (var i = 0; i < 30 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester, frames: 1);
    }
    await settle(tester);

    await tester.tap(find.byTooltip('Options'));
    await settle(tester);
    await saveScreenshot(tester, 'desktop_options_side_sheet');
    await tester.tap(find.byTooltip('Close'));
    await settle(tester);

    await tester.tap(find.byTooltip('Sort and group'));
    await settle(tester);
    await saveScreenshot(tester, 'desktop_sort_menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.tap(find.text('Holiday.jpg'), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await settle(tester);
    await saveScreenshot(tester, 'desktop_context_menu');
    await tester.tap(find.text('Properties'));
    await settle(tester);
    await saveScreenshot(tester, 'desktop_properties_side_sheet');

    ExplorerPaths.startFolder = null;
    debugDefaultTargetPlatformOverride = null;
  }, skip: !screenshotsEnabled);
}
