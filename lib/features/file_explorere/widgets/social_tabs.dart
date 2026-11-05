import 'dart:ui' show ImageFilter;

import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/services/social_files.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Above an app's files (WhatsApp...): "All files", then a tab for each of its
/// folders.
class SocialTabs extends StatefulWidget {
  const SocialTabs({super.key, required this.path});

  static const double height = 48;

  final String path;

  @override
  State<SocialTabs> createState() => _SocialTabsState();
}

class _SocialTabsState extends State<SocialTabs> {
  List<String> _tabs = const [];

  SocialApp? get _app => SocialApp.byId(ExplorerPaths.socialAppOf(widget.path) ?? '');

  Future<void> _load() async {
    final app = _app;
    if (app == null) return;
    final tabs = await SocialFiles.tabs(app);
    if (mounted) setState(() => _tabs = tabs);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SocialTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (ExplorerPaths.socialAppOf(oldWidget.path) != ExplorerPaths.socialAppOf(widget.path)) _load();
  }

  Widget _tab(String label, String? tab) {
    final colors = context.colors;
    final selected = ExplorerPaths.socialTabOf(widget.path) == tab;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? colors.primary : colors.muted,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: selected
              ? null
              : () => context.read<FileExplorerBloc>().add(
                    LoadDirectory(ExplorerPaths.socialPath(ExplorerPaths.socialAppOf(widget.path)!, tab)),
                  ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: selected ? colors.primaryForeground : colors.foreground,
                  ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: colors.background.withValues(alpha: colors.background.a * 0.82),
          child: SizedBox(
            height: SocialTabs.height,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                _tab(SocialFiles.allFiles, null),
                for (final tab in _tabs) _tab(tab, tab),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
