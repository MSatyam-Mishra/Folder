import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/theme/app_color_theme.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/core/theme/icon_strokes.dart';
import 'package:folders/core/theme/material_style.dart';
import 'package:folders/core/theme/style_restart.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
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
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final style in AppStyle.values)
              _StyleCard(
                style: style,
                settings: settings,
                selected: settings.style == style,
                onTap: () => cubit.setStyle(style),
              ),
          ],
        ),
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

/// A style, shown as a small window in its colours.
class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.style,
    required this.settings,
    required this.selected,
    required this.onTap,
  });

  final AppStyle style;
  final AppThemeSettings settings;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final brightness = style.darkOnly ? Brightness.dark : Theme.of(context).brightness;
    final scheme = style.schemeFor(brightness, color: settings.colorTheme) ?? settings.colorTheme.schemeFor(brightness);
    final look = style.look(
      brightness,
      colors: style == AppStyle.android ? MaterialStyle.scheme(settings.colorTheme, brightness) : null,
    );
    final folder = look.folder ?? (scheme.primary, scheme.primary);
    final palette = look.iconPalette;
    Widget line(double width, Color color) => Container(
          width: width,
          height: 3,
          margin: const EdgeInsets.only(bottom: 4),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        );
    return Semantics(
      button: true,
      selected: selected,
      label: style.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 122,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? colors.primary : colors.border, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(style.controlRadius),
                child: SizedBox(
                  height: 62,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // The sidebar, its icons in the style's colours.
                      Container(
                        width: 34,
                        color: scheme.muted,
                        padding: const EdgeInsets.fromLTRB(5, 8, 5, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < 4; i++)
                              line(
                                i.isEven ? 22 : 16,
                                palette?[i % palette.length] ?? look.sidebarIcons ?? scheme.mutedForeground,
                              ),
                          ],
                        ),
                      ),
                      // The items: a folder, a selected row, a detail.
                      Expanded(
                        child: Container(
                          color: scheme.background,
                          padding: const EdgeInsets.fromLTRB(6, 7, 6, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      color: folder.$1,
                                      borderRadius: BorderRadius.circular(2),
                                      border: Border(top: BorderSide(color: folder.$2, width: 2)),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(child: line(30, scheme.foreground)),
                                ],
                              ),
                              Container(
                                height: 11,
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                decoration: BoxDecoration(
                                  color: scheme.accent,
                                  borderRadius: BorderRadius.circular(style.controlRadius / 2),
                                ),
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 4, top: 4),
                                child: line(28, scheme.accentForeground),
                              ),
                              Row(
                                children: [
                                  Expanded(child: line(24, scheme.mutedForeground)),
                                  Container(
                                    width: 8,
                                    height: 8,
                                    margin: const EdgeInsets.only(bottom: 4),
                                    decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  style.label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.foreground,
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
