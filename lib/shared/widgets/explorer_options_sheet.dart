import 'package:folders/features/file_explorere/explorer_zoom.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/window_effects.dart';
import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/ios_style.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/widgets/theme_choices.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
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
    // iOS: a large title, and rows on rounded cards.
    final grouped = context.look.groupedLists;

    // An icon beside each segment's label only where there's room for both:
    // on a phone it squeezes the words onto two lines ("Galler y").
    return LayoutBuilder(builder: (context, box) {
    final segmentIcons = !grouped && box.maxWidth >= 440;
    return CompactText(by: 2, onPhones: true, child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Options',
          style: grouped ? text.headlineMedium?.copyWith(fontSize: 30, color: text.titleLarge?.color) : text.titleLarge,
        ),
        const SizedBox(height: 4),
        Text('View, sorting and appearance.', style: text.bodySmall),
        const _Heading('Layout'),
        _Group([
        SegmentedButton<ViewMode>(
          style: _compactSegments,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: ViewMode.list, icon: segmentIcons ? const Icon(LucideIcons.list, size: 15) : null, label: Text('List')),
            ButtonSegment(value: ViewMode.grid, icon: segmentIcons ? const Icon(LucideIcons.layoutGrid, size: 15) : null, label: Text('Grid')),
            ButtonSegment(value: ViewMode.compact, icon: segmentIcons ? const Icon(LucideIcons.rows3, size: 15) : null, label: Text('Dense')),
            ButtonSegment(value: ViewMode.gallery, icon: segmentIcons ? const Icon(LucideIcons.images, size: 15) : null, label: Text('Gallery')),
          ],
          selected: {fileState.viewMode},
          onSelectionChanged: (s) => onViewModeChanged(s.first),
        ),
        if (!grouped) const SizedBox(height: 12),
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
          builder: (context, setState) => _SwitchRow(
            contentPadding: const EdgeInsets.only(top: 8),
            title: 'Show hidden files',
            subtitle: 'Files starting with a dot, and system files',
            value: FolderPrefsService().showHidden,
            onChanged: (value) async {
              await FolderPrefsService().setShowHidden(value);
              setState(() {});
              onShowHiddenChanged();
            },
          ),
        ),
        ]),
        const _Heading('Sort by'),
        _Group([
        Row(
          children: [
            Expanded(
              child: SegmentedButton<SortOption>(
                style: _compactSegments,
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: SortOption.name, icon: segmentIcons ? const Icon(LucideIcons.arrowDownAZ, size: 15) : null, label: Text('Name')),
                  ButtonSegment(value: SortOption.date, icon: segmentIcons ? const Icon(LucideIcons.calendarClock, size: 15) : null, label: Text('Date')),
                  ButtonSegment(value: SortOption.size, icon: segmentIcons ? const Icon(LucideIcons.ruler, size: 15) : null, label: Text('Size')),
                  ButtonSegment(value: SortOption.type, icon: segmentIcons ? const Icon(LucideIcons.shapes, size: 15) : null, label: Text('Type')),
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
        ]),
        ThemeChoices(
          heading: _Heading.new,
          section: _Group.new,
          afterMode: [
            if (WindowEffects.supported) ...[
              const _Heading('Window'),
              _Group([
              // The system's materials behind the window, and how much of them
              // shows through the app.
              SegmentedButton<WindowBackdrop>(
                style: _compactSegments,
                showSelectedIcon: false,
                segments: [
                  for (final backdrop in WindowBackdrop.available)
                    ButtonSegment(
                      value: backdrop,
                      icon: segmentIcons ? Icon(backdrop.icon, size: 15) : null,
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
              ]),
            ],
          ],
        ),
        if (grouped) const SizedBox(height: 24),
        _Group([
        _SwitchRow(
          contentPadding: EdgeInsets.zero,
          icon: LucideIcons.images,
          value: settings.showThumbnails,
          onChanged: cubit.setShowThumbnails,
          title: 'Thumbnails',
          subtitle: 'Pictures of images, videos, PDFs and documents instead of their icons',
        ),
        // Android's style is Material's, without glass; iOS's always has it.
        if (!Desktop.isDesktop && settings.style != AppStyle.android && !settings.style.glass)
          _SwitchRow(
            contentPadding: EdgeInsets.zero,
            icon: LucideIcons.droplets,
            value: settings.liquidGlass,
            onChanged: cubit.setLiquidGlass,
            title: 'Liquid glass',
            subtitle: 'See-through, blurred bars, menus and sheets',
          ),
        ]),
        const _Heading('File icons'),
        _Group([
        // Android and iOS draw their own.
        if (context.look.fileArt != null)
          Text('The ${settings.style.label} style draws its own file icons.', style: text.bodySmall)
        else
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
        ]),
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
    });
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
    // iOS: small grey capitals over the card, in line with its text.
    if (context.look.groupedLists) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 7),
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 12,
                letterSpacing: 0.3,
                color: context.colors.mutedForeground,
              ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}

/// A section's rows: as they are, or for iOS on a rounded card, set apart by
/// hairlines.
class _Group extends StatelessWidget {
  const _Group(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!context.look.groupedLists) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(color: IosStyle.groupedCard(dark), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0) Divider(height: 0.5, thickness: 0.5, indent: 16, color: IosStyle.separator(dark)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: child),
          ],
        ],
      ),
    );
  }
}

/// A setting switched on or off: Material's switch, or iOS's in its style.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    required this.contentPadding,
    this.subtitle,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final icon = this.icon;
    if (!context.look.groupedLists) {
      return SwitchListTile(
        contentPadding: contentPadding,
        secondary: icon == null ? null : Icon(icon, size: 17),
        value: value,
        onChanged: onChanged,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
      );
    }
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: context.colors.primary),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.bodyMedium),
                  if (subtitle != null) Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 12),
            CupertinoSwitch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: dark ? IosStyle.greenDark : IosStyle.green,
            ),
          ],
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
    final grouped = context.look.groupedLists;
    return Material(
      color: grouped ? IosStyle.groupedCard(Theme.of(context).brightness == Brightness.dark) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: grouped ? BorderSide.none : BorderSide(color: colors.border),
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
