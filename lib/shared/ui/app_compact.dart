import 'package:folder/core/platform/desktop.dart';
import 'package:flutter/material.dart';

/// Text in [child] about [by] px smaller (with 1, 14 px becomes 13) on
/// computers, for panes read up close beside the files: the sidebar and
/// Options. Phones keep their sizes, unless [onPhones].
class CompactText extends StatelessWidget {
  const CompactText({super.key, required this.child, this.by = 1, this.onPhones = false});

  final Widget child;
  final double by;
  final bool onPhones;

  @override
  Widget build(BuildContext context) {
    if (!Desktop.isDesktop && !onPhones) return child;
    final media = MediaQuery.of(context);
    // On top of the system's own text size.
    final scale = media.textScaler.scale(14) / 14 * ((14 - by) / 14);
    return MediaQuery(data: media.copyWith(textScaler: TextScaler.linear(scale)), child: child);
  }
}
