import 'package:flutter/services.dart';

/// The app's icons (Lucide) with lighter lines.
abstract final class IconStrokes {
  /// Lucide draws 2 px lines at 24 px, heavy next to text. Its package also
  /// has the same icons drawn with 1.55 px lines; loaded under the default
  /// font's name, they take its place for every icon in the app (fonts
  /// loaded while running come before the bundled ones).
  static Future<void> useLight() async {
    final loader = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/build_font/LucideVariable-w300.ttf'));
    await loader.load();
  }
}
