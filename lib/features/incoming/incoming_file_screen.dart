import 'dart:async';
import 'dart:io';

import 'package:folder/core/router/file_opener.dart';
import 'package:folder/core/services/incoming_files.dart';
import 'package:folder/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folder/shared/ui/app_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Opens a file another app sent to Folder ("Open with").
///
/// When [closeAppWhenDone] is true (the app was launched just for this file)
/// leaving the viewer returns to the app that sent it, like other viewers.
class IncomingFileScreen extends StatefulWidget {
  const IncomingFileScreen({
    super.key,
    required this.incoming,
    required this.closeAppWhenDone,
  });

  final IncomingFile incoming;
  final bool closeAppWhenDone;

  @override
  State<IncomingFileScreen> createState() => _IncomingFileScreenState();
}

class _IncomingFileScreenState extends State<IncomingFileScreen> {
  StreamSubscription<({String uri, int copied, int total})>? _progressSub;
  bool _resolving = true;
  int? _copied;
  int _total = -1;
  String _status = 'Opening…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _progressSub = IncomingFiles.copyProgress
        .where((e) => e.uri == widget.incoming.uri)
        .listen((e) => setState(() {
              _copied = e.copied;
              _total = e.total;
            }));
    _run();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    if (_resolving) unawaited(IncomingFiles.cancel(widget.incoming));
    super.dispose();
  }

  Future<void> _run() async {
    final ResolvedIncomingFile resolved;
    try {
      resolved = await IncomingFiles.resolve(widget.incoming);
    } on IncomingFileException catch (e) {
      _resolving = false;
      if (!mounted) return;
      if (e.cancelled) return _close();
      setState(() => _error = e.message);
      return;
    }
    _resolving = false;
    if (!mounted) return;
    setState(() => _copied = null);

    final file = resolved.file;
    final before = resolved.isCopy ? _snapshot(file.parent) : null;
    await FileOpener.open(context, file, allowExternal: false);
    if (!mounted) return;
    if (before != null) {
      await _keepEdits(file, before);
      try {
        await file.parent.delete(recursive: true);
      } catch (_) {
        // Stale copies are cleared on the next incoming file.
      }
    }
    if (mounted) _close();
  }

  void _close() {
    if (widget.closeAppWhenDone) {
      SystemNavigator.pop();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Map<String, (int, int)> _snapshot(Directory dir) {
    final result = <String, (int, int)>{};
    try {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final stat = entity.statSync();
        result[p.basename(entity.path)] =
            (stat.size, stat.modified.millisecondsSinceEpoch);
      }
    } catch (_) {}
    return result;
  }

  /// Saves edits made to a cache copy: back through the URI when allowed,
  /// otherwise wherever the user picks. Also covers new files a viewer wrote
  /// next to the copy (Save as copy, Save as .docx).
  Future<void> _keepEdits(File original, Map<String, (int, int)> before) async {
    final after = _snapshot(original.parent);
    final changed = [
      for (final entry in after.entries)
        if (before[entry.key] != entry.value)
          File(p.join(original.parent.path, entry.key)),
    ];
    if (changed.isEmpty) return;

    final unsaved = changed.where((f) => f.path != original.path).toList();
    var reason = 'These files are in a temporary copy and will be deleted.';
    if (changed.any((f) => f.path == original.path)) {
      if (widget.incoming.writable) {
        setState(() => _status = 'Saving changes…');
        try {
          await IncomingFiles.writeBack(widget.incoming, original);
        } on IncomingFileException catch (e) {
          unsaved.insert(0, original);
          reason = "Couldn't save to the original file: ${e.message}";
        }
      } else {
        unsaved.insert(0, original);
        reason = "The app that opened this file doesn't allow saving back to "
            'it, so your changes are in a temporary copy.';
      }
    }
    if (unsaved.isEmpty || !mounted) return;

    final save = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Keep your changes?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(reason),
            const SizedBox(height: 12),
            for (final f in unsaved)
              Text('• ${p.basename(f.path)}', overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Save…'),
          ),
        ],
      ),
    );
    if (save != true) return;
    for (final f in unsaved) {
      try {
        await FilePicker.platform.saveFile(
          dialogTitle: 'Save ${p.basename(f.path)}',
          fileName: p.basename(f.path),
          bytes: await f.readAsBytes(),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't save ${p.basename(f.path)}: $e")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final copied = _copied;
    final error = _error;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: error != null
            ? ExplorerEmptyState(
                destructive: true,
                icon: LucideIcons.fileX,
                title: "Couldn't open this file",
                description: error,
                actions: [
                  FilledButton(onPressed: _close, child: const Text('Close')),
                ],
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          copied != null ? 'Preparing file' : _status,
                          textAlign: TextAlign.center,
                          style: text.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          copied != null
                              ? 'Copying ${_formatSize(copied)}'
                                  '${_total > 0 ? ' of ${_formatSize(_total)}' : ''}…'
                              : 'This only takes a moment.',
                          textAlign: TextAlign.center,
                          style: text.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        LinearProgressIndicator(
                          minHeight: 6,
                          value: copied != null && _total > 0
                              ? (copied / _total).clamp(0.0, 1.0)
                              : null,
                        ),
                        if (copied != null) ...[
                          const SizedBox(height: 16),
                          Center(
                            child: OutlinedButton(
                              onPressed: () =>
                                  IncomingFiles.cancel(widget.incoming),
                              child: const Text('Cancel'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
