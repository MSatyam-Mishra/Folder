import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';

/// A label / value row in the properties sheet.
class InfoRow extends StatelessWidget {
  final String title;
  final String content;

  /// Shows [content] in the muted colour (placeholders like "Calculating…").
  final bool muted;

  /// Lets the user select and copy [content] (paths).
  final bool selectable;

  const InfoRow({
    super.key,
    required this.title,
    required this.content,
    this.muted = false,
    this.selectable = false,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final valueStyle = text.bodyMedium?.copyWith(
      color: muted ? context.colors.mutedForeground : null,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(title, style: text.bodySmall?.copyWith(fontSize: 13)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: selectable
              ? SelectableText(content, style: valueStyle)
              : Text(content, style: valueStyle),
        ),
      ],
    );
  }
}
