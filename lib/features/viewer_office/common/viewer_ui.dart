/// Chrome shared by the document viewers (PDF, e-book, Word, slides and
/// spreadsheets): header actions and menus, floating toolbars and pills,
/// side-panel lists and tabs, status messages, info sheets and dialogs.
///
/// Everything is drawn from the shadcn tokens in `context.colors`, so it
/// follows light/dark mode and every colour scheme. (Candidate for
/// lib/shared/ui once other screens need it.)
library;

import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

export 'package:folder/shared/ui/app_ui.dart';
export 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

// ---------------------------------------------------------------------------
// Document surfaces

/// Colours for the area around rendered pages (PDF pages, Word pages,
/// slides): pages stay white paper in both modes, on a muted surround.
abstract final class ViewerSurface {
  static Color canvas(BuildContext context) => context.colors.muted;

  /// White paper with a hairline edge and a soft shadow.
  static BoxDecoration page(BuildContext context, {Color paper = Colors.white}) {
    final dark = context.isDarkMode;
    return BoxDecoration(
      color: paper,
      border: Border.all(
        color: dark ? Colors.black.withValues(alpha: 0.4) : context.colors.border,
        width: 0.5,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.45 : 0.08),
          blurRadius: dark ? 12 : 8,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Header

/// A header (or toolbar) action: 40×40 ghost button with a Lucide icon.
/// [badge] shows a small dot (e.g. unsaved changes); [busy] a spinner.
class ViewerAction extends StatelessWidget {
  const ViewerAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.badge = false,
    this.busy = false,
    this.selected = false,
    this.color,
    this.size = 40,
    this.iconSize = 20,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool badge;
  final bool busy;
  final bool selected;
  final Color? color;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget glyph = busy
        ? ViewerSpinner(size: iconSize - 4)
        : Icon(icon, size: iconSize);
    if (badge && !busy) {
      glyph = Badge(
        smallSize: 8,
        backgroundColor: colors.primary,
        child: glyph,
      );
    }
    return IconButton(
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      isSelected: selected,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor:
            color ?? (selected ? colors.accentForeground : colors.foreground),
        backgroundColor: selected ? colors.accent : null,
        disabledForegroundColor: colors.mutedForeground.withValues(alpha: 0.5),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: glyph,
    );
  }
}

/// Header row of actions with the standard spacing.
class ViewerActions extends StatelessWidget {
  const ViewerActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Row(mainAxisSize: MainAxisSize.min, children: children);
}

/// A menu button styled like [ViewerAction] (ellipsis by default).
class ViewerMenuButton<T> extends StatelessWidget {
  const ViewerMenuButton({
    super.key,
    required this.itemBuilder,
    required this.onSelected,
    this.icon = LucideIcons.ellipsisVertical,
    this.tooltip = 'More options',
    this.enabled = true,
    this.badge = false,
    this.busy = false,
    this.child,
    this.size = 40,
    this.minMenuWidth = 220,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final bool badge;
  final bool busy;

  /// Replaces the icon button (e.g. a labelled dropdown trigger).
  final Widget? child;
  final double size;
  final double minMenuWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget glyph = busy ? const ViewerSpinner(size: 16) : Icon(icon, size: 20);
    if (badge && !busy) {
      glyph = Badge(
        smallSize: 8,
        backgroundColor: colors.primary,
        child: glyph,
      );
    }
    return PopupMenuButton<T>(
      tooltip: tooltip,
      enabled: enabled && !busy,
      onSelected: onSelected,
      itemBuilder: itemBuilder,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      constraints: BoxConstraints(minWidth: minMenuWidth, maxWidth: 300),
      padding: EdgeInsets.zero,
      style: child != null
          ? null
          : IconButton.styleFrom(
              fixedSize: Size.square(size),
              minimumSize: Size.square(size),
              foregroundColor: colors.foreground,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
      icon: child != null ? null : glyph,
      child: child,
    );
  }
}

/// A dense menu row: Lucide icon, label and an optional check or hint.
/// Disabled rows are dimmed; destructive rows use the destructive colour.
PopupMenuItem<T> viewerMenuItem<T>({
  required T value,
  required String label,
  IconData? icon,
  bool enabled = true,
  bool destructive = false,
  bool checked = false,
  String? hint,
}) {
  return PopupMenuItem<T>(
    value: value,
    enabled: enabled,
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: ViewerMenuRow(
      icon: icon,
      label: label,
      enabled: enabled,
      destructive: destructive,
      checked: checked,
      hint: hint,
    ),
  );
}

/// Thin separator between menu groups.
PopupMenuEntry<T> viewerMenuDivider<T>() => const PopupMenuDivider(height: 9);

/// Small muted heading inside a menu.
PopupMenuEntry<T> viewerMenuLabel<T>(String text) => PopupMenuItem<T>(
      enabled: false,
      height: 28,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Builder(
        builder: (context) => Text(
          text,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
    );

class ViewerMenuRow extends StatelessWidget {
  const ViewerMenuRow({
    super.key,
    required this.label,
    this.icon,
    this.enabled = true,
    this.destructive = false,
    this.checked = false,
    this.hint,
  });

  final String label;
  final IconData? icon;
  final bool enabled;
  final bool destructive;
  final bool checked;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    var fg = destructive ? colors.destructive : colors.popoverForeground;
    var iconColor = destructive ? colors.destructive : colors.mutedForeground;
    if (!enabled) {
      fg = colors.mutedForeground.withValues(alpha: 0.6);
      iconColor = fg;
    }
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(color: fg),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(width: 12),
          Text(hint!, style: text.bodySmall),
        ],
        if (checked) ...[
          const SizedBox(width: 12),
          Icon(LucideIcons.check, size: 16, color: fg),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Floating chrome over documents

/// Small rounded label floating over content (page numbers, zoom level).
class ViewerPill extends StatelessWidget {
  const ViewerPill({
    super.key,
    this.text,
    this.child,
    this.onTap,
    this.semanticsLabel,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  final String? text;
  final Widget? child;
  final VoidCallback? onTap;
  final String? semanticsLabel;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
          color: context.colors.foreground,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final content = Padding(
      padding: padding,
      child: child ??
          Text(text ?? '', style: style, semanticsLabel: semanticsLabel),
    );
    return AppPanel(
      translucent: true,
      borderRadius: 999,
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null
            ? DefaultTextStyle.merge(style: style, child: content)
            : InkWell(
                customBorder: const StadiumBorder(),
                onTap: onTap,
                child: DefaultTextStyle.merge(style: style, child: content),
              ),
      ),
    );
  }
}

/// Floating toolbar card (translucent, bordered) holding [children].
class ViewerToolbar extends StatelessWidget {
  const ViewerToolbar({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.all(4),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      translucent: true,
      padding: padding,
      child: Material(
        type: MaterialType.transparency,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// Vertical hairline between toolbar groups.
class ViewerToolDivider extends StatelessWidget {
  const ViewerToolDivider({super.key, this.height = 20, this.spacing = 4});

  final double height;
  final double spacing;

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: height,
        margin: EdgeInsets.symmetric(horizontal: spacing),
        color: context.colors.border,
      );
}

/// A colour dot for colour tools and palettes; [selected] adds a ring.
class ViewerSwatch extends StatelessWidget {
  const ViewerSwatch({
    super.key,
    required this.color,
    this.size = 20,
    this.selected = false,
  });

  final Color color;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: colors.foreground.withValues(alpha: 0.18),
        ),
      ),
    );
    if (!selected) return Padding(padding: const EdgeInsets.all(3), child: dot);
    return Container(
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colors.ring, width: 2),
      ),
      child: dot,
    );
  }
}

/// Borderless search input for floating find bars.
class ViewerSearchField extends StatelessWidget {
  const ViewerSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hintText = 'Find in document',
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.showIcon = true,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool showIcon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyMedium,
      cursorColor: colors.foreground,
      decoration: InputDecoration(
        hintText: hintText,
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        prefixIcon: showIcon
            ? Icon(LucideIcons.search, size: 16, color: colors.mutedForeground)
            : null,
        prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
    );
  }
}

/// Small spinner in the current foreground colour.
class ViewerSpinner extends StatelessWidget {
  const ViewerSpinner({super.key, this.size = 16, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: color ?? context.colors.mutedForeground,
        ),
      );
}

/// Dims the content and shows [label] with a spinner while work runs.
class ViewerBusyOverlay extends StatelessWidget {
  const ViewerBusyOverlay({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: ColoredBox(
        color: context.colors.background.withValues(alpha: 0.5),
        child: Center(
          child: AppPanel(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ViewerSpinner(size: 18),
                const SizedBox(width: 12),
                Text(label, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// States

/// Centered empty/error/locked state: icon tile, title, message, actions.
class ViewerMessage extends StatelessWidget {
  const ViewerMessage({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actions = const [],
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final List<Widget> actions;

  /// Tints the icon tile with the destructive colour (errors).
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final tint = destructive ? colors.destructive : colors.mutedForeground;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: destructive
                      ? colors.destructive.withValues(alpha: 0.12)
                      : colors.muted,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 22, color: tint),
              ),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: text.titleMedium),
              if (message != null && message!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.mutedForeground,
                  ),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Side panels

/// Title row of a side panel or drawer, with optional actions and close.
class ViewerPanelHeader extends StatelessWidget {
  const ViewerPanelHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.onClose,
    this.closeTooltip = 'Hide panel',
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                ],
              ),
            ),
            ...actions,
            if (onClose != null)
              ViewerAction(
                icon: LucideIcons.x,
                tooltip: closeTooltip,
                onPressed: onClose,
                iconSize: 18,
              ),
          ],
        ),
      ),
    );
  }
}

/// shadcn-style tab list: a muted track with the selected tab raised.
class ViewerTabs extends StatelessWidget {
  const ViewerTabs({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<String> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = Theme.of(context).textTheme.labelLarge;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == index,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: i == index
                        ? BoxDecoration(
                            color: colors.background,
                            borderRadius: BorderRadius.circular(6),
                            border: context.isDarkMode
                                ? Border.all(color: colors.border)
                                : null,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.06),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          )
                        : null,
                    child: Text(
                      tabs[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style?.copyWith(
                        fontSize: 13,
                        color: i == index
                            ? colors.foreground
                            : colors.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row in a side-panel list. The selected row gets the accent background.
class ViewerListTile extends StatelessWidget {
  const ViewerListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.onLongPress,
    this.indent = 0,
    this.emphasis = false,
    this.maxLines = 2,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double indent;

  /// Semi-bold title (top-level outline entries).
  final bool emphasis;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final fg = !enabled
        ? colors.mutedForeground
        : selected
            ? colors.accentForeground
            : colors.foreground;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                12 + indent,
                4,
                trailing == null ? 12 : 4,
                4,
              ),
              child: Row(
                children: [
                  if (leading != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(
                        size: 16,
                        color: selected ? fg : colors.mutedForeground,
                      ),
                      child: leading!,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: maxLines,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium?.copyWith(
                            color: fg,
                            fontWeight: selected || emphasis
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall,
                          ),
                      ],
                    ),
                  ),
                  if (trailing != null)
                    IconTheme.merge(
                      data: IconThemeData(size: 16, color: colors.mutedForeground),
                      child: trailing!,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted heading inside a panel or sheet.
class ViewerSectionLabel extends StatelessWidget {
  const ViewerSectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 16, 6),
    this.trailing,
  });

  final String text;
  final EdgeInsetsGeometry padding;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            ?trailing,
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Sheets and dialogs

/// Title and optional description at the top of a bottom sheet.
class ViewerSheetHeader extends StatelessWidget {
  const ViewerSheetHeader({
    super.key,
    required this.title,
    this.description,
    this.trailing,
  });

  final String title;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.titleLarge?.copyWith(fontSize: 18)),
                if (description != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    description!,
                    style: text.bodyMedium?.copyWith(
                      color: context.colors.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Bordered card of label/value rows.
class ViewerInfoTable extends StatelessWidget {
  const ViewerInfoTable({super.key, required this.rows, this.labelWidth = 140});

  final List<(String, String)> rows;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: colors.border),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Text(
                      rows[i].$1,
                      style: text.bodyMedium?.copyWith(
                        color: colors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      rows[i].$2,
                      textAlign: TextAlign.end,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// File/document details in a bottom sheet.
Future<void> showViewerInfoSheet(
  BuildContext context, {
  required String title,
  String? description,
  required List<(String, String)> rows,
}) {
  return AppSheet.show<void>(
    context,
    style: SheetStyle.side,
    maxHeightFraction: 0.8,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ViewerSheetHeader(title: title, description: description),
        ViewerInfoTable(rows: rows),
      ],
    ),
  );
}

/// Button style for a destructive confirmation.
ButtonStyle viewerDestructiveStyle(BuildContext context) =>
    FilledButton.styleFrom(
      backgroundColor: context.colors.destructive,
      foregroundColor: context.colors.destructiveForeground,
    );

/// Yes/no confirmation dialog. Returns true when confirmed.
Future<bool> showViewerConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive ? viewerDestructiveStyle(context) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

// ---------------------------------------------------------------------------
// Sliders

/// shadcn slider look for [child]'s sliders: a ringed thumb (visible on
/// dark surfaces too) and no tick marks.
class ViewerSliderTheme extends StatelessWidget {
  const ViewerSliderTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        thumbShape: _RingThumbShape(
          fill: colors.background,
          ring: colors.primary,
          disabledRing: colors.mutedForeground.withValues(alpha: 0.5),
        ),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        overlayColor: colors.ring.withValues(alpha: 0.15),
      ),
      child: child,
    );
  }
}

class _RingThumbShape extends SliderComponentShape {
  const _RingThumbShape({
    required this.fill,
    required this.ring,
    required this.disabledRing,
  });

  final Color fill;
  final Color ring;
  final Color disabledRing;
  static const _radius = 9.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final enabled = enableAnimation.value > 0.5;
    canvas.drawCircle(
      center.translate(0, 1),
      _radius,
      Paint()
        ..color = const Color(0x22000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawCircle(center, _radius, Paint()..color = fill);
    canvas.drawCircle(
      center,
      _radius - 1,
      Paint()
        ..color = enabled ? ring : disabledRing
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }
}
