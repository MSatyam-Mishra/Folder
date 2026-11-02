import 'package:explorer/core/platform/desktop.dart';
import 'package:flutter/material.dart';

/// Text in [child] about 1 px smaller (14 px becomes 13) on computers, for
/// panes read up close beside the files: the sidebar and Options. Phones
/// keep their sizes.
class CompactText extends StatelessWidget {
  const CompactText({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Desktop.isDesktop) return child;
    final media = MediaQuery.of(context);
    // On top of the system's own text size.
    final scale = media.textScaler.scale(14) / 14 * (13 / 14);
    return MediaQuery(data: media.copyWith(textScaler: TextScaler.linear(scale)), child: child);
  }
}
