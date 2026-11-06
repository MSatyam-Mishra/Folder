import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import 'grid_colors.dart';

/// Result of the colour picker; [color] null means automatic / no fill.
class ColorChoice {
  const ColorChoice(this.color);
  final int? color;
}

Future<ColorChoice?> showColorPalette(
  BuildContext context, {
  required String title,
  required String noneLabel,
  int? current,
}) {
  return showDialog<ColorChoice>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                icon: const Icon(LucideIcons.ban, size: 16),
                label: Text(noneLabel),
                onPressed: () => Navigator.pop(context, const ColorChoice(null)),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  for (final c in kSheetPalette)
                    Semantics(
                      button: true,
                      selected: current == c,
                      label: '#${(c & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                      child: InkResponse(
                        radius: 20,
                        onTap: () => Navigator.pop(context, ColorChoice(c)),
                        child: SizedBox.square(
                          dimension: 40,
                          child: Center(
                            child: ViewerSwatch(
                              color: Color(c),
                              size: 26,
                              selected: current == c,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ],
      );
    },
  );
}
