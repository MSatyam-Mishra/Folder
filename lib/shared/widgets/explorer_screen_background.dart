import 'package:folders/shared/ui/app_tokens.dart';
import 'package:flutter/material.dart';

/// Page background in the current theme.
class ExplorerScreenBackground extends StatelessWidget {
  const ExplorerScreenBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: context.colors.background, child: child);
}
