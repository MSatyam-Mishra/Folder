import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The iOS style (Options > Style): iOS's system colours, grouped lists of
/// rounded cards, large bold titles, its switches, sliders and segmented
/// controls, hairline separators, and Liquid glass bars, menus and sheets on
/// every system (AppGlass). Its icons are CupertinoIcons (IconStrokes), never
/// Apple's own symbols, and its folders are drawn here, not taken from Apple.
abstract final class IosStyle {
  static const blue = Color(0xFF007AFF);
  static const blueDark = Color(0xFF0A84FF);
  static const green = Color(0xFF34C759);
  static const greenDark = Color(0xFF30D158);

  /// The grouped background (Settings, sheets) and the cards on it.
  static Color groupedBackground(bool dark) => dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
  static Color groupedCard(bool dark) => dark ? const Color(0xFF2C2C2E) : const Color(0xFFFFFFFF);

  /// A hairline between rows.
  static Color separator(bool dark) => dark ? const Color(0xFF3D3D41) : const Color(0xFFC6C6C8);

  /// A field's fill.
  static Color fill(bool dark) => dark ? const Color(0xFF2C2C2E) : const Color(0xFFEEEEF0);

  /// The track of a segmented control, a grey button: a step lighter than
  /// the cards they sit on.
  static Color track(bool dark) => dark ? const Color(0xFF3A3A3C) : const Color(0xFFEEEEF0);

  static const light = ShadColorScheme(
    background: Color(0xFFFFFFFF), // systemBackground
    foreground: Color(0xFF000000), // label
    card: Color(0xFFFFFFFF), // secondarySystemGroupedBackground
    cardForeground: Color(0xFF000000),
    popover: Color(0xFFF9F9F9),
    popoverForeground: Color(0xFF000000),
    primary: blue,
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFFEEEEF0), // tertiarySystemFill on white
    secondaryForeground: Color(0xFF000000),
    muted: Color(0xFFF2F2F7), // systemGroupedBackground: sidebar, tab bar
    mutedForeground: Color(0xFF8A8A8E), // secondaryLabel
    accent: Color(0xFFE5E5EA), // a selected row: systemGray5
    accentForeground: Color(0xFF000000),
    destructive: Color(0xFFFF3B30),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFFD1D1D6), // systemGray4
    input: Color(0xFFD1D1D6),
    ring: blue,
    selection: Color(0xFFB4D5FE),
  );

  static const dark = ShadColorScheme(
    background: Color(0xFF000000),
    foreground: Color(0xFFFFFFFF),
    card: Color(0xFF1C1C1E),
    cardForeground: Color(0xFFFFFFFF),
    popover: Color(0xFF2C2C2E),
    popoverForeground: Color(0xFFFFFFFF),
    primary: blueDark,
    primaryForeground: Color(0xFFFFFFFF),
    secondary: Color(0xFF2C2C2E),
    secondaryForeground: Color(0xFFFFFFFF),
    muted: Color(0xFF1C1C1E), // secondarySystemBackground
    mutedForeground: Color(0xFF98989E),
    accent: Color(0xFF3A3A3C), // systemGray4
    accentForeground: Color(0xFFFFFFFF),
    destructive: Color(0xFFFF453A),
    destructiveForeground: Color(0xFFFFFFFF),
    border: Color(0xFF38383A),
    input: Color(0xFF48484A),
    ring: blueDark,
    selection: Color(0xFF2B4A6E),
  );

  /// [theme] (AppTheme.material's) made iOS's.
  static ThemeData apply(ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final c = theme.colorScheme;
    final t = theme.textTheme;
    final grouped = groupedBackground(dark);
    final line = separator(dark);
    final text = t.copyWith(
      // Large titles are bold, and headlines semibold.
      headlineLarge: t.headlineLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      titleLarge: t.titleLarge?.copyWith(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.5),
      titleMedium: t.titleMedium?.copyWith(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.4),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
    );
    const capsule = StadiumBorder();
    const capsuleShape = WidgetStatePropertyAll<OutlinedBorder>(capsule);

    ButtonStyle button(ButtonStyle? style, {double padding = 18}) => (style ?? const ButtonStyle()).copyWith(
          shape: capsuleShape,
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: padding, vertical: 8)),
        );

    // A field: grey, no line, blue around it while typing.
    final field = WidgetStateInputBorder.resolveWith((states) {
      final radius = BorderRadius.circular(10);
      if (states.contains(WidgetState.error)) {
        return OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c.error, width: 1.5));
      }
      if (states.contains(WidgetState.focused)) {
        return OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c.primary, width: 1.5));
      }
      return OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none);
    });

    return theme.copyWith(
      textTheme: text,
      dividerColor: line,
      dividerTheme: DividerThemeData(color: line, thickness: 0.5, space: 0.5),
      appBarTheme: theme.appBarTheme.copyWith(
        centerTitle: true,
        titleTextStyle: text.titleMedium,
        shape: Border(bottom: BorderSide(color: line, width: 0.5)),
      ),
      cardTheme: theme.cardTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: grouped,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        titleTextStyle: text.titleMedium,
        barrierColor: Colors.black.withValues(alpha: 0.3),
      ),
      bottomSheetTheme: theme.bottomSheetTheme.copyWith(
        backgroundColor: grouped,
        modalBackgroundColor: grouped,
        dragHandleSize: const Size(36, 5),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      ),
      drawerTheme: theme.drawerTheme.copyWith(backgroundColor: grouped),
      listTileTheme: theme.listTileTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      filledButtonTheme: FilledButtonThemeData(style: button(theme.filledButtonTheme.style)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: button(theme.elevatedButtonTheme.style)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: button(theme.outlinedButtonTheme.style).copyWith(
          // No outlines on iOS: a grey capsule.
          side: const WidgetStatePropertyAll(BorderSide.none),
          backgroundColor: WidgetStatePropertyAll(track(dark)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: button(theme.textButtonTheme.style, padding: 12).copyWith(
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.onSurfaceVariant.withValues(alpha: 0.5) : c.primary,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: (theme.iconButtonTheme.style ?? const ButtonStyle()).copyWith(
          shape: const WidgetStatePropertyAll(CircleBorder()),
        ),
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: fill(dark),
        border: field,
      ),
      // iOS's switch: green, a white thumb as big when off as on.
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? (dark ? greenDark : green)
              : (dark ? const Color(0xFF39393D) : const Color(0xFFE9E9EA)),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        trackOutlineWidth: const WidgetStatePropertyAll(0),
        thumbIcon: const WidgetStatePropertyAll(Icon(null)),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      // Round selection marks, as iOS's lists in Select mode.
      checkboxTheme: theme.checkboxTheme.copyWith(
        shape: const CircleBorder(),
        side: BorderSide(color: c.onSurfaceVariant.withValues(alpha: 0.6), width: 1.5),
      ),
      // A thin track and a white knob.
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        activeTrackColor: c.primary,
        inactiveTrackColor: dark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA),
        thumbColor: Colors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 2, pressedElevation: 3),
        overlayShape: SliderComponentShape.noOverlay,
        valueIndicatorColor: dark ? const Color(0xFF3A3A3C) : const Color(0xFF636366),
        valueIndicatorTextStyle: text.bodySmall?.copyWith(color: Colors.white),
      ),
      // A segmented control: a grey track, the chosen segment white on it.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? (dark ? const Color(0xFF636366) : Colors.white)
                : track(dark),
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.onSurfaceVariant.withValues(alpha: 0.5) : c.onSurface,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: track(dark), width: 2)),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
          textStyle: WidgetStatePropertyAll(text.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w500)),
          elevation: const WidgetStatePropertyAll(0),
          visualDensity: VisualDensity.compact,
        ),
      ),
      chipTheme: theme.chipTheme.copyWith(shape: capsule),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: c.outline, width: 0.5)),
      ),
      menuTheme: MenuThemeData(
        style: (theme.menuTheme.style ?? const MenuStyle()).copyWith(
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        ),
      ),
      snackBarTheme: theme.snackBarTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      tooltipTheme: theme.tooltipTheme.copyWith(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF3A3A3C) : const Color(0xFF3A3A3C).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: text.bodySmall?.copyWith(color: Colors.white),
      ),
      progressIndicatorTheme: theme.progressIndicatorTheme.copyWith(
        linearTrackColor: dark ? const Color(0xFF3A3A3C) : const Color(0xFFE5E5EA),
      ),
      searchBarTheme: theme.searchBarTheme.copyWith(
        backgroundColor: WidgetStatePropertyAll(fill(dark)),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
      tabBarTheme: theme.tabBarTheme.copyWith(labelColor: c.primary, indicatorColor: c.primary),
    );
  }
}
