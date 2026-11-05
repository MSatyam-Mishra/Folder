import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

/// A centred icon and message for an empty list.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.padding = EdgeInsets.zero,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final EdgeInsets padding;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: ViewerMessage(
        shrinkWrap: true,
        icon: icon,
        title: title,
        message: message,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        actions: [?action],
      ),
    );
  }
}
