import 'dart:io';

import 'package:folder/core/router/file_opener.dart';
import 'package:folder/core/services/localsend/localsend.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/file_icons/file_icons.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

String lsSize(int bytes) => filesize(bytes, 1);

String lsSpeed(double bytesPerSecond) =>
    bytesPerSecond <= 0 ? '' : '${filesize(bytesPerSecond.round(), 1)}/s';

IconData lsDeviceIcon(LsDeviceType? type) => switch (type) {
  LsDeviceType.mobile => LucideIcons.smartphone,
  LsDeviceType.desktop => LucideIcons.monitor,
  LsDeviceType.web => LucideIcons.globe,
  LsDeviceType.headless => LucideIcons.terminal,
  LsDeviceType.server => LucideIcons.server,
  null => LucideIcons.monitorSmartphone,
};

/// Card section used by both panels: icon, title, trailing actions, body.
class LsSection extends StatelessWidget {
  const LsSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: colors.mutedForeground),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Muted one-line hint inside a section (empty lists).
class LsHint extends StatelessWidget {
  const LsHint(this.text, {super.key, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 16, color: colors.mutedForeground),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Transfer progress: status line, bar and byte/file counts.
class LsProgress extends StatelessWidget {
  const LsProgress({
    super.key,
    required this.status,
    required this.value,
    required this.detail,
    this.tone = Tone.neutral,
  });

  final String status;

  /// 0..1, or null while waiting.
  final double? value;
  final String detail;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final percent = value == null ? null : (value! * 100).clamp(0, 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                status,
                style: text.bodyMedium?.copyWith(
                  color: tone == Tone.neutral
                      ? colors.foreground
                      : context.toneColor(tone),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (percent != null)
              Text(
                '$percent%',
                style: text.labelMedium?.copyWith(
                  color: colors.foreground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: value,
          color: tone == Tone.destructive ? colors.destructive : null,
        ),
        const SizedBox(height: 6),
        Text(
          detail,
          style: text.bodySmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Done / failed mark at the end of a transfer row.
class LsFileState extends StatelessWidget {
  const LsFileState({super.key, required this.done, required this.failed});

  final bool done;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    if (done) {
      return Icon(
        LucideIcons.circleCheck,
        size: 18,
        color: context.toneColor(Tone.success),
      );
    }
    if (failed) {
      return Icon(
        LucideIcons.circleX,
        size: 18,
        color: context.colors.destructive,
      );
    }
    return const SizedBox.shrink();
  }
}

/// A failure message under a transfer row's title.
class LsErrorText extends StatelessWidget {
  const LsErrorText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.colors.destructive,
            ),
      );
}

/// Icon for a (possibly folder-relative) file name.
class LsFileIcon extends StatelessWidget {
  const LsFileIcon(this.name, {super.key, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) =>
      FileIcon(path: p.basename(name), size: size);
}

/// Reveals [path] in the system file manager on desktop; on phones shows the
/// folder in a sheet where files can be opened.
Future<void> lsShowInFolder(BuildContext context, String path) async {
  final isDir = FileSystemEntity.isDirectorySync(path);
  final folder = isDir ? path : p.dirname(path);
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', isDir ? [path] : ['/select,', path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', isDir ? [path] : ['-R', path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [folder]);
      return;
    }
  } catch (_) {
    // Fall back to the in-app listing below.
  }
  if (!context.mounted) return;
  await AppSheet.show<void>(
    context,
    child: LsFolderSheet(folder: folder, highlight: isDir ? null : path),
  );
}

/// Simple in-app folder listing (phones): open files, enter sub-folders.
class LsFolderSheet extends StatefulWidget {
  const LsFolderSheet({super.key, required this.folder, this.highlight});

  final String folder;
  final String? highlight;

  @override
  State<LsFolderSheet> createState() => _LsFolderSheetState();
}

class _LsFolderSheetState extends State<LsFolderSheet> {
  late String _dir = widget.folder;
  List<FileSystemEntity> _entries = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await Directory(
        _dir,
      ).list().where((e) => !p.basename(e.path).startsWith('.')).toList();
      list.sort((a, b) {
        final da = a is Directory ? 0 : 1;
        final db = b is Directory ? 0 : 1;
        if (da != db) return da - db;
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });
      if (mounted) {
        setState(() {
          _entries = list;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final height = MediaQuery.sizeOf(context).height * 0.6;
    final canGoUp =
        !p.equals(_dir, widget.folder) && p.isWithin(widget.folder, _dir);
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (canGoUp)
                AppIconButton(
                  icon: const Icon(LucideIcons.arrowUp),
                  tooltip: 'Up',
                  onPressed: () {
                    setState(() => _dir = p.dirname(_dir));
                    _load();
                  },
                )
              else
                const FolderIcon(size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.basename(_dir),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium,
                    ),
                    Text(
                      _dir,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          Expanded(
            child: _error != null
                ? ViewerMessage(
                    icon: LucideIcons.folderX,
                    title: "Can't open this folder",
                    details: _error,
                  )
                : _entries.isEmpty
                ? const ViewerMessage(
                    icon: LucideIcons.folderOpen,
                    title: 'This folder is empty',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 8),
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      final name = p.basename(e.path);
                      final isDir = e is Directory;
                      return ListRow(
                        selected: e.path == widget.highlight,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        leading: isDir
                            ? const FolderIcon(size: 40)
                            : LsFileIcon(name),
                        title: name,
                        subtitle: isDir
                            ? null
                            : lsSize((e as File).statSync().size),
                        onTap: () {
                          if (isDir) {
                            setState(() => _dir = e.path);
                            _load();
                          } else {
                            FileOpener.open(context, e as File);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
