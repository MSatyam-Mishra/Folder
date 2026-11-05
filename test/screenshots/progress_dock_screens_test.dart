import 'package:folder/shared/widgets/progress_dock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  setUpAll(() async {
    if (screenshotsEnabled) await loadAppFonts();
  });

  testWidgets('progress dock: shown, hidden, hovered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    setScreenSize(tester, const Size(900, 560));
    await tester.pumpWidget(
      screenshotFrame(
        themedApp(
          const Scaffold(
            body: Stack(
              children: [
                ProgressDock(
                  fileTask: DockTask(
                    title: 'Copying 12 items',
                    message: 'Holiday 2026/IMG_2041.jpg',
                    progress: 0.62,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await saveScreenshot(tester, 'progress_dock_shown');

    await tester.tap(find.byTooltip('Hide'));
    await tester.pump();
    await saveScreenshot(tester, 'progress_dock_hidden');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byTooltip('1 task running')));
    await tester.pump();
    await saveScreenshot(tester, 'progress_dock_hovered');
    await mouse.removePointer();
  }, skip: !screenshotsEnabled);
}
