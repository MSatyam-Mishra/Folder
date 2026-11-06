import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/auth_service.dart';
import 'package:folders/core/services/directory_services.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/features/vault/vault_store.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Private files, unlocked with the device's fingerprint, face or screen
/// lock. Locks again whenever Folders goes to the background.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key, this.store, this.auth});

  /// For tests.
  final VaultStore? store;
  final AuthService? auth;

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> with WidgetsBindingObserver {
  late final VaultStore _store = widget.store ?? VaultStore();
  late final AuthService _auth = widget.auth ?? AuthService();

  bool _unlocked = false;
  bool _noScreenLock = false;
  bool _unlocking = false;

  /// Leaving the app on purpose (file picker, share sheet): don't lock.
  bool _stayUnlocked = false;
  List<VaultItem>? _items;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phones pause in the background; desktop windows are only hidden
    // (minimized), never paused.
    final away = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;
    if (away &&
        _unlocked &&
        !_unlocking &&
        !_stayUnlocked &&
        !_noScreenLock) {
      setState(() {
        _unlocked = false;
        _items = null;
      });
    }
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    setState(() => _unlocking = true);
    final result = await _auth.unlock(reason: 'Unlock your vault');
    if (!mounted) return;
    setState(() {
      _unlocking = false;
      _unlocked = result != UnlockResult.failed;
      _noScreenLock = result == UnlockResult.noScreenLock;
    });
    if (_unlocked) await _reload();
  }

  Future<void> _reload() async {
    final items = await _store.list();
    if (mounted) setState(() => _items = items);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _addFiles() async {
    _stayUnlocked = true;
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    } finally {
      _stayUnlocked = false;
    }
    final paths = picked?.paths.nonNulls.toList() ?? const <String>[];
    if (paths.isEmpty) return;
    var added = 0;
    for (final path in paths) {
      try {
        // Android hands us temporary copies (moved in, nothing left over);
        // on desktops the path is the original, which stays put.
        await _store.add(File(path), keepOriginal: !Platform.isAndroid);
        added++;
      } catch (e) {
        debugPrint('Vault: adding $path failed: $e');
      }
    }
    await _reload();
    if (!mounted) return;
    _toast(added == paths.length
        ? 'Added $added ${added == 1 ? 'file' : 'files'}. The originals '
            'are still where they were.'
        : "Added $added of ${paths.length} files. Some couldn't be read.");
  }

  Future<void> _restore(VaultItem item) async {
    final downloads = await DirectoryService.findDownloadsDirectory();
    final fallback = downloads?.path ??
        (Platform.isAndroid ? ExplorerPaths.androidInternalStorage : p.dirname(item.originalPath));
    try {
      final path = await _store.restore(item, fallbackDir: fallback);
      await _reload();
      if (mounted) _toast('Restored to ${p.dirname(path)}');
    } catch (e) {
      if (mounted) _toast("Couldn't restore ${item.name}: $e");
    }
  }

  Future<void> _delete(VaultItem item) async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${item.name}"?'),
        content: const Text(
          "It will be permanently deleted from the vault. This can't be undone.",
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.delete(item);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final top = AppTopBarScaffold.contentTopInset(context);
    final items = _items;
    return ExplorerScaffold(
      title: 'Vault',
      trailing: _unlocked
          ? AppIconButton(
              icon: const Icon(LucideIcons.plus, size: 20),
              tooltip: 'Add files',
              onPressed: _addFiles,
            )
          : null,
      body: () {
        if (!_unlocked) {
          return ExplorerEmptyState(
            padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
            icon: LucideIcons.lockKeyhole,
            title: 'Vault is locked',
            description:
                'Unlock with your fingerprint, face or screen lock to see '
                'your private files.',
            actions: [
              FilledButton.icon(
                onPressed: _unlocking ? null : _unlock,
                icon: const Icon(LucideIcons.lockKeyholeOpen, size: 16),
                label: const Text('Unlock'),
              ),
            ],
          );
        }
        if (items == null) {
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: top + 8)),
            if (_noScreenLock)
              const SliverToBoxAdapter(child: _NoScreenLockNotice()),
            if (items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ExplorerEmptyState(
                  padding: const EdgeInsets.all(24),
                  icon: LucideIcons.lockKeyhole,
                  title: 'Your vault is empty',
                  description: Platform.isAndroid
                      ? 'Files in the vault are hidden from other apps and the '
                          'file list. Use Move to vault in a file\'s menu, or add '
                          'files here.'
                      // On a computer other programs can still reach the
                      // app's folder, and the files aren't encrypted.
                      : 'Files in the vault are moved out of your folders, and '
                          'Folders asks for your sign-in before showing them. '
                          "They aren't encrypted. Use Move to vault in a file's "
                          'menu, or add files here.',
                  actions: [
                    FilledButton.icon(
                      onPressed: _addFiles,
                      icon: const Icon(LucideIcons.plus, size: 16),
                      label: const Text('Add files'),
                    ),
                  ],
                ),
              )
            else
              SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, i) => _VaultRow(
                  item: items[i],
                  onOpen: () => FileOpener.open(
                    context,
                    items[i].file,
                    allowExternal: false,
                  ),
                  onRestore: () => _restore(items[i]),
                  onDelete: () => _delete(items[i]),
                ),
              ),
            SliverToBoxAdapter(
              child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
            ),
          ],
        );
      }(),
    );
  }
}

class _NoScreenLockNotice extends StatelessWidget {
  const _NoScreenLockNotice();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.shieldAlert, size: 18, color: colors.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This device has no screen lock, so anyone using it can open '
              'the vault. Set one in your phone\'s security settings.',
              style: text.bodySmall?.copyWith(color: colors.foreground),
            ),
          ),
        ],
      ),
    );
  }
}

class _VaultRow extends StatelessWidget {
  const _VaultRow({
    required this.item,
    required this.onOpen,
    required this.onRestore,
    required this.onDelete,
  });

  final VaultItem item;
  final VoidCallback onOpen;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final meta = [
      EntityFormat.size(item.size),
      'Added ${EntityFormat.date(item.added)}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onOpen,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                FileIcon(path: item.name, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                    ],
                  ),
                ),
                PopupMenuButton<VoidCallback>(
                  tooltip: 'More',
                  icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: onRestore,
                      child: const Row(
                        children: [
                          Icon(LucideIcons.undo2, size: 16),
                          SizedBox(width: 10),
                          Text('Restore'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: onDelete,
                      child: Row(
                        children: [
                          Icon(LucideIcons.trash2, size: 16, color: colors.destructive),
                          const SizedBox(width: 10),
                          Text('Delete', style: TextStyle(color: colors.destructive)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
