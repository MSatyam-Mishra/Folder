import 'package:folder/shared/ui/app_sidebar.dart';
import 'package:flutter/material.dart';

/// Side drawer in the app's sidebar style.
class GlossyDrawer extends StatelessWidget {
  const GlossyDrawer({super.key, required this.child, this.width});

  final Widget child;
  final double? width;

  @override
  Widget build(BuildContext context) => AppSidebar(width: width, child: child);
}
