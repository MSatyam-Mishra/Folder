import 'dart:io';

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/core/theme/icon_strokes.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/explorer_tabs/tabbed_explorer.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/screenshots.dart';
import '../test/support/themed_app.dart';

/// On a computer: `flutter test integration_test/glass_test.dart -d windows`
/// With the window effect on, menus and sheets are blurred and see-through.
/// Also writes build/screenshots/glass_*.png (This PC, a category, a menu,
/// Options).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('menus and sheets on glass; This PC and a category', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // As main() does: the app's icon font.
    await tester.runAsync(IconStrokes.useLight);
    final root = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('explorer_glass');
      final picture = img.Image(width: 320, height: 200);
      img.fill(picture, color: img.ColorRgb8(30, 120, 220));
      for (final name in ['Beach.png', 'Mountains.png', 'City at night.png', 'Forest.png']) {
        await File(p.join(dir.path, name)).writeAsBytes(img.encodePng(picture));
      }
      return dir;
    }))!;
    addTearDown(() => root.delete(recursive: true));
    final real = LocalFileRepository.categoryFiles;
    addTearDown(() => LocalFileRepository.categoryFiles = real);
    LocalFileRepository.categoryFiles = (_) async => root.listSync();
    ExplorerTabs.instance.reset();

    Future<void> rounds([int count = 12]) async {
      for (var i = 0; i < count; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(
      screenshotFrame(themedApp(const TabbedExplorer(startFolder: ExplorerPaths.windowsRoots))),
    );
    await rounds(20);
    await saveScreenshot(tester, 'glass_this_pc');

    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    bloc.add(LoadDirectory(ExplorerPaths.categoryPath('Photos')));
    await rounds();
    expect(find.text('New folder'), findsNothing);
    await saveScreenshot(tester, 'glass_category');

    await tester.tap(find.text('Beach.png'), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await rounds(4);
    expect(find.byType(GlassSurface), findsOneWidget, reason: 'the menu');
    await saveScreenshot(tester, 'glass_menu');
    await tester.tapAt(const Offset(900, 500));
    await rounds(4);

    await tester.tap(find.byTooltip('Options'));
    await rounds(6);
    await saveScreenshot(tester, 'glass_options');
    expect(find.byType(GlassSurface), findsOneWidget, reason: 'the sheet');
    expect(tester.takeException(), isNull);
  });
}
