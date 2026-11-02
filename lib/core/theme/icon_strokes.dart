import 'package:flutter/services.dart';

/// The app's icons: Hi-icons where the pack has one, Lucide with lighter lines
/// for the others and for folders and files (`tool/icons/build_icon_font.py`).
abstract final class IconStrokes {
  /// Loaded under Lucide's font name, it takes that font's place for every
  /// icon in the app (fonts loaded while running come before the bundled
  /// ones), so `LucideIcons.x` is all the code ever says.
  static Future<void> useLight() async {
    final loader = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(rootBundle.load('assets/fonts/app_icons.ttf'));
    await loader.load();
  }
}
