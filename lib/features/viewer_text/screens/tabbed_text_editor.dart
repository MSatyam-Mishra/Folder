import 'dart:io';

import 'package:folder/core/services/new_files.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/features/viewer_text/screens/text_editor_screen.dart';
import 'package:folder/shared/file_icons/file_icons.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Multi-tab text/code editor. Each tab keeps its state while hidden.
class TabbedTextEditorScreen extends StatefulWidget {
  final File initialFile;

  const TabbedTextEditorScreen({super.key, required this.initialFile});

  @override
  State<TabbedTextEditorScreen> createState() => _TabbedTextEditorScreenState();
}

class _EditorTab {
  _EditorTab(this.file, {this.isCopy = false});

  File file;

  /// [file] is the file picker's temporary copy, not the user's file, so
  /// saving goes through "Save a copy" instead of overwriting it.
  final bool isCopy;
  final GlobalKey<TextEditorPaneState> key = GlobalKey();
  bool dirty = false;
}

class _TabbedTextEditorScreenState extends State<TabbedTextEditorScreen> {
  late final List<_EditorTab> _tabs = [_EditorTab(widget.initialFile)];
  int _index = 0;

  _EditorTab get _current => _tabs[_index];
  bool get _anyDirty => _tabs.any((t) => t.dirty);

  Future<void> _addFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    final picked = result?.files.single;
    final path = picked?.path;
    if (picked == null || path == null || !mounted) return;
    var file = File(path);
    var isCopy = false;
    // On Android and iOS the picker hands back a copy in the app's cache;
    // edits saved there would never reach the real file.
    if (Platform.isAndroid || Platform.isIOS) {
      final real = await _realPathFor(picked);
      if (real != null) {
        file = File(real);
      } else {
        isCopy = true;
      }
    }
    if (!mounted) return;
    final existing = _tabs.indexWhere((t) => p.equals(t.file.path, file.path));
    setState(() {
      if (existing >= 0) {
        _index = existing;
      } else {
        _tabs.add(_EditorTab(file, isCopy: isCopy));
        _index = _tabs.length - 1;
      }
    });
  }

  /// Maps an Android document URI back to the file it names when the
  /// provider exposes one (internal/SD storage, "raw:" downloads) and the app
  /// can read it. Returns null otherwise (other providers, iOS).
  static Future<String?> _realPathFor(PlatformFile picked) async {
    if (!Platform.isAndroid) return null;
    final uri = Uri.tryParse(picked.identifier ?? '');
    if (uri == null || uri.scheme != 'content') return null;
    final segments = uri.pathSegments; // decoded: "primary:Documents/a.txt"
    final docIndex = segments.lastIndexOf('document');
    if (docIndex < 0 || docIndex + 1 >= segments.length) return null;
    final docId = segments[docIndex + 1];
    String? candidate;
    switch (uri.authority) {
      case 'com.android.externalstorage.documents':
        final colon = docId.indexOf(':');
        if (colon <= 0) return null;
        final volume = docId.substring(0, colon);
        final relative = docId.substring(colon + 1);
        final root = volume.toLowerCase() == 'primary'
            ? '/storage/emulated/0'
            : '/storage/$volume';
        candidate = relative.isEmpty ? null : '$root/$relative';
      case 'com.android.providers.downloads.documents':
        if (docId.startsWith('raw:')) candidate = docId.substring(4);
    }
    if (candidate == null) return null;
    try {
      // Same size as the copy we were given, so it's the same file.
      if (await File(candidate).length() != picked.size) return null;
    } catch (_) {
      return null;
    }
    return candidate;
  }

  /// Saves or discards [tab]'s edits after asking. Returns false if the
  /// user cancelled or the save failed.
  Future<bool> _resolveUnsaved(_EditorTab tab) async {
    // Loop: keystrokes typed while a save is running leave the tab dirty.
    while (tab.dirty) {
      final choice = await _confirmDiscard(p.basename(tab.file.path));
      if (choice == null) return false;
      if (!choice) return true;
      if (!(await tab.key.currentState?.save() ?? false)) return false;
      if (!mounted) return false;
    }
    return true;
  }

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    if (!await _resolveUnsaved(tab)) return;
    if (!mounted) return;
    if (_tabs.length == 1) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      final position = _tabs.indexOf(tab);
      if (position < 0) return;
      _tabs.removeAt(position);
      if (position < _index) _index--;
      if (_index >= _tabs.length) _index = _tabs.length - 1;
    });
  }

  /// null = cancel, true = save first, false = discard.
  Future<bool?> _confirmDiscard(String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved changes'),
        content: Text('Save changes to $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: context.colors.destructive,
            ),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCurrent() async {
    final tab = _current;
    final ok = await tab.key.currentState?.save() ?? false;
    if (ok && mounted) {
      final name = p.basename(tab.file.path);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tab.isCopy ? 'Saved a copy of $name' : 'Saved $name')),
      );
    }
  }

  Future<void> _handlePop() async {
    for (final tab in _tabs.where((t) => t.dirty).toList()) {
      if (!await _resolveUnsaved(tab)) return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return PopScope(
      canPop: !_anyDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handlePop();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveCurrent,
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _saveCurrent,
          // macOS: ⌘F, and ⌥⌘F to replace (⌘H hides the app).
          if (Platform.isMacOS) ...{
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                _current.key.currentState?.toggleFind(),
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true, alt: true):
                () => _current.key.currentState?.toggleFind(replace: true),
          } else ...{
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
                _current.key.currentState?.toggleFind(),
            const SingleActivator(LogicalKeyboardKey.keyH, control: true): () =>
                _current.key.currentState?.toggleFind(replace: true),
          },
        },
        child: ExplorerScaffold(
          title: p.basename(_current.file.path),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconButton(
                icon: const Icon(LucideIcons.filePlus2),
                tooltip: 'Open another file',
                onPressed: _addFile,
              ),
              AppIconButton(
                icon: Icon(
                  LucideIcons.save,
                  color: _current.dirty ? colors.primary : null,
                ),
                tooltip: 'Save',
                // A new file can be saved as it is, to give it its name.
                onPressed: _current.dirty || UntitledFiles.isUntitled(_current.file) ? _saveCurrent : null,
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Padding(
            padding: EdgeInsets.only(
              top: DockedGlossyTopBar.contentTopInset(context),
            ),
            child: Column(
              children: [
                if (_tabs.length > 1) _buildTabStrip(),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: [
                      for (final tab in _tabs)
                        TextEditorPane(
                          key: tab.key,
                          file: tab.file,
                          saveAsCopy: tab.isCopy,
                          onFileNamed: (file) => setState(() => tab.file = file),
                          onDirtyChanged: (dirty) {
                            if (tab.dirty != dirty) {
                              setState(() => tab.dirty = dirty);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Open files as tabs: the active one raised, unsaved ones marked with a
  /// dot; each closes with its own button.
  Widget _buildTabStrip() {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.4),
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: SizedBox(
        height: 44,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          itemCount: _tabs.length,
          separatorBuilder: (_, _) => const SizedBox(width: 4),
          itemBuilder: (context, i) => _EditorTabChip(
            name: p.basename(_tabs[i].file.path),
            dirty: _tabs[i].dirty,
            selected: i == _index,
            onTap: () => setState(() => _index = i),
            onClose: () => _closeTab(i),
          ),
        ),
      ),
    );
  }
}

class _EditorTabChip extends StatelessWidget {
  const _EditorTabChip({
    required this.name,
    required this.dirty,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String name;
  final bool dirty;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? colors.background : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? colors.border : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 10, right: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FileIcon(path: name, size: 16),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                    color: selected ? colors.foreground : colors.mutedForeground,
                  ),
                ),
              ),
              if (dirty) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Unsaved changes',
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: colors.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 2),
              ToolButton(
                icon: LucideIcons.x,
                tooltip: 'Close',
                size: 28,
                iconSize: 14,
                color: colors.mutedForeground,
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
