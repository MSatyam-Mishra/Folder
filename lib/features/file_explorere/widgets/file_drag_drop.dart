import 'dart:async';
import 'dart:io';

import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/platform/macos_files.dart';
import 'package:explorer/core/platform/macos_writable.dart';
import 'package:explorer/core/platform/windows_drop_files.dart';
import 'package:explorer/features/file_explorere/widgets/selection_band.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

/// Whether the system's drag and drop is used; widget tests have none.
final bool nativeDragAndDrop = !Platform.environment.containsKey('FLUTTER_TEST');

/// Lets [entity] be dragged (desktop): to folders in this window or
/// another Explorer window, to File Explorer, the desktop or other apps.
/// When it's part of a selection, [selection] gives the other items that
/// go with it.
class FileDragSource extends StatelessWidget {
  const FileDragSource({
    super.key,
    required this.entity,
    required this.child,
    this.selection,
    this.draggable = true,
  });

  final FileSystemEntity entity;
  final Widget child;
  final bool draggable;
  final List<FileSystemEntity> Function()? selection;

  static DragItem _item(FileSystemEntity entity) => DragItem(
        localData: {'path': entity.path},
        suggestedName: p.basename(entity.path),
      )..add(Formats.fileUri(Uri.file(entity.path)));

  @override
  Widget build(BuildContext context) {
    if (!Desktop.isDesktop || !nativeDragAndDrop) return child;
    return DragItemWidget(
      allowedOperations: () => const [DropOperation.move, DropOperation.copy],
      dragItemProvider: (_) => _item(entity),
      child: DraggableWidget(
        isLocationDraggable: (position) => draggable && overDragPart(context, position),
        // The rest of the selection, also rows scrolled out of view, with
        // this row's picture.
        onDragConfiguration: (configuration, session) {
          final others = [
            for (final e in selection?.call() ?? const <FileSystemEntity>[])
              if (e.path != entity.path) e,
          ];
          if (others.isEmpty) return configuration;
          final image = configuration.items.first.image;
          return DragConfiguration(
            allowedOperations: configuration.allowedOperations,
            items: [
              ...configuration.items,
              for (final e in others) DragConfigurationItem(item: _item(e), image: image),
            ],
          );
        },
        child: child,
      ),
    );
  }
}

/// A folder files can be dropped on: from this window, another Explorer
/// window, File Explorer or other apps. [builder] shows whether something
/// is being dragged over it.
class FileDropTarget extends StatefulWidget {
  const FileDropTarget({
    super.key,
    required this.folder,
    required this.onDrop,
    required this.builder,
  });

  final String folder;

  /// The dropped paths, and whether they're to be moved (else copied).
  final void Function(List<String> paths, bool move) onDrop;
  final Widget Function(BuildContext context, bool hovering) builder;

  @override
  State<FileDropTarget> createState() => _FileDropTargetState();
}

class _FileDropTargetState extends State<FileDropTarget> {
  bool _hovering = false;

  void _hover(bool value) {
    if (_hovering != value && mounted) setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!nativeDragAndDrop) return widget.builder(context, false);
    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropEnter: (_) => _hover(true),
      onDropLeave: (_) => _hover(false),
      onDropEnded: (_) => _hover(false),
      onDropOver: (event) {
        final sources = [
          for (final item in event.session.items) ?_localPath(item),
        ];
        // Not onto itself, nor into a folder inside a dragged folder.
        if (sources.any((s) => p.equals(s, widget.folder) || p.isWithin(s, widget.folder))) {
          return DropOperation.none;
        }
        final move = dropMoves(
          sources.isEmpty ? null : sources.first,
          widget.folder,
          fromThisApp: sources.isNotEmpty,
        );
        final allowed = event.session.allowedOperations;
        final wanted = move ? DropOperation.move : DropOperation.copy;
        if (allowed.contains(wanted)) return wanted;
        // macOS narrows a drag's operations by the keys held, and Cmd
        // leaves none that read here; drags from this app allow both.
        if (Platform.isMacOS && allowed.isEmpty && sources.isNotEmpty) return wanted;
        // Whatever the source allows: some apps only let their files be moved.
        if (allowed.contains(DropOperation.copy)) return DropOperation.copy;
        return allowed.contains(DropOperation.move) ? DropOperation.move : DropOperation.none;
      },
      onPerformDrop: (event) async {
        _hover(false);
        final paths = await droppedPaths(event.session.items);
        if (paths.isEmpty) return;
        widget.onDrop(paths, event.acceptedOperation == DropOperation.move);
      },
      child: widget.builder(context, _hovering),
    );
  }

  static String? _localPath(DropItem item) {
    final data = item.localData;
    return data is Map ? data['path'] as String? : null;
  }

  /// The local paths of [items]: from this app directly, else the file
  /// URIs other apps give.
  static Future<List<String>> droppedPaths(List<DropItem> items) async {
    // From another app, what it gives now is the truth: WinRAR's earlier list
    // has names inside the archive, not files.
    if (items.any((item) => _localPath(item) == null)) {
      final files = await WindowsDropFiles.last();
      if (files.isNotEmpty) return files;
    }
    final paths = <String>[];
    for (final item in items) {
      final local = _localPath(item);
      if (local != null) {
        paths.add(local);
        continue;
      }
      final reader = item.dataReader;
      if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
      final uri = Completer<Uri?>();
      final progress = reader.getValue<Uri>(Formats.fileUri, uri.complete, onError: (_) => uri.complete(null));
      if (progress == null) continue;
      final value = await uri.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
      if (value != null && value.isScheme('file')) paths.add(value.toFilePath());
    }
    return paths;
  }
}

/// Whether dropping [source] into [destination] moves it, as in File
/// Explorer: Ctrl copies, Shift moves; otherwise a move on the same drive
/// and a copy to another one. Files from other apps are copied. On macOS
/// it's as in Finder: Option copies, Cmd moves, and otherwise a move within
/// a volume and a copy to another one; what can't be taken from its folder
/// (a read-only volume, a folder that isn't the user's) is always copied.
bool dropMoves(String? source, String destination, {required bool fromThisApp}) {
  final keys = HardwareKeyboard.instance;
  if (Platform.isMacOS) {
    if (keys.isAltPressed) return false;
    // The system volume shares its device id with the user's, so this
    // comes before the volume check.
    if (source != null && macosCanWriteIn(p.dirname(source)) == false) return false;
    if (keys.isMetaPressed) return true;
    if (!fromThisApp || source == null) return false;
    // "/." so a folder that's a link counts where it points.
    return MacosFiles.sameVolume(source, p.join(destination, '.')) ?? false;
  }
  if (keys.isControlPressed || keys.isMetaPressed) return false;
  if (keys.isShiftPressed) return true;
  if (!fromThisApp || source == null) return false;
  if (!Platform.isWindows) return true;
  return p.rootPrefix(source).toLowerCase() == p.rootPrefix(destination).toLowerCase();
}

/// The look of a folder while files are dragged over it.
class DropHighlight extends StatelessWidget {
  const DropHighlight({super.key, required this.active, required this.child, this.radius = 8});

  final bool active;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      foregroundDecoration: active
          ? BoxDecoration(
              color: colors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: colors.primary, width: 1.5),
            )
          : null,
      child: child,
    );
  }
}
