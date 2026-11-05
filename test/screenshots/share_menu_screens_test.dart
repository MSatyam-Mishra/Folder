import 'dart:io';

import 'package:folder/core/services/file_action_service.dart';
import 'package:folder/features/file_explorere/widgets/explorer_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  setUpAll(() async {
    if (screenshotsEnabled) await loadAppFonts();
  });

  testWidgets('right-click menu with the Share submenu open', (tester) async {
    SharedPreferences.setMockInitialValues({});
    setScreenSize(tester, const Size(900, 560), pixelRatio: 1.5);
    await tester.pumpWidget(screenshotFrame(themedApp(
      Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => ExplorerMenu.showAt<Object>(
                context,
                const Offset(220, 90),
                items: [
                  ExplorerMenu.item(context, value: 'open', label: 'Open', icon: LucideIcons.fileInput, shortcut: 'Enter'),
                  ExplorerMenu.item(context, value: 'window', label: 'Open in new window', icon: LucideIcons.appWindow),
                  ExplorerMenu.divider(),
                  ExplorerMenu.item(context, value: 'copy', label: 'Copy', icon: LucideIcons.copy, shortcut: 'Ctrl+C'),
                  ExplorerMenu.item(context, value: 'cut', label: 'Cut', icon: LucideIcons.scissors, shortcut: 'Ctrl+X'),
                  ExplorerMenu.divider(),
                  FileActionsService().shareSubmenu(context, [File('report.pdf')], label: 'Share file'),
                  ExplorerMenu.item(context, value: 'props', label: 'Properties', icon: LucideIcons.info),
                ],
              ),
              child: const Text('menu'),
            ),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('menu'));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Share file')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await saveScreenshot(tester, 'share_submenu');
    await mouse.removePointer();
  }, skip: !screenshotsEnabled);
}
