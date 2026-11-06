import 'dart:io';

import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folders/core/services/video_downloader/ytdlp_models.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'downloader_text.dart';
import 'empty_state.dart';

enum _HistoryAction { open, share, copyLink, deleteFile, remove }

/// A playlist's downloads, shown as one folder in the history.
class HistoryFolder {
  HistoryFolder(this.name);

  final String name;

  /// Newest first.
  final List<HistoryEntry> entries = [];
}

/// [history] (newest first) with each playlist's downloads gathered into one
/// [HistoryFolder], placed where its newest download is. Downloads from
/// before playlists were recorded count as one when they sit in a folder of
/// their own inside [outputDir], where playlists are saved.
List<Object> groupHistory(List<HistoryEntry> history, String outputDir) {
  final items = <Object>[];
  final folders = <String, HistoryFolder>{};
  for (final entry in history) {
    final name = _playlistOf(entry, outputDir);
    if (name == null) {
      items.add(entry);
    } else if (folders[name] case final folder?) {
      folder.entries.add(entry);
    } else {
      items.add(folders[name] = HistoryFolder(name)..entries.add(entry));
    }
  }
  return items;
}

String? _playlistOf(HistoryEntry entry, String outputDir) {
  if (entry.playlist case final name?) return name;
  if (outputDir.isEmpty) return null;
  final dir = p.dirname(entry.filePath);
  return p.equals(p.dirname(dir), outputDir) ? p.basename(dir) : null;
}

/// Finished downloads: open, share or delete them. A playlist's downloads
/// are in a folder named after it.
class HistoryList extends StatelessWidget {
  const HistoryList({super.key, required this.controller, this.padding = EdgeInsets.zero});

  final VideoDownloaderController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final history = controller.history;
        if (history.isEmpty) {
          return EmptyState(
            icon: LucideIcons.history,
            title: 'No downloads yet',
            message: 'Finished downloads are listed here.',
            padding: padding,
          );
        }
        final items = groupHistory(history, controller.outputDir);
        return ListView.builder(
          padding: padding,
          itemCount: items.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return SectionLabel(
                '${history.length} ${history.length == 1 ? 'download' : 'downloads'}',
                padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
                trailing: TextButton(
                  onPressed: () => _confirmClear(context),
                  child: const Text('Clear history'),
                ),
              );
            }
            return switch (items[i - 1]) {
              final HistoryFolder folder => _FolderTile(
                  key: ValueKey('playlist:${folder.name}'),
                  folder: folder,
                  controller: controller,
                ),
              final entry as HistoryEntry =>
                _HistoryTile(key: ValueKey(entry.id), entry: entry, controller: controller),
            };
          },
        );
      },
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text('The list is cleared. Downloaded files are kept.'),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok ?? false) await controller.clearHistory();
  }
}

/// A card in the history: a download or a playlist's folder.
class _TileCard extends StatelessWidget {
  const _TileCard({required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A playlist's downloads: opens the list of them.
class _FolderTile extends StatelessWidget {
  const _FolderTile({super.key, required this.folder, required this.controller});

  final HistoryFolder folder;
  final VideoDownloaderController controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final entries = folder.entries;
    final bytes = entries.fold<int>(0, (sum, e) => sum + (e.sizeBytes ?? 0));
    final subtitle = [
      entries.length == 1 ? '1 download' : '${entries.length} downloads',
      if (bytes > 0) DownloaderText.bytes(bytes),
      _HistoryTile._date.format(entries.first.completedAt),
    ].join(' · ');
    return _TileCard(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => _PlaylistScreen(name: folder.name, controller: controller),
        ),
      ),
      child: Row(
        children: [
          const FolderIcon(size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  folder.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Icon(LucideIcons.chevronRight, size: 18, color: context.colors.mutedForeground),
          ),
        ],
      ),
    );
  }
}

/// The downloads of the playlist [name], newest first. Downloads still
/// running join it as they finish.
class _PlaylistScreen extends StatelessWidget {
  const _PlaylistScreen({required this.name, required this.controller});

  final String name;
  final VideoDownloaderController controller;

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: name,
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final top = DockedGlossyTopBar.contentTopInset(context);
          final bottom = MediaQuery.paddingOf(context).bottom;
          final padding = EdgeInsets.fromLTRB(16, top + 8, 16, 24 + bottom);
          final entries = [
            for (final item in groupHistory(controller.history, controller.outputDir))
              if (item is HistoryFolder && item.name == name) ...item.entries,
          ];
          if (entries.isEmpty) {
            return EmptyState(
              icon: LucideIcons.folderOpen,
              title: 'No downloads here',
              message: "This playlist's downloads were removed from the history.",
              padding: padding,
            );
          }
          return ReadableWidth(
            maxWidth: 760,
            child: ListView.builder(
              padding: padding,
              itemCount: entries.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return SectionLabel(
                    entries.length == 1 ? '1 download' : '${entries.length} downloads',
                    padding: const EdgeInsets.fromLTRB(4, 4, 0, 8),
                    trailing: TextButton(
                      onPressed: () => _confirmRemove(context, entries),
                      child: const Text('Remove from history'),
                    ),
                  );
                }
                final entry = entries[i - 1];
                return _HistoryTile(key: ValueKey(entry.id), entry: entry, controller: controller);
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, List<HistoryEntry> entries) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from history?'),
        content: Text('“$name” is removed from the list. Downloaded files are kept.'),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    await controller.removeHistoryEntries(entries);
    if (context.mounted) Navigator.pop(context);
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({super.key, required this.entry, required this.controller});

  final HistoryEntry entry;
  final VideoDownloaderController controller;

  static final _date = DateFormat('d MMM y, HH:mm');

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final exists = File(entry.filePath).existsSync();
    final subtitle = exists
        ? [
            if (entry.sizeBytes != null) DownloaderText.bytes(entry.sizeBytes),
            if (entry.duration != null) DownloaderText.duration(entry.duration),
            _date.format(entry.completedAt),
            DownloaderText.site(entry.extractor, entry.url),
          ].where((s) => s.isNotEmpty).join(' · ')
        : 'File no longer exists';

    return _TileCard(
      onTap: exists ? () => _open(context) : null,
      child: Row(
        children: [
          Opacity(
            opacity: exists ? 1 : 0.4,
            child: FileIcon(path: entry.filePath, size: 40),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title.isEmpty ? p.basename(entry.filePath) : entry.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    color: exists ? null : colors.destructive,
                  ),
                ),
              ],
            ),
          ),
          MenuIconButton<_HistoryAction>(
            onSelected: (action) => _run(context, action, exists),
            itemBuilder: (context) => [
              if (exists) ...[
                menuItem(
                  value: _HistoryAction.open,
                  icon: LucideIcons.externalLink,
                  label: 'Open',
                ),
                if (Desktop.canShareFiles)
                  menuItem(
                    value: _HistoryAction.share,
                    icon: LucideIcons.share2,
                    label: 'Share',
                  ),
              ],
              menuItem(
                value: _HistoryAction.copyLink,
                icon: LucideIcons.link,
                label: 'Copy link',
              ),
              const PopupMenuDivider(),
              menuItem(
                value: _HistoryAction.remove,
                icon: LucideIcons.listX,
                label: 'Remove from history',
              ),
              if (exists)
                menuItem(
                  value: _HistoryAction.deleteFile,
                  icon: LucideIcons.trash2,
                  label: 'Delete file',
                  destructive: true,
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _open(BuildContext context) => FileOpener.open(context, File(entry.filePath));

  Future<void> _run(BuildContext context, _HistoryAction action, bool exists) async {
    switch (action) {
      case _HistoryAction.open:
        _open(context);
      case _HistoryAction.share:
        await SharePlus.instance.share(ShareParams(
          files: [XFile(entry.filePath)],
          subject: entry.title,
        ));
      case _HistoryAction.copyLink:
        await Clipboard.setData(ClipboardData(text: entry.url));
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Link copied')));
        }
      case _HistoryAction.deleteFile:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete file?'),
            content: Text('${p.basename(entry.filePath)} will be deleted from this device.'),
            actions: [
              OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.destructive,
                  foregroundColor: context.colors.destructiveForeground,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (!(ok ?? false)) return;
        try {
          await controller.removeHistory(entry, deleteFile: true);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text("Couldn't delete the file: $e")));
          }
        }
      case _HistoryAction.remove:
        await controller.removeHistory(entry);
    }
  }
}
