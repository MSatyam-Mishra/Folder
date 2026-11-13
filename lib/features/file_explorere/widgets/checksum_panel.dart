import 'dart:io';

import 'package:folders/core/services/checksums.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart' show CodeFont, Tone, ToneColors;
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Checksums in a file's Properties: MD5, SHA-1, SHA-256 and SHA-512,
/// worked out when asked (in the background, with progress), each with
/// Copy; a box to paste one into and compare; and a check against a sums
/// file beside it, such as the `SHA256SUMS.txt` of Folders' own releases.
class ChecksumPanel extends StatefulWidget {
  const ChecksumPanel({super.key, required this.file});

  final File file;

  @override
  State<ChecksumPanel> createState() => _ChecksumPanelState();
}

class _ChecksumPanelState extends State<ChecksumPanel> {
  ChecksumJob? _job;
  double? _progress;
  Map<HashKind, String>? _hashes;
  String? _error;
  final _compare = TextEditingController();
  SumsEntry? _sums;
  bool _checkSums = false;

  @override
  void initState() {
    super.initState();
    _findSums();
  }

  Future<void> _findSums() async {
    final sums = await Checksums.findSums(widget.file.path);
    if (mounted && sums != null) setState(() => _sums = sums);
  }

  @override
  void dispose() {
    _job?.cancel();
    _compare.dispose();
    super.dispose();
  }

  Future<void> _calculate() async {
    if (_job != null || _hashes != null) return;
    final job = ChecksumJob(widget.file.path, onProgress: (f) {
      if (mounted) setState(() => _progress = f);
    });
    setState(() {
      _job = job;
      _progress = 0;
      _error = null;
    });
    try {
      final hashes = await job.result;
      if (mounted) setState(() => _hashes = hashes);
    } on ChecksumCancelled {
      // Stopped, or the sheet closed.
    } catch (e) {
      if (mounted) setState(() => _error = e is FileSystemException ? (e.osError?.message ?? e.message) : '$e');
    } finally {
      if (mounted) setState(() => _job = null);
    }
  }

  void _cancel() {
    _job?.cancel();
    setState(() {
      _job = null;
      _progress = null;
      _checkSums = false;
    });
  }

  void _copy(HashKind kind, String hex) {
    Clipboard.setData(ClipboardData(text: hex));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${kind.label} copied')));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final hashes = _hashes;
    final running = _job != null;
    final pasted = Checksums.parse(_compare.text);
    final sums = _sums;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Checksums', style: text.titleSmall)),
            if (hashes == null && !running)
              OutlinedButton.icon(
                onPressed: _calculate,
                icon: const Icon(LucideIcons.fingerprint, size: 16),
                label: const Text('Calculate'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (running) ...[
          Row(
            children: [
              Expanded(child: LinearProgressIndicator(value: _progress == 0 ? null : _progress)),
              const SizedBox(width: 12),
              Text('${((_progress ?? 0) * 100).round()}%', style: text.bodySmall),
              const SizedBox(width: 4),
              AppIconButton(icon: const Icon(LucideIcons.x, size: 16), tooltip: 'Stop', onPressed: _cancel),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text("Couldn't read it: $_error", style: text.bodySmall?.copyWith(color: colors.destructive)),
          ),
        if (hashes != null)
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              children: [
                for (final kind in HashKind.values)
                  if (hashes[kind] case final hex?) ...[
                    if (kind != HashKind.md5) Divider(height: 1, color: colors.border),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                      child: Row(
                        children: [
                          SizedBox(width: 64, child: Text(kind.label, style: text.bodySmall?.copyWith(fontSize: 13))),
                          Expanded(
                            child: SelectableText(
                              hex,
                              maxLines: kind == HashKind.sha512 ? 3 : 2,
                              style: CodeFont.style(fontSize: 12, color: colors.foreground, height: 1.4),
                            ),
                          ),
                          AppIconButton(
                            icon: const Icon(LucideIcons.copy, size: 16),
                            tooltip: 'Copy ${kind.label}',
                            onPressed: () => _copy(kind, hex),
                          ),
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _compare,
          onChanged: (value) {
            setState(() {});
            if (Checksums.parse(value) != null) _calculate();
          },
          style: CodeFont.style(fontSize: 12, color: colors.foreground),
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Compare',
            hintText: 'Paste a checksum, or a line of a sums file',
            prefixIcon: const Icon(LucideIcons.clipboardPaste, size: 16),
            suffixIcon: _compare.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(LucideIcons.x, size: 16),
                    tooltip: 'Clear',
                    onPressed: () => setState(_compare.clear),
                  ),
          ),
        ),
        if (_compare.text.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: pasted == null
                ? _Verdict(icon: LucideIcons.circleHelp, text: 'Not an MD5, SHA-1, SHA-256 or SHA-512 checksum')
                : hashes == null
                    ? _Verdict(icon: LucideIcons.loader, text: 'Working out the ${pasted.kind.label}…')
                    : hashes[pasted.kind] == pasted.hex
                        ? _Verdict(icon: LucideIcons.circleCheck, text: 'Match (${pasted.kind.label})', good: true)
                        : _Verdict(icon: LucideIcons.circleX, text: 'No match (${pasted.kind.label})', bad: true),
          ),
        if (sums != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(LucideIcons.fileCheck2, size: 16, color: colors.mutedForeground),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${p.basename(sums.sumsPath)} lists this file', style: text.bodySmall),
              ),
              if (!_checkSums)
                TextButton.icon(
                  onPressed: () {
                    setState(() => _checkSums = true);
                    _calculate();
                  },
                  icon: const Icon(LucideIcons.shieldCheck, size: 16),
                  label: const Text('Check'),
                ),
            ],
          ),
          if (_checkSums)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: hashes == null
                  ? _Verdict(icon: LucideIcons.loader, text: 'Working out the ${sums.kind.label}…')
                  : hashes[sums.kind] == sums.hex
                      ? _Verdict(
                          icon: LucideIcons.circleCheck,
                          text: 'Matches ${p.basename(sums.sumsPath)} (${sums.kind.label})',
                          good: true,
                        )
                      : _Verdict(
                          icon: LucideIcons.circleX,
                          text: "Doesn't match ${p.basename(sums.sumsPath)}: the file may be damaged or changed",
                          bad: true,
                        ),
            ),
        ],
      ],
    );
  }
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.icon, required this.text, this.good = false, this.bad = false});

  final IconData icon;
  final String text;
  final bool good;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = bad ? colors.destructive : (good ? context.toneColor(Tone.success) : colors.mutedForeground);
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}
