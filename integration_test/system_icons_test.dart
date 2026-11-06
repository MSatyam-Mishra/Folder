import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/thumbnails/system_icons.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/shared/file_icons/place_icon.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/screenshots.dart';
import '../test/support/themed_app.dart';

/// On Windows: `flutter test integration_test/system_icons_test.dart -d windows`
/// The icons Windows itself shows, for the Windows style. Also writes
/// build/screenshots/system_icons_windows.png.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> decode(Uint8List bytes) async => (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image;

  /// Whether some pixels are see-through, as icons' corners are.
  Future<bool> seeThrough(ui.Image image) async {
    final pixels = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (var i = 3; i < pixels.lengthInBytes; i += 4) {
      if (pixels.getUint8(i) < 255) return true;
    }
    return false;
  }

  testWidgets('This PC, a drive, a library and a plain folder', (tester) async {
    await tester.runAsync(() async {
      final profile = Platform.environment['USERPROFILE']!;
      final plain = await Directory.systemTemp.createTemp('explorer_plain_folder');
      addTearDown(() => plain.delete());
      final byName = <String, Uint8List>{};
      for (final (name, path) in [
        ('This PC', ExplorerPaths.windowsRoots),
        ('drive', r'C:\'),
        ('Documents', p.join(profile, 'Documents')),
        ('Downloads', p.join(profile, 'Downloads')),
        ('plain', plain.path),
      ]) {
        final bytes = await SystemIcons.load(path, 48);
        expect(bytes, isNotNull, reason: '$name: no icon');
        final image = await decode(bytes!);
        expect(image.width, 48, reason: name);
        expect(await seeThrough(image), isTrue, reason: '$name: an icon, not a picture');
        byName[name] = bytes;
      }
      // Each its own, except plain folders, which share one.
      expect(byName.values.toSet(), hasLength(byName.length));
      expect(SystemIcons.known(p.join(plain.path, 'another'), 48), same(byName['plain']));
    });
  }, skip: !Platform.isWindows);

  testWidgets('the Windows style shows them', (tester) async {
    SharedPreferences.setMockInitialValues({'app_style': AppStyle.windows.name, 'theme_mode': 'light'});
    final root = await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('explorer_style');
      for (final name in ['Designs', 'Invoices', 'Photos 2026']) {
        await Directory(p.join(dir.path, name)).create();
      }
      return dir;
    });
    addTearDown(() => root!.delete(recursive: true));
    ExplorerTabs.instance.reset();
    await tester.pumpWidget(
      screenshotFrame(themedApp(TabbedExplorer(startFolder: root!.path), style: AppStyle.windows)),
    );
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Designs'), findsOneWidget);
    expect(find.byType(SystemIcon), findsWidgets);
    await saveScreenshot(tester, 'system_icons_windows');
  }, skip: !Platform.isWindows);
}
