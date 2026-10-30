import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/shared/ui/app_tokens.dart';
import 'package:flutter/material.dart';

/// Navigation drawer in the style of the shadcn/ui sidebar.
class AppSidebar extends StatelessWidget {
  const AppSidebar({super.key, required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: width,
      child: SafeArea(child: child),
    );
  }
}

/// Muted section heading inside the sidebar.
class AppSidebarSection extends StatelessWidget {
  const AppSidebarSection(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: context.colors.mutedForeground,
                    letterSpacing: 0.2,
                  ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One row in the sidebar: icon, label, optional detail and trailing widget.
class AppSidebarItem extends StatelessWidget {
  const AppSidebarItem({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    this.trailing,
    this.selected = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final Widget? trailing;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final fg = selected ? colors.accentForeground : colors.foreground;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  // Finder tints the sidebar's icons; Sweet and Dracula
                  // colour them.
                  color: selected ? fg : context.look.sidebarIcons ?? context.look.iconColor(icon, fg),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          color: fg,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  DefaultTextStyle.merge(
                    style: text.bodySmall,
                    child: trailing!,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
