import 'package:folders/core/theme/app_color_theme.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The Android style (Options > Style): Material 3 Expressive. Tonal colours
/// grown from one colour, large rounded surfaces, pill-shaped buttons, chips
/// and selections, a big rounded-square floating button, bolder headings, and
/// Material's own switches, sliders and segmented buttons.
///
/// Android 12 and newer grow these colours from the wallpaper; reading it
/// needs a plugin of its own (dynamic_color), so here they grow from the
/// Color picked in Options, as Android's would from a wallpaper of that
/// colour.
abstract final class MaterialStyle {
  /// Corner radius of dialogs and sheets.
  static const double surfaceRadius = 28;

  /// Corner radius of cards.
  static const double cardRadius = 24;

  /// Material's colours grown from [color] (Options > Color): tonal for a
  /// colour, greys for the neutral ones (Zinc, Slate...).
  static ColorScheme scheme(AppColorThemeSpec color, Brightness brightness) =>
      seeded(color.swatch, brightness);

  /// Schemes made, by their primary colour: the Material theme has only
  /// that to go by ([fromPrimary]).
  static final _byPrimary = <(Color, Brightness), ColorScheme>{};

  static ColorScheme seeded(Color seed, Brightness brightness) {
    final neutral = HSLColor.fromColor(seed).saturation < 0.15;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: neutral ? DynamicSchemeVariant.monochrome : DynamicSchemeVariant.tonalSpot,
    );
    _byPrimary[(scheme.primary, brightness)] = scheme;
    return scheme;
  }

  /// The scheme whose primary colour is [primary]: the one made for it, or
  /// grown anew from it (a scheme's primary has the hue it grew from).
  static ColorScheme fromPrimary(Color primary, Brightness brightness) =>
      _byPrimary[(primary, brightness)] ?? seeded(primary, brightness);

  /// The same colours as shadcn/ui tokens, for the app's own widgets.
  static ShadColorScheme shadScheme(ColorScheme c) => ShadColorScheme(
        background: c.surface,
        foreground: c.onSurface,
        card: c.surfaceContainerLow,
        cardForeground: c.onSurface,
        popover: c.surfaceContainer,
        popoverForeground: c.onSurface,
        primary: c.primary,
        primaryForeground: c.onPrimary,
        secondary: c.secondaryContainer,
        secondaryForeground: c.onSecondaryContainer,
        // The panes (sidebar, tab bar): a tone off the page.
        muted: c.surfaceContainer,
        mutedForeground: c.onSurfaceVariant,
        // A selected item: the secondary container, as Material's lists.
        accent: c.secondaryContainer,
        accentForeground: c.onSecondaryContainer,
        destructive: c.error,
        destructiveForeground: c.onError,
        border: c.outlineVariant,
        input: c.outline,
        ring: c.primary,
        selection: c.primaryContainer,
      );

  /// Tonal folders in the primary colour's tones, Material's own shape;
  /// pill-shaped selections.
  static AppLook look(ColorScheme c) {
    final dark = c.brightness == Brightness.dark;
    final front = dark ? c.primary : c.primaryFixedDim;
    final back = Color.lerp(dark ? c.primaryContainer : c.primary, front, 0.45)!;
    return AppLook(
      style: AppStyle.android,
      folder: (front, back),
      folderArt: FolderArt.material,
      fileArt: FileArt.material,
      itemRadius: 100,
    );
  }

  /// [theme] (AppTheme.material's) made Material 3 Expressive.
  static ThemeData apply(ThemeData theme) {
    // The page keeps its colour: see-through over a window effect.
    final c = fromPrimary(theme.colorScheme.primary, theme.brightness).copyWith(surface: theme.colorScheme.surface);
    final t = theme.textTheme;
    // Emphasised: bolder headings and labels.
    final text = t.copyWith(
      headlineLarge: t.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: t.titleLarge?.copyWith(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.1),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.1),
      labelMedium: t.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    const pill = StadiumBorder();
    const pillShape = WidgetStatePropertyAll<OutlinedBorder>(pill);
    final surface = RoundedRectangleBorder(borderRadius: BorderRadius.circular(surfaceRadius));
    final menu = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));

    ButtonStyle button(ButtonStyle? style, {Color? background, Color? foreground, double padding = 24}) =>
        (style ?? const ButtonStyle()).copyWith(
          shape: pillShape,
          minimumSize: const WidgetStatePropertyAll(Size(48, 40)),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: padding, vertical: 10)),
          textStyle: WidgetStatePropertyAll(text.labelLarge),
          backgroundColor: background == null
              ? null
              : WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.disabled) ? c.onSurface.withValues(alpha: 0.12) : background),
          foregroundColor: foreground == null
              ? null
              : WidgetStateProperty.resolveWith((s) =>
                  s.contains(WidgetState.disabled) ? c.onSurface.withValues(alpha: 0.38) : foreground),
          overlayColor: foreground == null ? null : WidgetStatePropertyAll(foreground.withValues(alpha: 0.1)),
        );

    final pillSegments = ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.secondaryContainer : Colors.transparent,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.disabled)
            ? c.onSurface.withValues(alpha: 0.38)
            : s.contains(WidgetState.selected)
                ? c.onSecondaryContainer
                : c.onSurface,
      ),
      side: WidgetStatePropertyAll(BorderSide(color: c.outline)),
      shape: pillShape,
      textStyle: WidgetStatePropertyAll(text.labelLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: 0)),
      visualDensity: VisualDensity.compact,
    );

    return theme.copyWith(
      colorScheme: c,
      textTheme: text,
      cardColor: c.surfaceContainerLow,
      dividerColor: c.outlineVariant,
      hoverColor: c.onSurface.withValues(alpha: 0.05),
      focusColor: c.onSurface.withValues(alpha: 0.1),
      highlightColor: c.onSurface.withValues(alpha: 0.1),
      splashColor: c.onSurface.withValues(alpha: 0.1),
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: c.surface,
        shape: const Border(),
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: c.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: c.surfaceContainerHigh,
        elevation: 6,
        shape: surface,
        titleTextStyle: text.headlineSmall?.copyWith(fontSize: 22, color: c.onSurface),
        contentTextStyle: text.bodyMedium?.copyWith(color: c.onSurfaceVariant),
        barrierColor: Colors.black.withValues(alpha: 0.32),
      ),
      bottomSheetTheme: theme.bottomSheetTheme.copyWith(
        backgroundColor: c.surfaceContainerLow,
        modalBackgroundColor: c.surfaceContainerLow,
        dragHandleColor: c.onSurfaceVariant.withValues(alpha: 0.4),
        dragHandleSize: const Size(32, 4),
        modalBarrierColor: Colors.black.withValues(alpha: 0.32),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(surfaceRadius))),
      ),
      drawerTheme: theme.drawerTheme.copyWith(
        backgroundColor: c.surfaceContainerLow,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(surfaceRadius))),
        endShape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(left: Radius.circular(surfaceRadius))),
      ),
      listTileTheme: theme.listTileTheme.copyWith(
        iconColor: c.onSurfaceVariant,
        selectedColor: c.onSecondaryContainer,
        selectedTileColor: c.secondaryContainer,
        shape: pill,
        titleTextStyle: text.bodyLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: button(theme.filledButtonTheme.style, background: c.primary, foreground: c.onPrimary),
      ),
      // Material's tonal button.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: button(theme.elevatedButtonTheme.style, background: c.secondaryContainer, foreground: c.onSecondaryContainer),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: button(theme.outlinedButtonTheme.style, foreground: c.onSurfaceVariant)
            .copyWith(side: WidgetStatePropertyAll(BorderSide(color: c.outlineVariant))),
      ),
      textButtonTheme: TextButtonThemeData(
        style: button(theme.textButtonTheme.style, foreground: c.primary, padding: 14),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: (theme.iconButtonTheme.style ?? const ButtonStyle()).copyWith(
          shape: const WidgetStatePropertyAll(CircleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.onSurface.withValues(alpha: 0.38) : c.onSurfaceVariant,
          ),
        ),
      ),
      // Expressive's medium floating button: a large rounded square.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.primaryContainer,
        foregroundColor: c.onPrimaryContainer,
        elevation: 3,
        focusElevation: 3,
        hoverElevation: 4,
        highlightElevation: 3,
        iconSize: 28,
        sizeConstraints: const BoxConstraints.tightFor(width: 80, height: 80),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        extendedSizeConstraints: const BoxConstraints.tightFor(height: 64),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(style: pillSegments),
      chipTheme: theme.chipTheme.copyWith(
        backgroundColor: Colors.transparent,
        selectedColor: c.secondaryContainer,
        checkmarkColor: c.onSecondaryContainer,
        side: BorderSide(color: c.outlineVariant),
        shape: pill,
        labelStyle: text.labelLarge?.copyWith(color: c.onSurfaceVariant),
        secondaryLabelStyle: text.labelLarge?.copyWith(color: c.onSecondaryContainer),
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        color: c.surfaceContainer,
        elevation: 3,
        shape: menu,
      ),
      menuTheme: MenuThemeData(
        style: (theme.menuTheme.style ?? const MenuStyle()).copyWith(
          backgroundColor: WidgetStatePropertyAll(c.surfaceContainer),
          shape: WidgetStatePropertyAll(menu),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 8, horizontal: 4)),
        ),
      ),
      dropdownMenuTheme: theme.dropdownMenuTheme.copyWith(
        menuStyle: (theme.dropdownMenuTheme.menuStyle ?? const MenuStyle()).copyWith(
          backgroundColor: WidgetStatePropertyAll(c.surfaceContainer),
          shape: WidgetStatePropertyAll(menu),
        ),
      ),
      snackBarTheme: theme.snackBarTheme.copyWith(
        backgroundColor: c.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: c.onInverseSurface),
        actionTextColor: c.inversePrimary,
        closeIconColor: c.onInverseSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      tooltipTheme: theme.tooltipTheme.copyWith(
        decoration: BoxDecoration(color: c.inverseSurface, borderRadius: BorderRadius.circular(8)),
        textStyle: text.bodySmall?.copyWith(color: c.onInverseSurface),
      ),
      // Material's own switch: its colours, a check on the thumb when on.
      switchTheme: SwitchThemeData(
        thumbIcon: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? const Icon(LucideIcons.check) : null,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: c.onSurfaceVariant, width: 2),
      ),
      radioTheme: const RadioThemeData(),
      // The 2024 slider: a tall track, a bar for a handle, a gap around it.
      sliderTheme: SliderThemeData(
        trackHeight: 16,
        activeTrackColor: c.primary,
        inactiveTrackColor: c.secondaryContainer,
        thumbColor: c.primary,
        disabledActiveTrackColor: c.onSurface.withValues(alpha: 0.38),
        disabledInactiveTrackColor: c.onSurface.withValues(alpha: 0.12),
        disabledThumbColor: c.onSurface.withValues(alpha: 0.38),
        overlayColor: Colors.transparent,
        thumbShape: const HandleThumbShape(),
        trackShape: const GappedSliderTrackShape(),
        trackGap: 6,
        thumbSize: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.pressed) || s.contains(WidgetState.focused) ? const Size(2, 44) : const Size(4, 44),
        ),
        valueIndicatorShape: const RoundedRectSliderValueIndicatorShape(),
        valueIndicatorColor: c.inverseSurface,
        valueIndicatorTextStyle: text.labelLarge?.copyWith(color: c.onInverseSurface),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.primary,
        linearTrackColor: c.secondaryContainer,
        circularTrackColor: c.secondaryContainer,
      ),
      tabBarTheme: theme.tabBarTheme.copyWith(
        labelColor: c.primary,
        unselectedLabelColor: c.onSurfaceVariant,
        indicatorColor: c.primary,
        dividerColor: c.outlineVariant,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: c.secondaryContainer,
        indicatorShape: pill,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(text.labelMedium?.copyWith(color: c.onSurface)),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.surface,
        indicatorColor: c.secondaryContainer,
        indicatorShape: pill,
        selectedIconTheme: IconThemeData(color: c.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: c.onSurfaceVariant),
      ),
      badgeTheme: BadgeThemeData(backgroundColor: c.error, textColor: c.onError),
      searchBarTheme: theme.searchBarTheme.copyWith(
        backgroundColor: WidgetStatePropertyAll(c.surfaceContainerHigh),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: pillShape,
      ),
      dividerTheme: theme.dividerTheme.copyWith(color: c.outlineVariant),
      extensions: [look(c)],
    );
  }
}
