import 'package:folder/core/formats/archive_backend.dart';
import 'package:folder/core/formats/archive_extract.dart';
import 'package:folder/features/viewer_archive/archive_ui_utils.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Asks for an archive password. Returns null when cancelled.
Future<String?> showArchivePasswordDialog(
  BuildContext context, {
  required String archiveName,
  bool wrongPassword = false,
  String? detail,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _PasswordDialog(
      archiveName: archiveName,
      wrongPassword: wrongPassword,
      detail: detail,
    ),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.archiveName,
    required this.wrongPassword,
    this.detail,
  });

  final String archiveName;
  final bool wrongPassword;
  final String? detail;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isEmpty) return;
    Navigator.pop(context, _controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            LucideIcons.lock,
            size: 18,
            color: widget.wrongPassword ? colors.destructive : colors.foreground,
          ),
          const SizedBox(width: 10),
          Text(widget.wrongPassword ? 'Wrong password' : 'Password required'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.wrongPassword
                  ? 'That password didn\'t work for "${widget.archiveName}". '
                      'Try again.'
                  : widget.detail ??
                      '"${widget.archiveName}" is password protected.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: 'Password',
                prefixIcon: const Icon(LucideIcons.keyRound, size: 16),
                errorText: widget.wrongPassword ? ' ' : null,
                errorStyle: const TextStyle(height: 0, fontSize: 0),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                    size: 16,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Remembered until you close this archive.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
    );
  }
}

/// Asks what to do with files that already exist. Null cancels.
Future<ConflictPolicy?> showConflictDialog(
  BuildContext context,
  int count,
  List<String> examples,
) {
  return showDialog<ConflictPolicy>(
    context: context,
    builder: (context) {
      final colors = context.colors;
      return AlertDialog(
        title: Text(
          count == 1 ? 'File already exists' : '$count files already exist',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Choose what to do with files that are already in '
                  'the destination.'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.muted,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in examples.take(3))
                      Text(
                        e,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: CodeFont.style(
                          fontSize: 12,
                          color: colors.foreground,
                          height: 1.6,
                        ),
                      ),
                    if (count > 3)
                      Text(
                        '…and ${count - 3} more',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, ConflictPolicy.skip),
            child: const Text('Skip'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, ConflictPolicy.rename),
            child: const Text('Keep both'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(context, ConflictPolicy.overwrite),
            child: const Text('Replace'),
          ),
        ],
      );
    },
  );
}

class ExtractOptions {
  const ExtractOptions(this.destination, this.policy);
  final String destination;
  final ConflictPolicy policy;
}

/// Bottom sheet to confirm an extraction and pick where it goes.
Future<ExtractOptions?> showExtractSheet(
  BuildContext context, {
  required String title,
  required String parent,
  required String folderName,
  required int fileCount,
  required int totalBytes,
  int? freeBytes,
}) {
  return AppSheet.show<ExtractOptions>(
    context,
    child: _ExtractSheet(
      title: title,
      parent: parent,
      folderName: folderName,
      fileCount: fileCount,
      totalBytes: totalBytes,
      freeBytes: freeBytes,
    ),
  );
}

class _ExtractSheet extends StatefulWidget {
  const _ExtractSheet({
    required this.title,
    required this.parent,
    required this.folderName,
    required this.fileCount,
    required this.totalBytes,
    this.freeBytes,
  });

  final String title;
  final String parent;
  final String folderName;
  final int fileCount;
  final int totalBytes;
  final int? freeBytes;

  @override
  State<_ExtractSheet> createState() => _ExtractSheetState();
}

class _ExtractSheetState extends State<_ExtractSheet> {
  late String _parent = widget.parent;
  bool _ownFolder = true;
  ConflictPolicy _policy = ConflictPolicy.ask;

  String get _destination =>
      _ownFolder ? p.join(_parent, widget.folderName) : _parent;

  Future<void> _pick() async {
    String? picked;
    try {
      picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Extract to',
        initialDirectory: _parent,
      );
    } catch (_) {
      picked = null;
    }
    if (!mounted) return;
    if (picked == null || picked.isEmpty) return;
    if (picked.startsWith('content://') || picked == '/') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That location can\'t be written to.')),
      );
      return;
    }
    setState(() => _parent = picked!);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final free = widget.freeBytes;
    final short = free != null && widget.totalBytes > free;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          '${widget.fileCount} ${widget.fileCount == 1 ? 'file' : 'files'}'
          ' · ${formatBytes(widget.totalBytes)}'
          '${free == null ? '' : ' · ${formatBytes(free)} free'}',
          style: text.bodySmall?.copyWith(
            color: short ? colors.destructive : null,
          ),
        ),
        const SectionLabel('Destination'),
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              const IconBox(LucideIcons.folderOpen, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _destination,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _pick,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('Change'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _ownFolder,
          onChanged: (v) => setState(() => _ownFolder = v ?? true),
          title: Text('In a new folder "${widget.folderName}"'),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SectionLabel(
          'If a file already exists',
          padding: EdgeInsets.fromLTRB(4, 8, 4, 8),
        ),
        SegmentedButton<ConflictPolicy>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ConflictPolicy.ask, label: Text('Ask')),
            ButtonSegment(value: ConflictPolicy.skip, label: Text('Skip')),
            ButtonSegment(
              value: ConflictPolicy.overwrite,
              label: Text('Replace'),
            ),
            ButtonSegment(
              value: ConflictPolicy.rename,
              label: Text('Keep both'),
            ),
          ],
          selected: {_policy},
          onSelectionChanged: (s) => setState(() => _policy = s.first),
        ),
        if (short)
          const ViewerNotice(
            icon: LucideIcons.hardDrive,
            tone: Tone.destructive,
            margin: EdgeInsets.only(top: 12),
            message: 'There isn\'t enough free space for everything.',
          ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => Navigator.pop(
                context,
                ExtractOptions(_destination, _policy),
              ),
              icon: const Icon(LucideIcons.packageOpen, size: 16),
              label: const Text('Extract'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Error explanation with an optional "Open with another app".
Future<void> showArchiveErrorDialog(
  BuildContext context,
  ArcException error, {
  VoidCallback? onOpenElsewhere,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Row(
        children: [
          Icon(
            LucideIcons.circleAlert,
            size: 18,
            color: context.colors.destructive,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(errorTitle(error.kind))),
        ],
      ),
      content: Text(error.message),
      actions: [
        if (onOpenElsewhere != null && error.suggestOtherApp)
          OutlinedButton(
            onPressed: () {
              Navigator.pop(context);
              onOpenElsewhere();
            },
            child: const Text('Open with another app'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Lists entries that couldn't be extracted.
Future<void> showFailuresDialog(
  BuildContext context,
  List<(String, String)> failures,
) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return AlertDialog(
        title: Text(
          failures.length == 1
              ? '1 item couldn\'t be extracted'
              : '${failures.length} items couldn\'t be extracted',
        ),
        content: SizedBox(
          width: 440,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: failures.take(50).length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final (path, message) = failures[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: text.bodySmall?.copyWith(
                        color: context.colors.destructive,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}

/// Floating progress card for a running extraction.
class ExtractProgressCard extends StatelessWidget {
  const ExtractProgressCard({
    super.key,
    required this.title,
    required this.progress,
    required this.onCancel,
  });

  final String title;
  final ExtractProgress? progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final pr = progress;
    final seeking = pr?.seeking;
    final current = pr == null || pr.current.isEmpty
        ? 'Preparing…'
        : seeking != null
        ? 'Unpacking earlier data to reach ${p.basename(pr.current)}…'
        : p.basename(pr.current);
    final detail = pr == null
        ? ''
        : seeking != null
        ? '${(seeking * 100).round()}%'
        : pr.totalBytes > 0
        ? '${formatBytes(pr.doneBytes)} of ${formatBytes(pr.totalBytes)}'
        : '${pr.doneFiles} of ${pr.totalFiles} files';
    final fraction = seeking ?? pr?.fraction;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: AppPanel(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: IconBox(LucideIcons.packageOpen, size: 36),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall,
                        ),
                      ),
                      if (fraction != null)
                        Text(
                          '${(fraction * 100).round()}%',
                          style: text.labelMedium?.copyWith(
                            color: colors.foreground,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    current,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: fraction, minHeight: 6),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      detail,
                      style: text.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            ToolButton(
              icon: LucideIcons.x,
              tooltip: 'Cancel',
              onPressed: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}
