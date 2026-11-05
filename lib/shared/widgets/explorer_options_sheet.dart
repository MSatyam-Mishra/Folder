import 'package:explorer/features/file_explorere/explorer_zoom.dart';
import 'package:explorer/core/platform/window_effects.dart';
import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/core/theme/app_color_theme.dart';
import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/shared/file_icons/file_icons.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Options sheet: view, sorting, appearance and sharing.
class ExplorerOptionsSheet extends StatelessWidget {
  const ExplorerOptionsSheet({
    super.key,
    required this.fileState,
    required this.onHttpShare,
    required this.onSortChanged,
    required this.onViewModeChanged,
    required this.onShowHiddenChanged,
  });

  final FileExplorerLoaded fileState;
  final VoidCallback onHttpShare;
  final void Function(SortOption option, SortOrder order) onSortChanged;
  final void Function(ViewMode mode) onViewModeChanged;

  /// "Show hidden files" was switched (saved already).
  final VoidCallback onShowHiddenChanged;

  static Future<void> show(
    BuildContext context, {
    required FileExplorerLoaded fileState,
    required VoidCallback onHttpShare,
    required void Function(SortOption option, SortOrder order) onSortChanged,
    required void Function(ViewMode mode) onViewModeChanged,
    required VoidCallback onShowHiddenChanged,
  }) {
    return AppSheet.show<void>(
      context,
    style: SheetStyle.side,
      child: ExplorerOptionsSheet(
        fileState: fileState,
        onHttpShare: onHttpShare,
        onSortChanged: onSortChanged,
        onViewModeChanged: onViewModeChanged,
        onShowHiddenChanged: onShowHiddenChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeCubit>().state;
    final cubit = context.read<ThemeCubit>();
    final text = Theme.of(context).textTheme;
    final ascending = fileState.sortOrder == SortOrder.ascending;

    return CompactText(by: 2, onPhones: true, child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Options', style: text.titleLarge),
        const SizedBox(height: 4),
        Text('View, sorting and appearance.', style: text.bodySmall),
        const _Heading('Layout'),
        SegmentedButton<ViewMode>(
          style: _compactSegments,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ViewMode.list, icon: Icon(LucideIcons.list, size: 15), label: Text('List')),
            ButtonSegment(value: ViewMode.grid, icon: Icon(LucideIcons.layoutGrid, size: 15), label: Text('Grid')),
            ButtonSegment(value: ViewMode.compact, icon: Icon(LucideIcons.rows3, size: 15), label: Text('Dense')),
            ButtonSegment(value: ViewMode.gallery, icon: Icon(LucideIcons.images, size: 15), label: Text('Gallery')),
          ],
          selected: {fileState.viewMode},
          onSelectionChanged: (s) => onViewModeChanged(s.first),
        ),
        const SizedBox(height: 12),
        // Also Ctrl+wheel or a pinch over the files, and Ctrl+plus/minus.
        ValueListenableBuilder<double>(
          valueListenable: ExplorerZoom.instance,
          builder: (context, zoom, _) => Row(
            children: [
              Tooltip(
                message: 'Icon size',
                child: Icon(LucideIcons.image, size: 13, color: context.colors.mutedForeground),
              ),
              Expanded(
                child: Slider(
                  value: zoom,
                  min: ExplorerZoom.min,
                  max: ExplorerZoom.max,
                  label: '${(zoom * 100).round()}%',
                  onChanged: ExplorerZoom.instance.set,
                ),
              ),
              Icon(LucideIcons.image, size: 21, color: context.colors.mutedForeground),
              SizedBox(
                width: 48,
                child: Text('${(zoom * 100).round()}%', textAlign: TextAlign.end, style: text.bodySmall),
              ),
            ],
          ),
        ),
        StatefulBuilder(
          builder: (context, setState) => SwitchListTile(
            contentPadding: const EdgeInsets.only(top: 8),
            title: const Text('Show hidden files'),
            subtitle: const Text('Files starting with a dot, and system files'),
            value: FolderPrefsService().showHidden,
            onChanged: (value) async {
              await FolderPrefsService().setShowHidden(value);
              setState(() {});
              onShowHiddenChanged();
            },
          ),
        ),
        const _Heading('Sort by'),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<SortOption>(
                style: _compactSegments,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: SortOption.name, icon: Icon(LucideIcons.arrowDownAZ, size: 15), label: Text('Name')),
                  ButtonSegment(value: SortOption.date, icon: Icon(LucideIcons.calendarClock, size: 15), label: Text('Date')),
                  ButtonSegment(value: SortOption.size, icon: Icon(LucideIcons.ruler, size: 15), label: Text('Size')),
                  ButtonSegment(value: SortOption.type, icon: Icon(LucideIcons.shapes, size: 15), label: Text('Type')),
                ],
                selected: {fileState.sortOption},
                onSelectionChanged: (s) =>
                    onSortChanged(s.first, fileState.sortOrder),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => onSortChanged(
                fileState.sortOption,
                ascending ? SortOrder.descending : SortOrder.ascending,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(40, 40),
                padding: EdgeInsets.zero,
              ),
              child: Tooltip(
                message: ascending ? 'Ascending' : 'Descending',
                child: Icon(
                  ascending
                      ? LucideIcons.arrowUpNarrowWide
                      : LucideIcons.arrowDownWideNarrow,
                  size: 17,
                ),
              ),
            ),
          ],
        ),
        const _Heading('Style'),
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
        const _Heading('Theme'),
        SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: ThemeMode.system,
              icon: Icon(LucideIcons.monitor, size: 15),
              label: Text('System'),
            ),
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(LucideIcons.sun, size: 15),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(LucideIcons.moon, size: 15),
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
        if (WindowEffects.supported) ...[
          const _Heading('Window'),
          // The system's materials behind the window, and how much of them
          // shows through the app.
          SegmentedButton<WindowBackdrop>(
            style: _compactSegments,
            showSelectedIcon: false,
            segments: [
              for (final backdrop in WindowBackdrop.available)
                ButtonSegment(
                  value: backdrop,
                  icon: Icon(backdrop.icon, size: 15),
                  label: Text(backdrop.label),
                ),
            ],
            selected: {settings.backdrop},
            onSelectionChanged: (s) => cubit.setBackdrop(s.first),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(settings.backdrop.description, style: text.bodySmall),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(LucideIcons.blend, size: 15, color: context.colors.mutedForeground),
              const SizedBox(width: 10),
              Text('Transparency', style: text.bodyMedium),
              const Spacer(),
              Text('${(settings.transparency * 100).round()}%', style: text.bodySmall),
            ],
          ),
          Slider(
            value: settings.transparency,
            divisions: 20,
            label: '${(settings.transparency * 100).round()}%',
            onChanged: settings.windowEffect ? (v) => cubit.setTransparency(v, save: false) : null,
            onChangeEnd: settings.windowEffect ? cubit.setTransparency : null,
          ),
        ],
        // The other styles come with their own colours.
        if (settings.style == AppStyle.standard) ...[
          const _Heading('Color'),
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
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(LucideIcons.images, size: 17),
          value: settings.showThumbnails,
          onChanged: cubit.setShowThumbnails,
          title: const Text('Thumbnails'),
          subtitle: const Text('Pictures of images, videos, PDFs and documents instead of their icons'),
        ),
        const _Heading('File icons'),
        SegmentedButton<FileIconStyle>(
          showSelectedIcon: false,
          segments: [
            for (final style in FileIconStyle.values)
              ButtonSegment(
                value: style,
                icon: FileIcon(path: 'preview.pdf', size: 17, style: style),
                label: Text(style.label),
              ),
          ],
          selected: {settings.fileIconStyle},
          onSelectionChanged: (s) => cubit.setFileIconStyle(s.first),
        ),
        const _Heading('Sharing'),
        _ActionRow(
          icon: LucideIcons.wifi,
          title: 'Wi-Fi sharing',
          subtitle: 'Open this folder from a browser or FTP app on your Wi-Fi',
          onTap: () {
            Navigator.pop(context);
            onHttpShare();
          },
        ),
      ],
    ));
  }
}

/// Room for an icon and a word in each of four segments.
const _compactSegments = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 6)),
  visualDensity: VisualDensity.compact,
);

class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
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
    final scheme = style.schemeFor(brightness) ?? settings.colorTheme.schemeFor(brightness);
    final look = style.look(brightness);
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
            child: selected
                ? const Icon(LucideIcons.check, size: 15, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 17, color: colors.foreground),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(subtitle, style: text.bodySmall),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 17,
                color: colors.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
