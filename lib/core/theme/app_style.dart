import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The app's overall look, chosen in Options: its own (with a colour of the
/// user's choice), or one that follows another system or theme.
enum AppStyle {
  /// The app's own look; the Color swatches apply.
  standard,

  /// Finder on macOS.
  macos,

  /// File Explorer on Windows 11.
  windows,

  /// The Sweet theme (EliverLara): dark, with magenta and colourful icons.
  sweet,

  /// The Dracula theme: dark, with its purple, pink and colourful icons.
  dracula;

  String get label => switch (this) {
        AppStyle.standard => 'Explorer',
        AppStyle.macos => 'macOS',
        AppStyle.windows => 'Windows',
        AppStyle.sweet => 'Sweet',
        AppStyle.dracula => 'Dracula',
      };

  /// Sweet and Dracula only come dark.
  bool get darkOnly => this == AppStyle.sweet || this == AppStyle.dracula;

  static AppStyle parse(String? name) =>
      AppStyle.values.firstWhere((s) => s.name == name, orElse: () => AppStyle.standard);

  /// The style's colours, or null for [standard] (its colour scheme is
  /// the one picked under Color).
  ShadColorScheme? schemeFor(Brightness brightness) {
    final dark = brightness == Brightness.dark || darkOnly;
    return switch (this) {
      AppStyle.standard => null,
      AppStyle.macos => dark ? _macDark : _macLight,
      AppStyle.windows => dark ? _windowsDark : _windowsLight,
      AppStyle.sweet => _sweet,
      AppStyle.dracula => _dracula,
    };
  }

  /// The style's typeface: the system's own on its system (San Francisco
  /// on a Mac, Segoe UI Variable on Windows); null keeps the app's
  /// (Geist), which is closer to either than another system's default.
  String? get fontFamily => switch (this) {
        AppStyle.macos when Platform.isMacOS && _systemFonts => 'CupertinoSystemText',
        AppStyle.windows when Platform.isWindows && _systemFonts => 'Segoe UI Variable Text',
        _ => null,
      };

  /// Tests have no system fonts.
  static final bool _systemFonts = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Corner radius of controls: Finder's are a little rounder than
  /// Windows 11's.
  double get controlRadius => switch (this) {
        AppStyle.macos => 6,
        AppStyle.windows => 4,
        _ => 8,
      };

  AppLook look(Brightness brightness) {
    final dark = brightness == Brightness.dark || darkOnly;
    return switch (this) {
      AppStyle.standard => const AppLook(style: AppStyle.standard),
      // Finder: blue folders; sidebar icons in the accent colour.
      AppStyle.macos => AppLook(
          style: this,
          folder: const (Color(0xFF6FBDF6), Color(0xFF4AA3EC)),
          sidebarIcons: dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
        ),
      // File Explorer: yellow folders.
      AppStyle.windows => const AppLook(
          style: AppStyle.windows,
          folder: (Color(0xFFFFD15E), Color(0xFFF0B22E)),
        ),
      AppStyle.sweet => const AppLook(
          style: AppStyle.sweet,
          // Violet: apart from the magenta of the selection.
          folder: (Color(0xFF9D6CF5), Color(0xFF6C45D1)),
          iconPalette: [
            Color(0xFFC74DED), // magenta
            Color(0xFF7CB7FF), // blue
            Color(0xFF00C1E4), // cyan
            Color(0xFF71F79F), // green
            Color(0xFFF9DC5C), // yellow
            Color(0xFFED254E), // red
          ],
        ),
      AppStyle.dracula => const AppLook(
          style: AppStyle.dracula,
          folder: (Color(0xFFBD93F9), Color(0xFF9273D6)),
          iconPalette: [
            Color(0xFFBD93F9), // purple
            Color(0xFFFF79C6), // pink
            Color(0xFF8BE9FD), // cyan
            Color(0xFF50FA7B), // green
            Color(0xFFFFB86C), // orange
            Color(0xFFF1FA8C), // yellow
            Color(0xFFFF5555), // red
          ],
        ),
    };
  }
}

/// What a style changes besides its colours, for widgets to read with
/// `context.look`.
class AppLook extends ThemeExtension<AppLook> {
  const AppLook({required this.style, this.folder, this.iconPalette, this.sidebarIcons});

  final AppStyle style;

  /// Folder art colours (front, back); null for the app's glass folder.
  final (Color, Color)? folder;

  /// Icons take these colours (Sweet, Dracula); null leaves them plain.
  final List<Color>? iconPalette;

  /// Colour of the sidebar's icons (Finder tints them).
  final Color? sidebarIcons;

  /// The colour for [icon] in a colourful style: the same icon always gets
  /// the same colour, and kinds of action get fitting ones (delete red,
  /// add green...). Else [plain].
  Color iconColor(IconData? icon, Color plain) => tint(icon) ?? plain;

  /// [iconColor], or null where icons keep their usual colour.
  Color? tint(IconData? icon) {
    final palette = iconPalette;
    if (palette == null || icon == null) return null;
    final role = _roles[icon.codePoint];
    final index = role != null ? _roleIndex(role) : icon.codePoint;
    return palette[index % palette.length];
  }

  int _roleIndex(_Role role) {
    final dracula = style == AppStyle.dracula;
    // Positions in the palettes above.
    return switch (role) {
      _Role.danger => dracula ? 6 : 5,
      _Role.create => 3,
      _Role.media => dracula ? 1 : 0,
      _Role.files => dracula ? 0 : 1,
      _Role.link => 2,
      _Role.warm => 4,
      _Role.store => dracula ? 5 : 4,
    };
  }

  static final Map<int, _Role> _roles = {
    for (final i in [LucideIcons.trash2, LucideIcons.trash, LucideIcons.x, LucideIcons.circleAlert, LucideIcons.power])
      i.codePoint: _Role.danger,
    for (final i in [
      LucideIcons.plus, LucideIcons.folderPlus, LucideIcons.filePlus, LucideIcons.squarePlus,
      LucideIcons.download, LucideIcons.cloudDownload, LucideIcons.check, LucideIcons.circleCheck,
    ])
      i.codePoint: _Role.create,
    for (final i in [
      LucideIcons.image, LucideIcons.images, LucideIcons.music, LucideIcons.video, LucideIcons.clapperboard,
      LucideIcons.film, LucideIcons.camera, LucideIcons.heart, LucideIcons.star,
    ])
      i.codePoint: _Role.media,
    for (final i in [
      LucideIcons.folder, LucideIcons.folderOpen, LucideIcons.file, LucideIcons.fileText, LucideIcons.files,
      LucideIcons.house, LucideIcons.monitor, LucideIcons.hardDrive, LucideIcons.usb, LucideIcons.smartphone,
    ])
      i.codePoint: _Role.files,
    for (final i in [
      LucideIcons.copy, LucideIcons.link, LucideIcons.share2, LucideIcons.wifi, LucideIcons.radio,
      LucideIcons.globe, LucideIcons.info, LucideIcons.search, LucideIcons.appWindow,
    ])
      i.codePoint: _Role.link,
    for (final i in [
      LucideIcons.scissors, LucideIcons.pencil, LucideIcons.squarePen, LucideIcons.settings,
      LucideIcons.slidersHorizontal, LucideIcons.refreshCw, LucideIcons.arrowUpDown,
    ])
      i.codePoint: _Role.warm,
    for (final i in [LucideIcons.archive, LucideIcons.package, LucideIcons.lock, LucideIcons.fileArchive])
      i.codePoint: _Role.store,
  };

  @override
  AppLook copyWith({AppStyle? style}) => AppLook(
        style: style ?? this.style,
        folder: folder,
        iconPalette: iconPalette,
        sidebarIcons: sidebarIcons,
      );

  @override
  AppLook lerp(AppLook? other, double t) => t < 0.5 || other == null ? this : other;
}

enum _Role { danger, create, media, files, link, warm, store }

extension AppLookContext on BuildContext {
  /// The current style's extras ([AppLook]); the app's own look by default.
  AppLook get look => Theme.of(this).extension<AppLook>() ?? const AppLook(style: AppStyle.standard);
}

// Finder (macOS 15): system colours of the light and dark appearance.
const _macLight = ShadColorScheme(
  background: Color(0xFFFFFFFF),
  foreground: Color(0xFF262626), // labelColor, 85% black
  card: Color(0xFFFFFFFF),
  cardForeground: Color(0xFF262626),
  popover: Color(0xFFF6F6F6),
  popoverForeground: Color(0xFF262626),
  primary: Color(0xFF007AFF), // controlAccentColor
  primaryForeground: Color(0xFFFFFFFF),
  secondary: Color(0xFFEDEDED),
  secondaryForeground: Color(0xFF262626),
  muted: Color(0xFFEFEFEF), // sidebar
  mutedForeground: Color(0xFF808080), // secondaryLabelColor
  accent: Color(0x24007AFF), // selected row: a light, see-through blue
  accentForeground: Color(0xFF262626),
  destructive: Color(0xFFFF3B30),
  destructiveForeground: Color(0xFFFFFFFF),
  border: Color(0xFFE5E5E5), // separatorColor
  input: Color(0xFFCFCFCF),
  ring: Color(0xFF7FBDFF),
  selection: Color(0xFFB3D7FF),
);

const _macDark = ShadColorScheme(
  background: Color(0xFF1E1E1E),
  foreground: Color(0xFFDFDFDF), // labelColor, 85% white
  card: Color(0xFF262626),
  cardForeground: Color(0xFFDFDFDF),
  popover: Color(0xFF2B2B2B),
  popoverForeground: Color(0xFFDFDFDF),
  primary: Color(0xFF0A84FF),
  primaryForeground: Color(0xFFFFFFFF),
  secondary: Color(0xFF3A3A3C),
  secondaryForeground: Color(0xFFDFDFDF),
  muted: Color(0xFF282828), // sidebar
  mutedForeground: Color(0xFF999999),
  accent: Color(0x3D0A84FF), // selected row: a light, see-through blue
  accentForeground: Color(0xFFDFDFDF),
  destructive: Color(0xFFFF453A),
  destructiveForeground: Color(0xFFFFFFFF),
  border: Color(0xFF3A3A3A),
  input: Color(0xFF4A4A4A),
  ring: Color(0xFF0A84FF),
  selection: Color(0xFF3F638B),
);

// File Explorer (Windows 11): Mica panes, white items view, blue selection.
const _windowsLight = ShadColorScheme(
  background: Color(0xFFFFFFFF),
  foreground: Color(0xFF1B1B1B), // TextFillColorPrimary
  card: Color(0xFFFBFBFB),
  cardForeground: Color(0xFF1B1B1B),
  popover: Color(0xFFF9F9F9), // menu flyout
  popoverForeground: Color(0xFF1B1B1B),
  primary: Color(0xFF005FB8), // AccentFillColorDefault
  primaryForeground: Color(0xFFFFFFFF),
  secondary: Color(0xFFF3F3F3),
  secondaryForeground: Color(0xFF1B1B1B),
  muted: Color(0xFFF3F3F3), // navigation pane, Mica
  mutedForeground: Color(0xFF606060), // TextFillColorSecondary
  accent: Color(0x260078D4), // selected item: File Explorer's light blue, see-through
  accentForeground: Color(0xFF1B1B1B),
  destructive: Color(0xFFC42B1C),
  destructiveForeground: Color(0xFFFFFFFF),
  border: Color(0xFFE5E5E5),
  input: Color(0xFFD1D1D1),
  ring: Color(0xFF005FB8),
  selection: Color(0xFFADD6FF),
);

const _windowsDark = ShadColorScheme(
  background: Color(0xFF191919),
  foreground: Color(0xFFFFFFFF),
  card: Color(0xFF1F1F1F),
  cardForeground: Color(0xFFFFFFFF),
  popover: Color(0xFF2C2C2C), // menu flyout
  popoverForeground: Color(0xFFFFFFFF),
  primary: Color(0xFF60CDFF), // AccentFillColorDefault
  primaryForeground: Color(0xFF000000),
  secondary: Color(0xFF2D2D2D),
  secondaryForeground: Color(0xFFFFFFFF),
  muted: Color(0xFF202020), // navigation pane, Mica
  mutedForeground: Color(0xFFC5C5C5), // TextFillColorSecondary
  accent: Color(0x24FFFFFF), // selected item: a light grey, see-through
  accentForeground: Color(0xFFFFFFFF),
  destructive: Color(0xFFFF99A4),
  destructiveForeground: Color(0xFF000000),
  border: Color(0xFF2E2E2E),
  input: Color(0xFF3B3B3B),
  ring: Color(0xFF60CDFF),
  selection: Color(0xFF264F78),
);

// Sweet (EliverLara): its KDE and GTK colours.
const _sweet = ShadColorScheme(
  background: Color(0xFF161925),
  foreground: Color(0xFFC3C7D1),
  card: Color(0xFF1A1D2B),
  cardForeground: Color(0xFFC3C7D1),
  popover: Color(0xFF1E2132),
  popoverForeground: Color(0xFFD3DAE3),
  primary: Color(0xFFC50ED2),
  primaryForeground: Color(0xFFFFFFFF),
  secondary: Color(0xFF262A3D),
  secondaryForeground: Color(0xFFD3DAE3),
  muted: Color(0xFF181B28), // window
  mutedForeground: Color(0xFF858CA2),
  accent: Color(0x47C50ED2), // selection: its magenta, see-through
  accentForeground: Color(0xFFD3DAE3),
  destructive: Color(0xFFED254E),
  destructiveForeground: Color(0xFFFFFFFF),
  border: Color(0xFF262A3D),
  input: Color(0xFF33374A),
  ring: Color(0xFFC74DED),
  selection: Color(0xFF6A1E7A),
);

// Dracula: its published palette.
const _dracula = ShadColorScheme(
  background: Color(0xFF282A36),
  foreground: Color(0xFFF8F8F2),
  card: Color(0xFF282A36),
  cardForeground: Color(0xFFF8F8F2),
  popover: Color(0xFF21222C),
  popoverForeground: Color(0xFFF8F8F2),
  primary: Color(0xFFBD93F9), // purple
  primaryForeground: Color(0xFF282A36),
  secondary: Color(0xFF44475A), // current line
  secondaryForeground: Color(0xFFF8F8F2),
  muted: Color(0xFF21222C), // darker background
  mutedForeground: Color(0xFF6272A4), // comment
  accent: Color(0xFF44475A), // selection
  accentForeground: Color(0xFFF8F8F2),
  destructive: Color(0xFFFF5555),
  destructiveForeground: Color(0xFFF8F8F2),
  border: Color(0xFF343746),
  input: Color(0xFF44475A),
  ring: Color(0xFFBD93F9),
  selection: Color(0xFF44475A),
);
