import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/platform/windows_locations.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/toolbox/app_delete.dart';
import 'package:folders/core/services/toolbox/storage_scanner.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/ios_style.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/toolbox/storage_treemap.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// A drive or a folder the analyzer offers to scan.
class StoragePlace {
  const StoragePlace(this.title, this.path, this.icon, {this.isDrive = false});

  final String title;
  final String path;
  final IconData icon;

  /// A whole drive, whose used space a scan's progress is measured against.
  final bool isDrive;
}

/// Shows what takes up the space on a drive or in a folder: pick one, it's
/// scanned in the background (Stop is instant), then a map of it where every
/// file is a rectangle as big as the space it takes, coloured by its kind,
/// with the biggest folders and files beside it. Folders open into their own
/// map, with the way back above it, and anything can be opened, shown in its
/// folder or deleted.
class StorageAnalyzerScreen extends StatefulWidget {
  const StorageAnalyzerScreen({super.key, this.initialPath});

  /// Scanned at once, when given.
  final String? initialPath;

  /// In place of the system's folder picker, for tests.
  @visibleForTesting
  static Future<String?> Function()? pickFolder;

  /// In place of this system's drives and folders, for tests.
  @visibleForTesting
  static Future<List<StoragePlace>> Function()? findPlaces;

  /// In place of opening the browser at a folder, for tests.
  @visibleForTesting
  static void Function(String folder)? showFolder;

  @override
  State<StorageAnalyzerScreen> createState() => _StorageAnalyzerScreenState();
}

enum _Stage { start, scanning, results }

enum _List { here, files }

enum _Action { open, showInFolder, delete }

class _StorageAnalyzerScreenState extends State<StorageAnalyzerScreen> {
  var _stage = _Stage.start;
  List<StoragePlace>? _places;
  final _spaces = <String, StorageSpace>{};
  String? _error;

  StorageScan? _scan;
  String? _scanning;
  StorageScanProgress? _progress;

  StorageScanResult? _result;
  StorageFolder? _shownFolder;
  StorageNode? _picked;
  var _list = _List.here;

  /// How many rows of the list show; more come on request.
  var _rows = _firstRows;

  static const _firstRows = 100;
  static const _wide = 860.0;
  static final _number = NumberFormat.decimalPattern();

  StorageFolder get _shown => _shownFolder!;

  @override
  void initState() {
    super.initState();
    final start = widget.initialPath;
    if (start != null && _canScan(start)) {
      _startScan(start);
    } else {
      _loadPlaces();
    }
  }

  @override
  void dispose() {
    _scan?.stop();
    super.dispose();
  }

  bool get _grouped => context.look.groupedLists;

  bool get _dark => Theme.of(context).brightness == Brightness.dark;

  static bool _canScan(String path) =>
      ExplorerPaths.isOnDisk(path) && !RemotePaths.isRemote(path) && !path.startsWith('content://');

  // ---- places ----

  Future<void> _loadPlaces() async {
    final places = await (StorageAnalyzerScreen.findPlaces ?? _systemPlaces)();
    if (!mounted) return;
    setState(() => _places = places);
    for (final place in places) {
      if (!place.isDrive) continue;
      final space = await StorageSpace.of(place.path);
      if (space != null && mounted) setState(() => _spaces[place.path] = space);
    }
  }

  static Future<List<StoragePlace>> _systemPlaces() async {
    if (Platform.isWindows) {
      final drives = await WindowsLocations.listDrives();
      return [
        for (final drive in drives) StoragePlace(drive.displayName, drive.path, LucideIcons.hardDrive, isDrive: true),
        StoragePlace('Your folder', ExplorerPaths.userFolder, LucideIcons.house),
      ];
    }
    if (Platform.isAndroid) {
      final cards = await LocalFileRepository().getStorageVolumes();
      return [
        const StoragePlace(
          'Internal storage',
          ExplorerPaths.androidInternalStorage,
          LucideIcons.smartphone,
          isDrive: true,
        ),
        for (final card in cards) StoragePlace(p.basename(card.path), card.path, LucideIcons.hardDrive, isDrive: true),
      ];
    }
    final home = Platform.environment['HOME'];
    final user = Platform.environment['USER'];
    final parents =
        Platform.isMacOS ? const ['/Volumes'] : [if (user != null) ...['/media/$user', '/run/media/$user'], '/mnt'];
    final mounts = <StoragePlace>[];
    for (final parent in parents) {
      try {
        for (final entity in Directory(parent).listSync(followLinks: false)) {
          final name = p.basename(entity.path);
          if (entity is Directory && !name.startsWith('.') && !name.startsWith('com.apple.')) {
            mounts.add(StoragePlace(name, entity.path, LucideIcons.usb, isDrive: true));
          }
        }
      } on FileSystemException {
        // Not there.
      }
    }
    return [
      if (home != null) StoragePlace('Home', home, LucideIcons.house),
      const StoragePlace('File system', '/', LucideIcons.hardDrive, isDrive: true),
      ...mounts,
    ];
  }

  Future<void> _chooseFolder() async {
    String? folder;
    try {
      final hook = StorageAnalyzerScreen.pickFolder;
      folder = hook != null ? await hook() : await FilePicker.platform.getDirectoryPath(dialogTitle: 'Folder to analyze');
    } on Object {
      folder = null;
    }
    if (folder == null || folder.isEmpty || !mounted) return;
    if (!_canScan(folder)) {
      setState(() => _error = "That place can't be analyzed. Choose a folder on this device.");
      return;
    }
    _startScan(folder);
  }

  // ---- scanning ----

  Future<void> _startScan(String path) async {
    _scan?.stop();
    final scan = _scan = StorageScan(path, onProgress: (progress) {
      if (mounted) setState(() => _progress = progress);
    });
    setState(() {
      _stage = _Stage.scanning;
      _scanning = path;
      _progress = null;
      _error = null;
    });
    final StorageScanResult? result;
    try {
      result = await scan.start();
    } on Object {
      if (!mounted || !identical(_scan, scan)) return;
      setState(() {
        _scan = null;
        _stage = _Stage.start;
        _error = "The scan couldn't finish. Try again.";
      });
      if (_places == null) _loadPlaces();
      return;
    }
    if (!mounted || result == null || !identical(_scan, scan)) return;
    setState(() {
      _scan = null;
      _result = result;
      _shownFolder = result!.root;
      _picked = null;
      _rows = _firstRows;
      _list = _List.here;
      _stage = _Stage.results;
    });
  }

  void _stop() {
    _scan?.stop();
    setState(() {
      _scan = null;
      _stage = _Stage.start;
    });
    if (_places == null) _loadPlaces();
  }

  void _backToStart() {
    setState(() {
      _stage = _Stage.start;
      _result = null;
      _shownFolder = null;
    });
    if (_places == null) _loadPlaces();
  }

  // ---- results ----

  void _openFolder(StorageFolder folder) => setState(() {
        _shownFolder = folder;
        _picked = null;
        _rows = _firstRows;
      });

  /// One level up; false at the top.
  bool _up() {
    final parent = _shown.parent;
    if (parent == null) return false;
    _openFolder(parent);
    return true;
  }

  Future<void> _actions(StorageNode node, Offset at) async {
    setState(() => _picked = node);
    final action = await ExplorerMenu.showAt<_Action>(
      context,
      at,
      items: [
        ExplorerMenu.label(context, '${node.name} · ${EntityFormat.size(node.disk)}'),
        ExplorerMenu.item(
          context,
          value: _Action.open,
          label: 'Open',
          icon: node.isFolder ? LucideIcons.folderOpen : LucideIcons.externalLink,
        ),
        ExplorerMenu.item(context, value: _Action.showInFolder, label: 'Show in folder', icon: LucideIcons.folderSearch),
        if (node.parent != null) ...[
          ExplorerMenu.divider(),
          ExplorerMenu.item(context, value: _Action.delete, label: 'Delete', icon: LucideIcons.trash2, destructive: true),
        ],
      ],
    );
    if (!mounted) return;
    if (action == null) {
      setState(() => _picked = null);
      return;
    }
    switch (action) {
      case _Action.open:
        if (node is StorageFolder) {
          _openFolder(node);
        } else {
          await FileOpener.open(context, File(node.path));
        }
      case _Action.showInFolder:
        _showInFolder(p.dirname(node.path));
      case _Action.delete:
        await _delete(node);
    }
  }

  void _showInFolder(String folder) {
    final hook = StorageAnalyzerScreen.showFolder;
    if (hook != null) return hook(folder);
    if (Desktop.isDesktop) {
      // A tab of its own, so this map stays as it is.
      ExplorerTabs.instance.open(folder);
    } else {
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => FileExplorerScreen(initialPath: folder)));
    }
  }

  Future<void> _delete(StorageNode node) async {
    final what = node is StorageFolder
        ? '${EntityFormat.size(node.disk)} (${_count(node.files, 'file')})'
        : EntityFormat.size(node.disk);
    final confirmed = await confirmToolboxDelete(
      context,
      title: 'Delete "${node.name}"?',
      message: "It takes up $what. It's deleted the way Delete does it in the browser.",
    );
    if (!confirmed || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await AppDelete.delete(node.path);
    } on Object catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't delete \"${node.name}\": ${_reason(error)}")));
      if (mounted) setState(() => _picked = null);
      return;
    }
    if (!mounted) return;
    setState(() {
      StorageFolder.remove(node);
      _picked = null;
    });
    messenger?.showSnackBar(SnackBar(content: Text('Deleted "${node.name}"')));
  }

  static String _reason(Object error) {
    if (error is FileSystemException) {
      final os = error.osError?.message.trim();
      return os == null || os.isEmpty ? error.message : os;
    }
    return '$error';
  }

  static String _count(int n, String unit) => '${_number.format(n)} $unit${n == 1 ? '' : 's'}';

  /// The last few parts of [path], as the start of a long one says little.
  static String _tail(String path) {
    final parts = p.split(path);
    return parts.length <= 4 ? path : '…${p.separator}${p.joinAll(parts.sublist(parts.length - 3))}';
  }

  static Offset _centerOf(BuildContext context) {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  // ---- pieces ----

  /// A card: iOS's grouped one, or a rounded outline.
  Widget _panel(Widget child) {
    final colors = context.colors;
    return Material(
      type: _grouped ? MaterialType.canvas : MaterialType.transparency,
      color: _grouped ? IosStyle.groupedCard(_dark) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_grouped ? 12 : 16),
        side: _grouped ? BorderSide.none : BorderSide(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _divider({double indent = 16}) => Divider(
        height: 1,
        thickness: _grouped ? 0.5 : 1,
        indent: indent,
        color: _grouped ? IosStyle.separator(_dark) : context.colors.border,
      );

  Widget _heading(String title, IconData icon) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(_grouped ? 16 : 6, 22, 6, 8),
      child: _grouped
          ? Text(
              title.toUpperCase(),
              style: text.bodySmall?.copyWith(fontSize: 12, letterSpacing: 0.3, color: colors.mutedForeground),
            )
          : Row(
              children: [
                Icon(icon, size: 16, color: context.look.iconColor(icon, colors.mutedForeground)),
                const SizedBox(width: 8),
                Text(title, style: text.titleSmall),
              ],
            ),
    );
  }

  /// A state in the middle of the page, scrolling if the window is too low.
  Widget _centred(List<Widget> children) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final bottom = MediaQuery.paddingOf(context).bottom + 24;
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, top + 16, 16, bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - top - 16 - bottom)),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(IconData icon, {double size = 88}) {
    final tint = context.colors.primary;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: tint.withValues(alpha: 0.12)),
        child: SizedBox.square(dimension: size, child: Icon(icon, size: size * 0.44, color: tint)),
      ),
    );
  }

  Widget _title(String title) => Text(
        title,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
      );

  Widget _line(String line) => Text(
        line,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.colors.mutedForeground),
      );

  /// A thin bar, [value] of it filled.
  Widget _bar(double value, Color color, {double height = 6}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: context.colors.border),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: value.clamp(0.0, 1.0),
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }

  // ---- start ----

  Widget _placeRow(StoragePlace place) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final space = _spaces[place.path];
    return InkWell(
      onTap: () => _startScan(place.path),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SizedBox.square(
                dimension: 38,
                child: Icon(place.icon, size: 19, color: context.look.iconColor(place.icon, colors.primary)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  if (space != null && space.total > 0) ...[
                    const SizedBox(height: 6),
                    _bar(space.used / space.total, colors.primary),
                    const SizedBox(height: 4),
                    Text(
                      '${EntityFormat.size(space.used)} used of ${EntityFormat.size(space.total)}',
                      style: text.bodySmall,
                    ),
                  ] else
                    Text(place.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(LucideIcons.chevronRight, size: 18, color: colors.mutedForeground),
          ],
        ),
      ),
    );
  }

  Widget _startView() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final places = _places;
    final error = _error;
    return _centred([
      _badge(Tool.storageAnalyzer.icon),
      const SizedBox(height: 20),
      _title('See what takes up space'),
      const SizedBox(height: 8),
      _line('Pick a drive or a folder. It shows as a map, where the biggest things take the most room.'),
      if (error != null) ...[
        const SizedBox(height: 14),
        Text(error, textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: colors.destructive)),
      ],
      _heading('Drives and folders', LucideIcons.hardDrive),
      _panel(Column(
        children: [
          if (places == null)
            const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))
          else
            for (final (i, place) in places.indexed) ...[
              if (i > 0) _divider(indent: 64),
              _placeRow(place),
            ],
          if (places != null && places.isNotEmpty) _divider(indent: 64),
          InkWell(
            onTap: _chooseFolder,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 38,
                    child: Icon(
                      LucideIcons.folderOpen,
                      size: 19,
                      color: context.look.iconColor(LucideIcons.folderOpen, colors.primary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('Choose a folder…', style: text.bodyMedium?.copyWith(color: colors.primary))),
                  Icon(LucideIcons.chevronRight, size: 18, color: colors.mutedForeground),
                ],
              ),
            ),
          ),
        ],
      )),
    ]);
  }

  // ---- scanning ----

  Widget _scanningView() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final progress = _progress;
    final space = _spaces[_scanning];
    final fraction = space == null || progress == null || space.used <= 0 ? null : progress.disk / space.used;
    return _centred([
      Center(
        child: SizedBox.square(
          dimension: 168,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CircularProgressIndicator(
                value: fraction?.clamp(0.0, 1.0),
                strokeWidth: 10,
                strokeCap: StrokeCap.round,
                color: colors.primary,
                backgroundColor: colors.border,
              ),
              Padding(
                padding: const EdgeInsets.all(28),
                child: Center(
                  child: FittedBox(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          EntityFormat.size(progress?.disk ?? 0),
                          style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text('found so far', style: text.bodySmall),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 26),
      _title(progress == null ? 'Getting ready…' : _count(progress.files, 'file')),
      const SizedBox(height: 6),
      Text(
        progress == null ? _scanning ?? '' : _tail(progress.place),
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall,
      ),
      const SizedBox(height: 26),
      Center(
        child: OutlinedButton.icon(
          onPressed: _stop,
          icon: const Icon(LucideIcons.circleStop, size: 18),
          label: const Text('Stop'),
        ),
      ),
    ]);
  }

  // ---- results ----

  /// The way back up: the scanned folder, then each folder down to this one.
  Widget _crumbs() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final trail = _shown.trail;
    final last = trail.length - 1;
    final items = <Widget>[];
    for (final (i, node) in trail.indexed) {
      if (i > 0) items.add(Icon(LucideIcons.chevronRight, size: 14, color: colors.mutedForeground));
      final current = i == last;
      items.add(TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          foregroundColor: current ? colors.foreground : colors.mutedForeground,
        ),
        onPressed: current ? null : () => _openFolder(node as StorageFolder),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i == 0) ...[
              Icon(
                LucideIcons.hardDrive,
                size: 15,
                color: context.look.iconColor(LucideIcons.hardDrive, colors.mutedForeground),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              i == 0 ? _rootName(node.name) : node.name,
              style: text.bodyMedium?.copyWith(
                fontWeight: current ? FontWeight.w600 : null,
                color: current ? colors.foreground : colors.mutedForeground,
              ),
            ),
          ],
        ),
      ));
    }
    return SizedBox(
      height: 36,
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // The current folder stays in sight in a long trail…
          reverse: true,
          // …and a short one starts at the left.
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: Row(children: items),
          ),
        ),
      ),
    );
  }

  /// The scanned folder's name: a drive keeps its letter, a folder its name.
  static String _rootName(String path) {
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }

  /// The folder's size, and its space by kind as one bar with a legend.
  Widget _summary() {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final shown = _shown;
    final total = shown.disk;
    final kinds = [
      for (final kind in StorageKind.values)
        if (shown.kinds[kind.index] > 0) kind,
    ]..sort((a, b) => shown.kinds[b.index].compareTo(shown.kinds[a.index]));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 10,
          children: [
            Text(EntityFormat.size(total), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('${_count(shown.files, 'file')} · ${_count(shown.folders, 'folder')}', style: text.bodySmall),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: SizedBox(
            height: 10,
            child: total <= 0
                ? ColoredBox(color: colors.border)
                : Row(
                    children: [
                      for (final kind in kinds)
                        Expanded(
                          flex: math.max(1, shown.kinds[kind.index] * 1000 ~/ total),
                          child: ColoredBox(color: StorageColors.of(kind, brightness)),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            for (final kind in kinds)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: StorageColors.of(kind, brightness),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const SizedBox.square(dimension: 10),
                  ),
                  const SizedBox(width: 6),
                  Text('${kind.label} ', style: text.bodySmall?.copyWith(color: colors.foreground)),
                  Text(EntityFormat.size(shown.kinds[kind.index]), style: text.bodySmall),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _map() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(_grouped ? 12 : 14),
      child: ColoredBox(
        color: context.colors.muted.withValues(alpha: 0.4),
        child: _shown.disk <= 0
            ? Center(child: Text('Nothing takes up space here', style: Theme.of(context).textTheme.bodySmall))
            : Builder(
                builder: (map) => StorageTreemap(
                  folder: _shown,
                  selected: _picked,
                  onOpen: _openFolder,
                  onPick: (node) {
                    if (node != null) _actions(node, _centerOf(map));
                  },
                  onMenu: _actions,
                ),
              ),
      ),
    );
  }

  Widget _listTabs() => SegmentedButton<_List>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: const [
          ButtonSegment(value: _List.here, icon: Icon(LucideIcons.folderTree, size: 16), label: Text('Biggest here')),
          ButtonSegment(value: _List.files, icon: Icon(LucideIcons.file, size: 16), label: Text('Biggest files')),
        ],
        selected: {_list},
        onSelectionChanged: (chosen) => setState(() {
          _list = chosen.first;
          _rows = _firstRows;
        }),
      );

  /// What the list shows: the folder's own items, or its biggest files
  /// however deep.
  List<StorageNode> get _listed =>
      _list == _List.here ? _shown.children : _shown.biggestFiles(StorageScanner.keepFiles);

  Widget _row(StorageNode node, {required bool showPath}) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final brightness = Theme.of(context).brightness;
    final share = _shown.disk <= 0 ? 0.0 : node.disk / _shown.disk;
    final color = switch (node) {
      StorageFolder() => StorageColors.of(StorageColors.mainKindOf(node), brightness),
      StorageFile(:final kind) => StorageColors.of(kind, brightness),
    };
    final icon = node.isFolder ? LucideIcons.folder : LucideIcons.file;
    final picked = identical(node, _picked);
    final percent = share == 0 || share >= 0.001 ? '${(share * 100).toStringAsFixed(share >= 0.1 ? 0 : 1)}%' : '<0.1%';
    return Builder(
      builder: (row) => InkWell(
        onTap: () => node is StorageFolder ? _openFolder(node) : _actions(node, _centerOf(row)),
        onLongPress: () => _actions(node, _centerOf(row)),
        onSecondaryTapUp: (details) => _actions(node, details.globalPosition),
        child: ColoredBox(
          color: picked ? colors.primary.withValues(alpha: 0.08) : Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8)),
                  child: SizedBox.square(dimension: 34, child: Icon(icon, size: 17, color: color)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                          ),
                          const SizedBox(width: 8),
                          Text(EntityFormat.size(node.disk), style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(child: _bar(share, color, height: 4)),
                          const SizedBox(width: 8),
                          SizedBox(width: 44, child: Text(percent, textAlign: TextAlign.end, style: text.bodySmall)),
                        ],
                      ),
                      if (showPath) ...[
                        const SizedBox(height: 2),
                        Text(
                          _tail(p.relative(p.dirname(node.path), from: p.dirname(_shown.path))),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ] else if (node is StorageFolder) ...[
                        const SizedBox(height: 2),
                        Text(node.unreadable ? "Couldn't be read" : _count(node.files, 'file'), style: text.bodySmall),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'More',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: colors.mutedForeground,
                  icon: const Icon(LucideIcons.ellipsisVertical),
                  onPressed: () => _actions(node, _centerOf(row)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The list's rows, then a line for the files too small to list and one
  /// to show more.
  List<Widget> _rowsOf(List<StorageNode> listed) {
    final text = Theme.of(context).textTheme;
    final shown = listed.take(_rows).toList();
    final small = _list == _List.here && _shown.smallFiles > 0;
    return [
      for (final (i, node) in shown.indexed) ...[
        if (i > 0) _divider(indent: 56),
        _row(node, showPath: _list == _List.files),
      ],
      if (listed.length > _rows)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Center(
            child: TextButton.icon(
              onPressed: () => setState(() => _rows += _firstRows),
              icon: const Icon(LucideIcons.chevronDown, size: 16),
              label: Text('Show ${math.min(_firstRows, listed.length - _rows)} more'),
            ),
          ),
        ),
      if (small) ...[
        if (shown.isNotEmpty) _divider(indent: 56),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 10, 16, 10),
          child: Text(
            '${_count(_shown.smallFiles, 'smaller file')} · ${EntityFormat.size(_shown.smallDisk)}',
            style: text.bodySmall,
          ),
        ),
      ],
      if (shown.isEmpty && !small)
        Padding(
          padding: const EdgeInsets.all(20),
          child: Center(child: Text('This folder is empty', style: text.bodySmall)),
        ),
    ];
  }

  /// How the scan went: its time, and what it left out.
  Widget _notes() {
    final text = Theme.of(context).textTheme;
    final result = _result!;
    final parts = [
      'Scanned in ${_seconds(result.took)}',
      if (result.unreadable > 0) "${_count(result.unreadable, 'folder')} couldn't be read",
      if (result.links > 0) '${_count(result.links, 'link')} not followed',
      if (result.skipped > 0) '${_count(result.skipped, 'other drive')} left out',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
      child: Text(parts.join(' · '), style: text.bodySmall),
    );
  }

  static String _seconds(Duration took) {
    final seconds = took.inMilliseconds / 1000;
    if (seconds < 1) return 'under a second';
    if (seconds < 60) return '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} s';
    return '${took.inMinutes} min ${took.inSeconds % 60} s';
  }

  Widget _resultsView() {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final listed = _listed;
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= _wide) {
        // The map, with the list beside it.
        return Padding(
          padding: EdgeInsets.fromLTRB(16, top + 8, 16, bottom + 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _crumbs(),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _summary(),
                          const SizedBox(height: 12),
                          Expanded(child: _map()),
                          _notes(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: math.min(420, box.maxWidth * 0.4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _listTabs(),
                          const SizedBox(height: 10),
                          Expanded(child: _panel(ListView(padding: EdgeInsets.zero, children: _rowsOf(listed)))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }
      // A phone: the map, then the list under it.
      final mapHeight = math.max(220.0, math.min(380.0, box.maxHeight * 0.42));
      return ListView(
        padding: EdgeInsets.fromLTRB(12, top + 6, 12, bottom + 24),
        children: [
          _crumbs(),
          const SizedBox(height: 6),
          _summary(),
          const SizedBox(height: 12),
          SizedBox(height: mapHeight, child: _map()),
          _notes(),
          const SizedBox(height: 16),
          _listTabs(),
          const SizedBox(height: 10),
          _panel(Column(children: _rowsOf(listed))),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final body = switch (_stage) {
      _Stage.start => _startView(),
      _Stage.scanning => _scanningView(),
      _Stage.results => _resultsView(),
    };
    final results = _stage == _Stage.results;
    return PopScope(
      // Back climbs the map first, then leaves.
      canPop: !results || _shownFolder?.parent == null,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _up();
      },
      child: ExplorerScaffold(
        title: 'Storage analyzer',
        backgroundColor: _grouped ? IosStyle.groupedBackground(_dark).withValues(alpha: colors.background.a) : null,
        trailing: results
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIconButton(
                    icon: const Icon(LucideIcons.refreshCw),
                    tooltip: 'Scan again',
                    onPressed: () => _startScan(_result!.root.name),
                  ),
                  AppIconButton(
                    icon: const Icon(LucideIcons.hardDrive),
                    tooltip: 'Another drive or folder',
                    onPressed: _backToStart,
                  ),
                ],
              )
            : null,
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: KeyedSubtree(key: ValueKey(_stage), child: body),
        ),
      ),
    );
  }
}
