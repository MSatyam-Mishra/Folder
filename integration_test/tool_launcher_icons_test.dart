import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/app_shortcuts.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/core/theme/icon_strokes.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// Draws each tool's icon for the app drawer into Android's resources, as a
/// launcher can't take a picture drawn at run time for a manifest entry. Run it
/// again after changing a tool, from a checkout, with the real fonts:
/// `flutter test integration_test/tool_launcher_icons_test.dart -d windows`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tools have an icon for the app drawer', (tester) async {
    await tester.runAsync(() async {
      await IconStrokes.useLight();
      final settings = AppThemeSettings.defaults().copyWith(style: AppStyle.standard);
      final colors = AppTheme.gradientOf(AppTheme.shad(settings, Brightness.light).colorScheme.primary);
      final res = p.join('android', 'app', 'src', 'main', 'res', 'mipmap-xxxhdpi');
      for (final tool in Tool.values) {
        final name = 'ic_tool_${tool.id}';
        // The whole layer of an adaptive icon (108 dp), and for phones before those a tile (48 dp).
        await File(p.join(res, '${name}_foreground.png'))
            .writeAsBytes(await AppShortcuts.drawIcon(tool.icon, colors: colors, fullBleed: true, size: 432));
        await File(p.join(res, '$name.png')).writeAsBytes(await AppShortcuts.drawIcon(tool.icon, colors: colors, size: 192));
      }
    });
  });
}
