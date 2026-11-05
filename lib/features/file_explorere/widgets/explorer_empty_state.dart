import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';

/// Centered empty / error / permission state in the shadcn style: a muted
/// icon in a circle, a title, a short description and optional actions.
class ExplorerEmptyState extends StatelessWidget {
  const ExplorerEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.actions = const [],
    this.destructive = false,
    this.padding = const EdgeInsets.all(24),
  });

  final IconData icon;
  final String title;
  final String? description;

  /// Buttons under the description (e.g. an OutlinedButton and a
  /// FilledButton), laid out in a wrapping row.
  final List<Widget> actions;

  /// Tints the icon with the destructive colour (errors).
  final bool destructive;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final tint = destructive ? colors.destructive : colors.mutedForeground;
    return Center(
      child: SingleChildScrollView(
        padding: padding,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: destructive
                      ? colors.destructive.withValues(alpha: 0.1)
                      : colors.muted,
                ),
                child: Icon(icon, size: 24, color: tint),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: text.titleMedium,
              ),
              if (description != null) ...[
                const SizedBox(height: 6),
                Text(
                  description!,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color: colors.mutedForeground,
                    height: 1.45,
                  ),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
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
