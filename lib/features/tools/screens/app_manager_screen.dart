import 'package:installed_apps/app_info.dart';
import 'package:folders/core/repositories/app_repository.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

class AppManagerScreen extends StatefulWidget {
  const AppManagerScreen({super.key});

  @override
  State<AppManagerScreen> createState() => _AppManagerScreenState();
}

class _AppManagerScreenState extends State<AppManagerScreen> {
  final AppRepository _repository = AppRepository();
  final TextEditingController _search = TextEditingController();
  List<AppInfo> _apps = [];
  bool _isLoading = true;
  String? _error;
  bool _showSystemApps = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadApps();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadApps() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final apps = await _repository.getInstalledApps();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  List<AppInfo> get _filteredApps {
    final query = _query.trim().toLowerCase();
    return [
      for (final app in _apps)
        if ((_showSystemApps || !app.isSystemApp) &&
            (query.isEmpty ||
                app.name.toLowerCase().contains(query) ||
                app.packageName.toLowerCase().contains(query)))
          app,
    ];
  }

  Future<void> _onAction(AppInfo app, _AppAction action) async {
    switch (action) {
      case _AppAction.open:
        await _repository.openApp(app.packageName);
      case _AppAction.settings:
        await _repository.openAppSettings(app.packageName);
      case _AppAction.uninstall:
        await _repository.uninstallApp(app.packageName);
    }
  }

  @override
  Widget build(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final statePadding = EdgeInsets.fromLTRB(24, top + 24, 24, 24);

    final Widget body;
    if (_isLoading) {
      body = Padding(
        padding: EdgeInsets.only(top: top),
        child: const Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (_error != null) {
      body = ExplorerEmptyState(
        padding: statePadding,
        destructive: true,
        icon: LucideIcons.layoutGrid,
        title: "Couldn't list your apps",
        description: 'The app manager is available on Android.',
        actions: [
          FilledButton.icon(
            onPressed: _loadApps,
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('Try again'),
          ),
        ],
      );
    } else {
      body = _buildList(context, top);
    }

    return ExplorerScaffold(
      title: 'App manager',
      trailing: _isLoading || _error != null
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                tooltip: 'Refresh',
                onPressed: _loadApps,
                icon: const Icon(LucideIcons.refreshCw),
              ),
            ),
      body: body,
    );
  }

  Widget _buildList(BuildContext context, double top) {
    final text = Theme.of(context).textTheme;
    final apps = _filteredApps;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final side = wide ? 24.0 : 16.0;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, top + 16, side, 8),
          sliver: SliverToBoxAdapter(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _search,
                      onChanged: (v) => setState(() => _query = v),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search apps',
                        prefixIcon: const Icon(LucideIcons.search, size: 16),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                icon: const Icon(LucideIcons.x, size: 16),
                                onPressed: () => setState(() {
                                  _search.clear();
                                  _query = '';
                                }),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${apps.length} '
                            '${apps.length == 1 ? 'app' : 'apps'}',
                            style: text.bodySmall,
                          ),
                        ),
                        FilterChip(
                          showCheckmark: true,
                          label: const Text('System apps'),
                          selected: _showSystemApps,
                          onSelected: (v) =>
                              setState(() => _showSystemApps = v),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (apps.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ExplorerEmptyState(
              icon: LucideIcons.searchX,
              title: 'No apps found',
              description: _query.isEmpty
                  ? 'Turn on "System apps" to see apps that came with the '
                      'device.'
                  : 'No app matches "$_query".',
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: wide ? side - 8 : 0),
            sliver: SliverList.builder(
              itemCount: apps.length,
              itemBuilder: (context, index) => Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 736),
                  child: _AppRow(
                    app: apps[index],
                    onAction: (a) => _onAction(apps[index], a),
                  ),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
        ),
      ],
    );
  }
}

enum _AppAction { open, settings, uninstall }

class _AppRow extends StatelessWidget {
  const _AppRow({required this.app, required this.onAction});

  final AppInfo app;
  final ValueChanged<_AppAction> onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final icon = app.icon;

    Future<void> showMenu(BuildContext anchor) async {
      final action = await ExplorerMenu.show<_AppAction>(
        anchor,
        items: [
          ExplorerMenu.item(
            anchor,
            value: _AppAction.open,
            label: 'Open',
            icon: LucideIcons.squareArrowOutUpRight,
            enabled: app.isLaunchableApp,
          ),
          ExplorerMenu.item(
            anchor,
            value: _AppAction.settings,
            label: 'App info',
            icon: LucideIcons.settings,
          ),
          ExplorerMenu.item<_AppAction>(
            anchor,
            value: _AppAction.open,
            label: 'Export APK (unavailable)',
            icon: LucideIcons.download,
            enabled: false,
          ),
          ExplorerMenu.divider(),
          ExplorerMenu.item(
            anchor,
            value: _AppAction.uninstall,
            label: 'Uninstall',
            icon: LucideIcons.trash2,
            destructive: true,
          ),
        ],
      );
      if (action != null) onAction(action);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Builder(
        builder: (anchor) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showMenu(anchor),
          child: SizedBox(
            height: 60,
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: icon != null
                        ? Image.memory(
                            icon,
                            width: 40,
                            height: 40,
                            cacheWidth: 120,
                            gaplessPlayback: true,
                          )
                        : Container(
                            width: 40,
                            height: 40,
                            color: colors.muted,
                            child: Icon(
                              LucideIcons.smartphone,
                              size: 18,
                              color: colors.mutedForeground,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${app.packageName} · ${app.versionName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Actions',
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                    onPressed: () => showMenu(anchor),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
