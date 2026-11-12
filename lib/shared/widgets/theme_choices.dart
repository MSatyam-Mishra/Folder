import 'dart:ui' show ImageFilter;

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/theme/app_color_theme.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/core/theme/icon_strokes.dart';
import 'package:folders/core/theme/material_style.dart';
import 'package:folders/core/theme/style_restart.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The app's look: its style, light or dark, and its colour. In Options, and in
/// the video player's settings for someone who only uses the player.
class ThemeChoices extends StatelessWidget {
  const ThemeChoices({super.key, required this.heading, this.section, this.afterMode = const []});

  /// A section's title, as the sheet it's in shows them.
  final Widget Function(String label) heading;

  /// A section's content, as the sheet shows them (iOS: on a card); one
  /// below the other by default.
  final Widget Function(List<Widget> children)? section;

  /// After light and dark: Options puts the window's settings there.
  final List<Widget> afterMode;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeCubit>().state;
    final cubit = context.read<ThemeCubit>();
    final text = Theme.of(context).textTheme;
    final section = this.section ??
        (children) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('Style'),
        section([
        // Three to a row, sized to fill it.
        LayoutBuilder(builder: (context, box) {
          const gap = 10.0;
          final width = ((box.maxWidth - gap * 2) / 3).floorToDouble();
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final style in AppStyle.values)
                _StyleCard(
                  style: style,
                  settings: settings,
                  selected: settings.style == style,
                  width: width,
                  onTap: () => cubit.setStyle(style),
                ),
            ],
          );
        }),
        // Icons only change from the start (IconStrokes).
        if (IconStrokes.needsRestartFor(settings.style)) _RestartNotice(style: settings.style),
        ]),
        heading('Theme'),
        section([
        SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          // iOS's segmented controls have words only.
          segments: [
            ButtonSegment(
              value: ThemeMode.system,
              icon: context.look.groupedLists ? null : const Icon(LucideIcons.monitor, size: 15),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: context.look.groupedLists ? null : const Icon(LucideIcons.sun, size: 15),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: context.look.groupedLists ? null : const Icon(LucideIcons.moon, size: 15),
              label: Text('Dark'),
            ),
          ],
          selected: {settings.effectiveThemeMode},
          // Sweet and Dracula only come dark.
          onSelectionChanged: settings.style.darkOnly ? null : (s) => cubit.setThemeMode(s.first),
        ),
        if (settings.style.darkOnly)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('${settings.style.label} is a dark theme.', style: text.bodySmall),
          ),
        ]),
        ...afterMode,
        // The other styles come with their own colours; Android's grow
        // from the one picked.
        if (settings.style.takesColor) ...[
          heading('Color'),
          section([
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final spec in AppColorThemes.all)
                _Swatch(
                  spec: spec,
                  selected: settings.colorThemeId == spec.id,
                  onTap: () => cubit.setColorTheme(spec.id),
                ),
            ],
          ),
          ]),
        ],
      ],
    );
  }
}

/// A style, shown as a small window drawn in it: its title bar and window
/// buttons, its sidebar, and its own folders and files.
class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.style,
    required this.settings,
    required this.selected,
    required this.width,
    required this.onTap,
  });

  final AppStyle style;
  final AppThemeSettings settings;
  final bool selected;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: style.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: selected ? colors.primary : colors.border.withValues(alpha: 0.7),
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Stack(
                  children: [
                    _StylePreview(style: style, settings: settings, width: width - 10),
                    if (selected)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: Icon(LucideIcons.check, size: 11, color: colors.primaryForeground),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  style.label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? colors.primary : colors.foreground,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The window a style card shows, [width] wide.
class _StylePreview extends StatelessWidget {
  const _StylePreview({required this.style, required this.settings, required this.width});

  final AppStyle style;
  final AppThemeSettings settings;
  final double width;

  @override
  Widget build(BuildContext context) {
    final brightness = style.darkOnly ? Brightness.dark : Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final material = style == AppStyle.android ? MaterialStyle.scheme(settings.colorTheme, brightness) : null;
    final scheme = style.schemeFor(brightness, color: settings.colorTheme) ?? settings.colorTheme.schemeFor(brightness);
    final look = style.look(brightness, colors: material);
    final palette = look.iconPalette;
    final glass = style.glass;
    final height = width * 0.68;
    final bar = (height * 0.15).clamp(9.0, 14.0);
    final radius = switch (style) {
      AppStyle.ios => 12.0,
      AppStyle.android => 12.0,
      AppStyle.macos => 9.0,
      _ => 6.0,
    };
    final page = material?.surface ?? scheme.background;
    final sideColor = material?.surfaceContainer ?? scheme.muted;

    Widget line(double w, Color color, {double h = 2.5}) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        );

    // The window's buttons, as the style draws them.
    Widget buttons() {
      final dot = (bar * 0.42).clamp(4.0, 6.0);
      switch (style) {
        case AppStyle.macos || AppStyle.ios:
          return Row(mainAxisSize: MainAxisSize.min, children: [
            for (final c in const [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)])
              Container(
                width: dot,
                height: dot,
                margin: EdgeInsets.only(right: dot * 0.55),
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
          ]);
        case AppStyle.sweet || AppStyle.dracula:
          return Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: dot,
                height: dot,
                margin: EdgeInsets.only(left: dot * 0.6),
                decoration: BoxDecoration(
                  color: i == 2 ? (palette?.first ?? scheme.primary) : scheme.mutedForeground.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
              ),
          ]);
        case AppStyle.android:
          return Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: dot + 2,
                height: dot + 2,
                margin: EdgeInsets.only(left: dot * 0.5),
                decoration: BoxDecoration(
                  color: (material?.onSurfaceVariant ?? scheme.mutedForeground).withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
              ),
          ]);
        default:
          final glyph = scheme.foreground.withValues(alpha: 0.55);
          return Row(mainAxisSize: MainAxisSize.min, children: [
            line(dot, glyph, h: 1),
            SizedBox(width: dot),
            Container(
              width: dot * 0.9,
              height: dot * 0.9,
              decoration: BoxDecoration(border: Border.all(color: glyph, width: 1)),
            ),
            SizedBox(width: dot),
            Icon(LucideIcons.x, size: dot * 1.3, color: glyph),
          ]);
      }
    }

    final macLike = style == AppStyle.macos || style == AppStyle.ios;
    final titleBar = SizedBox(
      height: bar,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: bar * 0.55),
        child: Row(
          children: [
            if (macLike) buttons(),
            if (macLike) const Spacer(),
            if (!macLike) ...[
              // A tab.
              Container(
                width: width * 0.22,
                height: bar * 0.62,
                decoration: BoxDecoration(
                  color: page,
                  borderRadius: BorderRadius.circular(style == AppStyle.android ? bar : 3),
                ),
              ),
              const Spacer(),
              buttons(),
            ],
          ],
        ),
      ),
    );

    // The sidebar: places with their icons in the style's colours, the
    // first one selected.
    final accent = material?.secondaryContainer ?? scheme.accent;
    final sidebar = Padding(
      padding: EdgeInsets.fromLTRB(width * 0.03, height * 0.05, width * 0.03, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              margin: EdgeInsets.only(bottom: height * 0.035),
              padding: EdgeInsets.symmetric(horizontal: width * 0.02, vertical: height * 0.025),
              decoration: i == 0
                  ? BoxDecoration(
                      color: glass ? Colors.white.withValues(alpha: dark ? 0.16 : 0.7) : accent,
                      borderRadius: BorderRadius.circular(style == AppStyle.android ? 20 : style.controlRadius * 0.6),
                    )
                  : null,
              child: Row(children: [
                Container(
                  width: width * 0.045,
                  height: width * 0.045,
                  decoration: BoxDecoration(
                    color: palette?[i % palette.length] ??
                        look.sidebarIcons ??
                        scheme.primary.withValues(alpha: i == 0 ? 1 : 0.7),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                SizedBox(width: width * 0.025),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: line(
                      i.isEven ? width * 0.12 : width * 0.09,
                      scheme.foreground.withValues(alpha: i == 0 ? 0.75 : 0.45),
                    ),
                  ),
                ),
              ]),
            ),
        ],
      ),
    );

    // The files: the style's own folders and pages, three to a row and
    // sized to the room there is.
    final files = Theme(
      data: Theme.of(context).copyWith(extensions: [look]),
      child: LayoutBuilder(builder: (context, box) {
        final cell = box.maxWidth / 3;
        final art = (cell * 0.62).clamp(8.0, 30.0);
        Widget item(Widget child, double label) => SizedBox(
              width: cell,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                child,
                SizedBox(height: art * 0.14),
                line(art * label, scheme.foreground.withValues(alpha: 0.5), h: 2),
              ]),
            );
        return Padding(
          padding: EdgeInsets.only(top: height * 0.06),
          child: Column(children: [
            Row(children: [
              item(FolderIcon(size: art), 0.9),
              item(FolderIcon(size: art), 1.0),
              item(FolderIcon(size: art), 0.7),
            ]),
            SizedBox(height: height * 0.05),
            Row(children: [
              item(FileIcon(path: 'preview.pdf', size: art), 0.85),
              item(FileIcon(path: 'preview.png', size: art), 0.75),
              item(FileIcon(path: 'preview.mp3', size: art), 0.9),
            ]),
          ]),
        );
      }),
    );

    final Widget body;
    if (glass) {
      // Glass panels floating over the wallpaper.
      body = LiquidWallpaper(
        child: Column(children: [
          titleBar,
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(width * 0.025, 0, width * 0.025, width * 0.025),
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: width * 0.3,
                  child: _MiniGlass(dark: dark, radius: 8, child: sidebar),
                ),
                SizedBox(width: width * 0.02),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: page.withValues(alpha: dark ? 0.72 : 0.82),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: files,
                  ),
                ),
              ]),
            ),
          ),
        ]),
      );
    } else {
      body = ColoredBox(
        color: page,
        child: Column(children: [
          ColoredBox(color: sideColor, child: titleBar),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                width: width * 0.3,
                decoration: BoxDecoration(
                  color: sideColor,
                  border: style == AppStyle.android
                      ? null
                      : Border(right: BorderSide(color: scheme.border.withValues(alpha: 0.6), width: 0.5)),
                ),
                child: sidebar,
              ),
              Expanded(
                child: Stack(children: [
                  Positioned.fill(child: files),
                  if (style == AppStyle.android)
                    Positioned(
                      right: width * 0.035,
                      bottom: width * 0.035,
                      child: Container(
                        width: width * 0.13,
                        height: width * 0.13,
                        decoration: BoxDecoration(
                          color: material?.primaryContainer ?? scheme.primary,
                          borderRadius: BorderRadius.circular(width * 0.04),
                        ),
                        child: Icon(
                          LucideIcons.plus,
                          size: width * 0.06,
                          color: material?.onPrimaryContainer ?? scheme.primaryForeground,
                        ),
                      ),
                    ),
                ]),
              ),
            ]),
          ),
        ]),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: width, height: height, child: body),
    );
  }
}

/// Liquid glass drawn small: frosted white over the wallpaper, a bright rim.
class _MiniGlass extends StatelessWidget {
  const _MiniGlass({required this.dark, required this.radius, required this.child});

  final bool dark;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [Colors.white.withValues(alpha: 0.16), Colors.white.withValues(alpha: 0.06)]
                  : [Colors.white.withValues(alpha: 0.7), Colors.white.withValues(alpha: 0.38)],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.22 : 0.85), width: 0.8),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The style just picked has icons of its own, which show once the app starts
/// again: a computer can do that now, a phone next time.
class _RestartNotice extends StatelessWidget {
  const _RestartNotice({required this.style});

  final AppStyle style;

  /// The folder the new window opens on: this one's, if it's on disk.
  static String? get _folder {
    final folder = ExplorerTabs.instance.active?.folder.value;
    return folder == null || ExplorerPaths.isVirtual(folder) ? null : folder;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final icons = switch (style.iconSet) {
      IconSet.material => "Android's icons",
      IconSet.cupertino => "iOS's icons",
      IconSet.lucide => 'These icons',
    };
    final restart = StyleRestart.supported;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: colors.secondary,
          borderRadius: BorderRadius.circular(context.look.itemRadius.clamp(8, 16)),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.refreshCw, size: 16, color: colors.mutedForeground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                restart
                    ? '$icons show once Folders starts again.'
                    : '$icons show the next time Folders starts.',
                style: text.bodySmall?.copyWith(color: colors.secondaryForeground),
              ),
            ),
            if (restart) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => StyleRestart.restart(folder: _folder),
                icon: const Icon(LucideIcons.refreshCw, size: 15),
                label: const Text('Restart'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final AppColorThemeSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final swatch = spec.swatch;
    return Tooltip(
      message: spec.name,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 36,
          height: 36,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? colors.foreground : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: swatch,
              border: Border.all(color: colors.border),
            ),
            child: selected ? const Icon(LucideIcons.check, size: 15, color: Colors.white) : null,
          ),
        ),
      ),
    );
  }
}
