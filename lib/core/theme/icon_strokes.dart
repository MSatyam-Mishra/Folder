import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/theme_preferences.dart';
import 'package:flutter/services.dart';

/// The app's icons: Hi-icons where the pack has one, Lucide with lighter lines
/// for the others and for folders and files (`tool/icons/build_icon_font.py`);
/// or, in the Android and iOS styles, Material's or CupertinoIcons
/// (`tool/icons/build_style_icon_fonts.py`).
///
/// A font family can't be unloaded or replaced while the app runs: loading
/// another font under the same name adds it behind the first, which keeps
/// drawing (test/core/theme/icon_sets_test.dart checks that). So the set is
/// picked once, at the start, from the saved style, and a style with other
/// icons shows them after a restart (ThemeChoices offers one).
abstract final class IconStrokes {
  static const _family = 'packages/lucide_icons_flutter/Lucide';

  /// The set drawn until the app restarts; null before one is loaded.
  static IconSet? get loaded => _loaded;
  static IconSet? _loaded;

  /// Whether [style]'s icons are other than the ones showing, so they need
  /// a restart.
  static bool needsRestartFor(AppStyle style) {
    final loaded = _loaded;
    return loaded != null && loaded != style.iconSet;
  }

  /// The icons of the style last chosen (at the start).
  static Future<void> useSaved() async => use((await ThemePreferences.loadStyle()).iconSet);

  /// Lucide's light weight and Hi-icons, whatever the style.
  static Future<void> useLight() => use(IconSet.lucide);

  /// Loaded under Lucide's font name, [set] takes that font's place for every
  /// icon in the app (fonts loaded while running come before the bundled
  /// ones), so `LucideIcons.x` is all the code ever says. Only the first call
  /// counts.
  static Future<void> use(IconSet set) async {
    if (_loaded != null) return;
    _loaded = set;
    final loader = FontLoader(_family)..addFont(rootBundle.load(set.asset));
    await loader.load();
  }
}
