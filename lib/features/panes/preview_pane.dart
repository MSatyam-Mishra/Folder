import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/file_action_service.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/folder_size.dart';
import 'package:folders/features/panes/preview_views.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The preview pane, right of the files: what's selected in the active pane
/// (a picture, a video's frame, a song to play, a PDF's first pages, the
/// start of a text or a document...), its details and quick actions. With
/// nothing selected, the folder; with several, how many and how big.
class PreviewPane extends StatelessWidget {
  const PreviewPane({super.key, required this.panes});

  final DualPaneController panes;

  @override
  Widget build(BuildContext context) {
    // Rebuilt when another pane becomes the active one.
    DualPanes.of(context);
    final bloc = panes.activeBloc;
    final content = bloc == null
        ? const SizedBox.shrink()
        : BlocBuilder<FileExplorerBloc, FileExplorerState>(
            bloc: bloc,
            buildWhen: (before, now) => _shown(before) != _shown(now),
            builder: (context, state) => _PreviewFor(bloc: bloc, state: state),
          );
    final colors = context.colors;
    // iOS: a pane of glass floating over the wallpaper, as the sidebar.
    if (context.look.style.glass) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(2, 8, 8, 8),
        child: GlassPane(borderRadius: BorderRadius.circular(18), child: SafeArea(left: false, child: content)),
      );
    }
    return Material(
      color: DockedSidebar.backgroundOf(context),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: colors.foreground),
        child: SafeArea(left: false, child: content),
      ),
    );
  }

  /// What the pane shows for [state]: the folder and what's selected.
  static Object? _shown(FileExplorerState state) => switch (state) {
        FileExplorerLoaded(:final path, :final selectedItems, :final entities) =>
          (path, Object.hashAllUnordered(selectedItems.map((e) => e.path)), entities.length, identityHashCode(entities)),
        _ => state.runtimeType,
      };
}

class _PreviewFor extends StatelessWidget {
  const _PreviewFor({required this.bloc, required this.state});

  final FileExplorerBloc bloc;
  final FileExplorerState state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state is! FileExplorerLoaded) {
      return const PreviewMessage(icon: LucideIcons.eye, text: 'Select an item to preview it');
    }
    final selected = [
      for (final e in state.displayEntities) if (state.selectedItems.contains(e)) e,
    ];
    if (selected.isEmpty && state.selectedItems.isNotEmpty) selected.addAll(state.selectedItems);
    if (selected.length == 1) {
      return _ItemPreview(key: ValueKey(selected.single.path), entity: selected.single, bloc: bloc, state: state);
    }
    if (selected.length > 1) {
      return _ManyPreview(key: ValueKey(Object.hashAll(selected.map((e) => e.path))), items: selected, bloc: bloc);
    }
    if (ExplorerPaths.isVirtual(state.path)) {
      return const PreviewMessage(icon: LucideIcons.eye, text: 'Select an item to preview it');
    }
    return _FolderPreview(key: ValueKey(state.path), state: state);
  }
}

/// A line of muted text with an icon, in the middle of the pane.
class PreviewMessage extends StatelessWidget {
  const PreviewMessage({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: colors.mutedForeground),
            const SizedBox(height: 10),
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Scrolls the pane's content, with room at the top for the page's bar.
class _PreviewScroll extends StatelessWidget {
  const _PreviewScroll({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: children,
      ),
    );
  }
}

/// One file or folder: a picture of it, its name, actions and details.
class _ItemPreview extends StatefulWidget {
  const _ItemPreview({super.key, required this.entity, required this.bloc, required this.state});

  final FileSystemEntity entity;
  final FileExplorerBloc bloc;
  final FileExplorerLoaded state;

  @override
  State<_ItemPreview> createState() => _ItemPreviewState();
}

class _ItemPreviewState extends State<_ItemPreview> {
  final PreviewFacts _facts = ValueNotifier(const {});

  // Arrowing through a folder goes past many items: the heavier previews
  // start once the selection rests on one.
  bool _settled = false;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _settle = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _settled = true);
    });
  }

  @override
  void dispose() {
    _settle?.cancel();
    _facts.dispose();
    super.dispose();
  }

  FileSystemEntity get _entity => widget.entity;

  bool get _isFolder => _entity is Directory && !FileActionsService.isPackage(_entity);

  Future<void> _open() async {
    final entity = _entity;
    final bloc = widget.bloc;
    if (_isFolder) {
      bloc.add(LoadDirectory(entity.path));
      return;
    }
    if (FileActionsService.opensWithMac(entity)) {
      return FileActionsService().openPackage(context, entity);
    }
    final folder = widget.state.path;
    final changed = await FileOpener.open(context, entity as File);
    // The viewer saved a copy or changed the folder: show it.
    if (changed == true && !bloc.isClosed) bloc.add(LoadDirectory(folder));
  }

  Widget _picture(BuildContext context) {
    final entity = _entity;
    if (entity is! File) return PreviewIcon(entity: entity);
    final look = previewLookOf(entity.path);
    // Cheap ones at once; the rest once the selection rests.
    if (!_settled && look != PreviewLook.image) return PreviewIcon(entity: entity);
    return switch (look) {
      PreviewLook.image => ImagePreview(file: entity, facts: _facts),
      PreviewLook.svg => SvgPreview(file: entity),
      PreviewLook.picture || PreviewLook.other => ThumbnailPreview(file: entity),
      PreviewLook.video => ThumbnailPreview(
          file: entity,
          overlay: PlayBadge(onPressed: _open),
        ),
      PreviewLook.audio => AudioPreview(file: entity, facts: _facts),
      PreviewLook.pdf => PdfPreview(file: entity, facts: _facts),
      PreviewLook.text => TextPreview(file: entity, facts: _facts),
      PreviewLook.document => DocumentPreview(file: entity),
    };
  }

  @override
  Widget build(BuildContext context) {
    final entity = _entity;
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final look = entity is File ? previewLookOf(entity.path) : PreviewLook.other;
    final name = widget.state.labelFor(entity);
    return LayoutBuilder(builder: (context, box) {
      final inner = math.max(0.0, box.maxWidth - 32);
      final tall = previewIsTall(look);
      final double height = tall
          ? (inner * 1.3).clamp(200.0, math.max(200.0, box.maxHeight * 0.62)).toDouble()
          : look == PreviewLook.audio
              ? inner + 64
              : math.min(inner, math.max(160.0, box.maxHeight * 0.45));
      return _PreviewScroll(
        children: [
          Container(
            height: height,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: tall || _isFolder || look == PreviewLook.audio ? null : colors.background.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
              border: tall ? Border.all(color: colors.border) : null,
            ),
            child: _picture(context),
          ),
          const SizedBox(height: 14),
          SelectableText(
            name,
            minLines: 1,
            maxLines: 3,
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          EntityStatBuilder(
            entity: entity,
            builder: (context, stat) => Text(
              stat == null ? EntityFormat.kind(entity) : '${EntityFormat.kind(entity)} · ${EntityFormat.summary(entity, stat)}',
              style: text.bodySmall,
            ),
          ),
          const SizedBox(height: 12),
          _Actions(
            actions: [
              _Action(
                icon: _isFolder ? LucideIcons.folderOpen : LucideIcons.externalLink,
                label: 'Open',
                onPressed: _open,
              ),
              if (entity is File && (Desktop.canShareFiles || !Desktop.isDesktop))
                _Action(
                  icon: LucideIcons.share2,
                  label: 'Share',
                  onPressed: () => FileActionsService().shareMany(context, [entity]),
                ),
              _Action(
                icon: LucideIcons.clipboardCopy,
                label: 'Copy path',
                onPressed: () => _copyPaths(context, [entity.path]),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ValueListenableBuilder<Map<String, String>>(
            valueListenable: _facts,
            builder: (context, facts, _) => _Details(entity: entity, facts: facts),
          ),
        ],
      );
    });
  }
}

/// The current folder, with nothing selected: how much is in it.
class _FolderPreview extends StatelessWidget {
  const _FolderPreview({super.key, required this.state});

  final FileExplorerLoaded state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final folder = Directory(state.path);
    final entities = state.entities;
    final folders = entities.where((e) => e is Directory && !FileActionsService.isPackage(e)).length;
    final files = entities.length - folders;
    return _PreviewScroll(
      children: [
        const SizedBox(height: 8),
        Center(child: EntityIcon(entity: folder, size: 88)),
        const SizedBox(height: 14),
        SelectableText(
          ExplorerPaths.titleForPath(state.path),
          textAlign: TextAlign.center,
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(_count(folders, files), textAlign: TextAlign.center, style: text.bodySmall),
        const SizedBox(height: 12),
        Center(
          child: _Actions(actions: [
            _Action(
              icon: LucideIcons.clipboardCopy,
              label: 'Copy path',
              onPressed: () => _copyPaths(context, [state.path]),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        _DetailRow(label: 'Size', child: _SizeOnRequest(paths: [state.path])),
        _DetailRow(label: 'Location', value: state.path, selectable: true),
        const SizedBox(height: 18),
        Text('Select an item to preview it.', textAlign: TextAlign.center, style: text.bodySmall),
      ],
    );
  }
}

/// Several items: how many of each, and their size.
class _ManyPreview extends StatelessWidget {
  const _ManyPreview({super.key, required this.items, required this.bloc});

  final List<FileSystemEntity> items;
  final FileExplorerBloc bloc;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final folders = items.where((e) => e is Directory && !FileActionsService.isPackage(e)).length;
    final files = items.length - folders;
    final shown = items.take(6).toList();
    return _PreviewScroll(
      children: [
        const SizedBox(height: 8),
        // A little pile of what's selected.
        SizedBox(
          height: 92,
          child: Center(
            child: SizedBox(
              width: 72 + (shown.length - 1) * 18.0,
              child: Stack(
                children: [
                  for (final (i, e) in shown.indexed)
                    Positioned(
                      left: i * 18.0,
                      top: (i.isEven ? 6 : 0) + 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.card,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colors.border),
                          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))],
                        ),
                        child: Padding(padding: const EdgeInsets.all(8), child: EntityIcon(entity: e, size: 56)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '${items.length} items selected',
          textAlign: TextAlign.center,
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(_count(folders, files), textAlign: TextAlign.center, style: text.bodySmall),
        const SizedBox(height: 12),
        Center(
          child: _Actions(actions: [
            if (files > 0 && (Desktop.canShareFiles || !Desktop.isDesktop))
              _Action(
                icon: LucideIcons.share2,
                label: 'Share',
                onPressed: () => FileActionsService().shareMany(context, items),
              ),
            _Action(
              icon: LucideIcons.clipboardCopy,
              label: 'Copy paths',
              onPressed: () => _copyPaths(context, [for (final e in items) e.path]),
            ),
          ]),
        ),
        const SizedBox(height: 18),
        if (folders == 0)
          _DetailRow(label: 'Total size', child: _FilesSize(files: items.whereType<File>().toList()))
        else
          _DetailRow(label: 'Total size', child: _SizeOnRequest(paths: [for (final e in items) e.path])),
        _DetailRow(label: 'Location', value: _commonFolder(items), selectable: true),
      ],
    );
  }

  static String _commonFolder(List<FileSystemEntity> items) {
    final folders = {for (final e in items) p.dirname(e.path)};
    return folders.length == 1 ? folders.single : 'Several folders';
  }
}

/// "3 folders · 12 files".
String _count(int folders, int files) {
  final parts = [
    if (folders > 0) '$folders ${folders == 1 ? 'folder' : 'folders'}',
    if (files > 0) '$files ${files == 1 ? 'file' : 'files'}',
  ];
  return parts.isEmpty ? 'Empty' : parts.join(' · ');
}

void _copyPaths(BuildContext context, List<String> paths) {
  Clipboard.setData(ClipboardData(text: paths.join('\n')));
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(paths.length == 1 ? 'Path copied' : '${paths.length} paths copied')));
}

class _Action {
  const _Action({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// The quick actions, as small outlined buttons that wrap when narrow.
class _Actions extends StatelessWidget {
  const _Actions({required this.actions});

  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final a in actions)
          OutlinedButton.icon(
            onPressed: a.onPressed,
            icon: Icon(a.icon, size: 15, color: context.look.iconColor(a.icon, context.colors.foreground)),
            label: Text(a.label),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
              textStyle: Theme.of(context).textTheme.labelMedium,
            ),
          ),
      ],
    );
  }
}

/// Type, size, dates, what the views found out, and the full path.
class _Details extends StatelessWidget {
  const _Details({required this.entity, required this.facts});

  final FileSystemEntity entity;
  final Map<String, String> facts;

  static final _when = DateFormat.yMMMd().add_jm();

  @override
  Widget build(BuildContext context) {
    final folder = entity is Directory && !FileActionsService.isPackage(entity);
    return EntityStatBuilder(
      entity: entity,
      builder: (context, stat) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Details', style: Theme.of(context).textTheme.labelMedium),
          ),
          _DetailRow(label: 'Type', value: EntityFormat.kind(entity)),
          if (!folder && stat != null)
            _DetailRow(
              label: 'Size',
              value: '${EntityFormat.size(stat.size)} (${NumberFormat.decimalPattern().format(stat.size)} bytes)',
            ),
          if (folder) ...[
            _DetailRow(label: 'Items', child: _ItemCount(folder: entity.path)),
            _DetailRow(label: 'Size', child: _SizeOnRequest(paths: [entity.path])),
          ],
          for (final fact in facts.entries) _DetailRow(label: fact.key, value: fact.value),
          if (stat != null) _DetailRow(label: 'Modified', value: _when.format(stat.modified)),
          // Windows keeps when a file was made; elsewhere this is when it
          // last changed in any way.
          if (stat != null && Platform.isWindows) _DetailRow(label: 'Created', value: _when.format(stat.changed)),
          _DetailRow(label: 'Location', value: p.dirname(entity.path), selectable: true),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, this.value, this.child, this.selectable = false});

  final String label;
  final String? value;
  final Widget? child;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final style = text.bodySmall?.copyWith(color: context.colors.foreground);
    final value = this.value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 84, child: Text(label, style: text.bodySmall)),
          Expanded(
            child: child ??
                (selectable ? SelectableText(value ?? '', style: style) : Text(value ?? '', style: style)),
          ),
        ],
      ),
    );
  }
}

/// How many items a folder holds.
class _ItemCount extends StatefulWidget {
  const _ItemCount({required this.folder});

  final String folder;

  @override
  State<_ItemCount> createState() => _ItemCountState();
}

class _ItemCountState extends State<_ItemCount> {
  String? _text;

  @override
  void initState() {
    super.initState();
    _countItems();
  }

  Future<void> _countItems() async {
    var folders = 0, files = 0;
    try {
      await for (final e in Directory(widget.folder).list(followLinks: false)) {
        e is Directory ? folders++ : files++;
      }
    } on FileSystemException {
      if (mounted) setState(() => _text = "Can't be read");
      return;
    }
    if (mounted) setState(() => _text = _count(folders, files));
  }

  @override
  Widget build(BuildContext context) =>
      Text(_text ?? '…', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.colors.foreground));
}

/// The size of files, added up.
class _FilesSize extends StatefulWidget {
  const _FilesSize({required this.files});

  final List<File> files;

  @override
  State<_FilesSize> createState() => _FilesSizeState();
}

class _FilesSizeState extends State<_FilesSize> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    Future.wait(widget.files.map(EntityStats.load)).then((stats) {
      if (mounted) setState(() => _bytes = stats.fold<int>(0, (sum, s) => sum + (s?.size ?? 0)));
    });
  }

  @override
  Widget build(BuildContext context) => Text(
        _bytes == null ? '…' : EntityFormat.size(_bytes!),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.colors.foreground),
      );
}

/// A folder's size, added up when asked (it can take a while): the total
/// so far while counting, with a button to stop.
class _SizeOnRequest extends StatefulWidget {
  const _SizeOnRequest({required this.paths});

  final List<String> paths;

  @override
  State<_SizeOnRequest> createState() => _SizeOnRequestState();
}

class _SizeOnRequestState extends State<_SizeOnRequest> {
  StreamSubscription<FolderSize>? _counting;
  FolderSize? _size;

  @override
  void dispose() {
    _counting?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() => _size = const FolderSize());
    _counting = FolderSize.measure(widget.paths).listen(
      (size) {
        if (mounted) setState(() => _size = size);
      },
      onError: (Object _) {
        if (mounted) setState(() => _size = null);
      },
    );
  }

  void _stop() {
    _counting?.cancel();
    _counting = null;
    setState(() => _size = null);
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: context.colors.foreground);
    final size = _size;
    if (size == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: _start,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.calculator, size: 13, color: context.colors.primary),
                const SizedBox(width: 6),
                Text('Calculate', style: style?.copyWith(color: context.colors.primary, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      );
    }
    final summary = '${EntityFormat.size(size.bytes)} · ${_count(size.folders, size.files)}';
    if (size.done) return Text(summary, style: style);
    return Row(
      children: [
        Expanded(child: Text('$summary…', style: style)),
        InkWell(
          onTap: _stop,
          borderRadius: BorderRadius.circular(6),
          child: Tooltip(
            message: 'Stop',
            child: Icon(LucideIcons.circleStop, size: 15, color: context.colors.mutedForeground),
          ),
        ),
      ],
    );
  }
}
