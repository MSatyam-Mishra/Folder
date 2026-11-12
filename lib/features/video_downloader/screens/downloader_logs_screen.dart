import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/services/video_downloader/downloader_log.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum _LogAction { copyAll, save, share, clear }

/// The downloader's log: entries grouped by day, newest first; each opens
/// to show its details. Copy one or all, save as a .txt file or share it.
class DownloaderLogsScreen extends StatelessWidget {
  const DownloaderLogsScreen({super.key, required this.log});

  final DownloaderLog log;

  static String _fileName() =>
      'folders-downloader-log-${DateFormat('yyyyMMdd-HHmm').format(DateTime.now())}.txt';

  void _say(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(BuildContext context, _LogAction action) async {
    switch (action) {
      case _LogAction.copyAll:
        await Clipboard.setData(ClipboardData(text: log.toText()));
        if (context.mounted) _say(context, 'The log was copied');
      case _LogAction.save:
        await _save(context);
      case _LogAction.share:
        await _share(context);
      case _LogAction.clear:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Clear the log?'),
            content: const Text('Every entry is deleted. Downloads and history stay.'),
            actions: [
              OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.destructive,
                  foregroundColor: context.colors.destructiveForeground,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Clear'),
              ),
            ],
          ),
        );
        if (ok == true) await log.clear();
    }
  }

  Future<void> _save(BuildContext context) async {
    final text = log.toText();
    final bytes = utf8.encode(text);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save the log',
        fileName: _fileName(),
        type: FileType.custom,
        allowedExtensions: const ['txt'],
        bytes: bytes,
      );
      if (path == null) return;
      // Computers get only the path back.
      if (!Platform.isAndroid && !Platform.isIOS) await File(path).writeAsBytes(bytes, flush: true);
      if (context.mounted) _say(context, 'Saved ${p.basename(path)}');
    } catch (e) {
      if (context.mounted) _say(context, "Couldn't save the log: $e");
    }
  }

  Future<void> _share(BuildContext context) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, _fileName()));
      await file.writeAsString(log.toText(), flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Folders video downloader log',
      ));
    } catch (e) {
      if (context.mounted) _say(context, "Couldn't share the log: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        // Newest first; a download that ended while the app was closed is
        // logged later with the time it ended.
        final entries = log.entries.toList()..sort((a, b) => b.time.compareTo(a.time));
        return ExplorerScaffold(
          title: 'Downloader log',
          trailing: MenuIconButton<_LogAction>(
            enabled: entries.isNotEmpty,
            tooltip: 'Log',
            onSelected: (action) => _run(context, action),
            itemBuilder: (_) => [
              menuItem(value: _LogAction.copyAll, icon: LucideIcons.copy, label: 'Copy all'),
              menuItem(value: _LogAction.save, icon: LucideIcons.save, label: 'Save as .txt'),
              if (Desktop.canShareFiles)
                menuItem(value: _LogAction.share, icon: LucideIcons.share2, label: 'Share'),
              const PopupMenuDivider(),
              menuItem(
                value: _LogAction.clear,
                icon: LucideIcons.trash2,
                label: 'Clear the log',
                destructive: true,
              ),
            ],
          ),
          body: Padding(
            padding: EdgeInsets.only(top: DockedGlossyTopBar.contentTopInset(context)),
            child: entries.isEmpty
                ? const ViewerMessage(
                    icon: LucideIcons.scrollText,
                    title: 'Nothing logged yet',
                    message: 'Downloads, links read, engine updates and errors show up here.',
                  )
                : ReadableWidth(
                    maxWidth: 860,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 32 + MediaQuery.paddingOf(context).bottom),
                      children: [
                        for (final day in _byDay(entries)) ...[
                          SectionLabel(_dayLabel(day.first.time), padding: const EdgeInsets.fromLTRB(4, 16, 4, 8)),
                          SurfaceCard(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            clip: true,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < day.length; i++) ...[
                                  if (i > 0) const Divider(height: 1),
                                  _LogTile(entry: day[i], onCopied: () => _say(context, 'Entry copied')),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  static List<List<LogEntry>> _byDay(List<LogEntry> entries) {
    final days = <List<LogEntry>>[];
    for (final e in entries) {
      final last = days.isEmpty ? null : days.last.first.time;
      if (last != null && last.year == e.time.year && last.month == e.time.month && last.day == e.time.day) {
        days.last.add(e);
      } else {
        days.add([e]);
      }
    }
    return days;
  }

  static String _dayLabel(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(t.year, t.month, t.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return DateFormat(t.year == now.year ? 'EEEE d MMMM' : 'd MMMM y').format(t);
  }
}

class _LogTile extends StatefulWidget {
  const _LogTile({required this.entry, required this.onCopied});

  final LogEntry entry;
  final VoidCallback onCopied;

  @override
  State<_LogTile> createState() => _LogTileState();
}

class _LogTileState extends State<_LogTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final colors = context.colors;
    final color = switch (e.level) {
      LogLevel.error => colors.destructive,
      LogLevel.warning => context.toneColor(Tone.warning),
      LogLevel.info => colors.mutedForeground,
    };
    final icon = switch (e.level) {
      LogLevel.error => LucideIcons.circleAlert,
      LogLevel.warning => LucideIcons.triangleAlert,
      LogLevel.info => switch (e.category) {
          LogCategory.download => LucideIcons.download,
          LogCategory.link => LucideIcons.link,
          LogCategory.engine => LucideIcons.package,
          LogCategory.cookies => LucideIcons.cookie,
          LogCategory.maintenance => LucideIcons.brushCleaning,
        },
    };
    final details = e.details;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(icon, color: color, size: 20),
          title: Text(e.title, maxLines: _open ? 4 : 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('${DownloaderLog.clock(e.time)} · ${e.category.label}'),
          onTap: details == null ? null : () => setState(() => _open = !_open),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIconButton(
                icon: const Icon(LucideIcons.copy, size: 16),
                tooltip: 'Copy',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: e.toText()));
                  widget.onCopied();
                },
              ),
              if (details != null)
                Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 16, color: colors.mutedForeground),
            ],
          ),
        ),
        if (_open && details != null)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.muted.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.border),
            ),
            child: SelectableText(
              details,
              style: CodeFont.style(fontSize: 11.5, color: colors.foreground).copyWith(height: 1.45),
            ),
          ),
      ],
    );
  }
}
