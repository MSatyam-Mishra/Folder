import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What shows behind the window on computers (Options > Window): the
/// system's own materials, so the app looks part of Windows 11 or macOS.
enum WindowBackdrop {
  off,

  /// Windows 11: the wallpaper's colours, softly, as File Explorer has.
  mica,

  /// Windows 11: Mica with more of the wallpaper (tabbed apps use it).
  micaAlt,

  /// Windows: what's behind the window, blurred.
  acrylic,

  /// Windows, Linux: what's behind the window, not blurred (Linux
  /// compositors such as KDE may blur it).
  clear,

  /// macOS: Finder's sidebar material.
  sidebar,

  /// macOS: the material under a window's content.
  vibrancy,

  /// macOS: the dark glass of heads-up windows.
  hud;

  String get label => switch (this) {
        WindowBackdrop.off => 'Off',
        WindowBackdrop.mica => 'Mica',
        WindowBackdrop.micaAlt => 'Mica Alt',
        WindowBackdrop.acrylic => 'Acrylic',
        WindowBackdrop.clear => 'Clear',
        WindowBackdrop.sidebar => 'Sidebar',
        WindowBackdrop.vibrancy => 'Vibrancy',
        WindowBackdrop.hud => 'HUD',
      };

  String get description => switch (this) {
        WindowBackdrop.off => 'A solid window',
        WindowBackdrop.mica => 'The colours of your wallpaper, softly, as in File Explorer',
        WindowBackdrop.micaAlt => 'Like Mica, with more of the wallpaper',
        WindowBackdrop.acrylic => 'What is behind the window, blurred',
        WindowBackdrop.clear => Platform.isLinux
            ? 'What is behind the window (blurred where your desktop supports it)'
            : 'What is behind the window, not blurred',
        WindowBackdrop.sidebar => 'The blur of Finder\'s sidebar',
        WindowBackdrop.vibrancy => 'What is behind the window, blurred',
        WindowBackdrop.hud => 'A darker, stronger blur',
      };

  IconData get icon => switch (this) {
        WindowBackdrop.off => LucideIcons.square,
        WindowBackdrop.mica || WindowBackdrop.micaAlt => LucideIcons.image,
        WindowBackdrop.acrylic || WindowBackdrop.vibrancy || WindowBackdrop.sidebar => LucideIcons.droplets,
        WindowBackdrop.clear => LucideIcons.squareDashed,
        WindowBackdrop.hud => LucideIcons.moon,
      };

  /// The choices this computer has.
  static List<WindowBackdrop> get available {
    if (Platform.isMacOS) return const [off, sidebar, vibrancy, hud];
    if (Platform.isLinux) return const [off, clear];
    return [
      off,
      if (WindowEffects.windowsBuild >= 22000) mica,
      // Mica Alt came with Windows 11 22H2.
      if (WindowEffects.windowsBuild >= 22523) micaAlt,
      acrylic,
      clear,
    ];
  }

  /// The one used until the user picks.
  static WindowBackdrop get standard {
    if (Platform.isMacOS) return vibrancy;
    if (Platform.isLinux) return clear;
    return acrylic;
  }

  static WindowBackdrop parse(String? name) {
    final found = values.where((b) => b.name == name).firstOrNull;
    return found != null && available.contains(found) ? found : standard;
  }

  /// How see-through the app's backgrounds are, until the user sets it:
  /// little on Linux, where nothing may blur.
  static double get standardTransparency {
    if (Platform.isWindows) return 0.65;
    return Platform.isLinux ? 0.12 : 0.5;
  }
}

/// The window's backdrop ([WindowBackdrop]) through flutter_acrylic. The
/// app's backgrounds then let it show through ([AppTheme] makes them as
/// see-through as set); dialogs, sheets and menus stay solid.
abstract final class WindowEffects {
  /// Computers only; widget tests have no window.
  static final bool supported = (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
      !Platform.environment.containsKey('FLUTTER_TEST');

  /// The Windows build number (22000 and up is Windows 11); 0 elsewhere.
  static final int windowsBuild = Platform.isWindows
      ? int.tryParse(RegExp(r'Build (\d+)').firstMatch(Platform.operatingSystemVersion)?.group(1) ?? '') ?? 0
      : 0;

  /// Prepares the window at start-up, before the first frame (the Linux
  /// window is shown by the plugin once it can be see-through).
  static Future<void> init() async {
    if (!supported) return;
    await Window.initialize();
  }

  static WindowBackdrop? _last;
  static bool? _lastDark;

  /// Puts [backdrop] behind the window, for the current theme ([dark]).
  static Future<void> apply({required WindowBackdrop backdrop, required bool dark}) async {
    if (!supported) return;
    if (_last == backdrop && _lastDark == dark) return;
    final changed = _last != null && _last != backdrop;
    _last = backdrop;
    _lastDark = dark;
    // One material at a time: the previous one goes first.
    if (changed || backdrop == WindowBackdrop.off) {
      await Window.setEffect(effect: WindowEffect.disabled);
      if (backdrop == WindowBackdrop.off) return;
    }
    switch (backdrop) {
      case WindowBackdrop.off:
        break;
      case WindowBackdrop.mica:
        await Window.setEffect(effect: WindowEffect.mica, dark: dark);
      case WindowBackdrop.micaAlt:
        await Window.setEffect(effect: WindowEffect.tabbed, dark: dark);
      case WindowBackdrop.acrylic:
        await Window.setEffect(
          effect: WindowEffect.acrylic,
          // A light wash; the app's own background tints it further.
          color: dark ? const Color(0x22101010) : const Color(0x22F8F8F8),
          dark: dark,
        );
      case WindowBackdrop.clear:
        await Window.setEffect(effect: WindowEffect.transparent, dark: dark);
      case WindowBackdrop.sidebar:
        await Window.setEffect(effect: WindowEffect.sidebar, dark: dark);
      case WindowBackdrop.vibrancy:
        await Window.setEffect(effect: WindowEffect.underWindowBackground, dark: dark);
      case WindowBackdrop.hud:
        await Window.setEffect(effect: WindowEffect.hudWindow, dark: dark);
    }
  }
}
