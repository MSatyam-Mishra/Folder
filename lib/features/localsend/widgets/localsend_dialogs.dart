import 'dart:async';

import 'package:folder/core/services/localsend/localsend.dart';
import 'package:folder/features/localsend/widgets/localsend_common.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

/// Result of the incoming-transfer dialog.
class LsIncomingAnswer {
  const LsIncomingAnswer({required this.accept, this.trust = false});

  final bool accept;

  /// Accept this device automatically from now on.
  final bool trust;
}

/// Accept/decline dialog. Closes by itself when the sender withdraws.
Future<LsIncomingAnswer> showLsIncomingDialog(
  BuildContext context,
  LsIncomingRequest request, {
  required bool alreadyTrusted,
}) async {
  final navigator = Navigator.of(context);
  var open = true;
  unawaited(
    request.cancelled.then((_) {
      if (open && navigator.mounted) navigator.pop();
    }),
  );
  final result = await showDialog<LsIncomingAnswer>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _IncomingDialog(request: request, alreadyTrusted: alreadyTrusted),
  );
  open = false;
  return result ?? const LsIncomingAnswer(accept: false);
}

class _IncomingDialog extends StatefulWidget {
  const _IncomingDialog({required this.request, required this.alreadyTrusted});

  final LsIncomingRequest request;
  final bool alreadyTrusted;

  @override
  State<_IncomingDialog> createState() => _IncomingDialogState();
}

class _IncomingDialogState extends State<_IncomingDialog> {
  bool _trust = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final sender = r.sender;
    final text = Theme.of(context).textTheme;
    final count = r.files.length;
    final files = List.of(r.files)
      ..sort((a, b) => a.fileName.compareTo(b.fileName));
    return AlertDialog(
      title: Row(
        children: [
          IconBox(lsDeviceIcon(sender.deviceType)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sender.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'wants to send you $count ${count == 1 ? 'file' : 'files'}',
                  style: text.bodySmall?.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                if (sender.deviceModel != null) sender.deviceModel!,
                r.senderIp,
                lsSize(r.totalSize),
              ].join(' · '),
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: context.colors.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final f = files[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          LsFileIcon(f.fileName, size: 28),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              f.fileName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(lsSize(f.size), style: text.bodySmall),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (!widget.alreadyTrusted && sender.fingerprint.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _trust,
                  onChanged: (v) => setState(() => _trust = v ?? false),
                  title: const Text('Always accept from this device'),
                  subtitle: const Text(
                    'Needs "Auto-accept trusted devices" in settings',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () =>
              Navigator.pop(context, const LsIncomingAnswer(accept: false)),
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            LsIncomingAnswer(accept: true, trust: _trust),
          ),
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

/// Asks for the receiver's PIN; null when dismissed.
Future<String?> showLsPinDialog(
  BuildContext context, {
  required String deviceAlias,
  required bool invalid,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _TextPromptDialog(
    title: 'PIN for $deviceAlias',
    label: 'PIN',
    helper: "Set in the receiver's LocalSend settings",
    error: invalid ? 'Wrong PIN, try again' : null,
    action: 'Send',
    icon: LucideIcons.keyRound,
  ),
);

/// Asks for `ip` or `ip:port`.
Future<String?> showLsAddressDialog(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _TextPromptDialog(
    title: 'Add device by IP',
    label: 'IP address',
    hint: '192.168.1.20 or 192.168.1.20:53317',
    helper: "Shown in the other device's LocalSend settings",
    action: 'Add',
    keyboardType: TextInputType.url,
    icon: LucideIcons.network,
  ),
);

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    required this.action,
    this.hint,
    this.helper,
    this.error,
    this.keyboardType,
    this.icon,
  });

  final String title;
  final String label;
  final String action;
  final String? hint;
  final String? helper;
  final String? error;
  final TextInputType? keyboardType;
  final IconData? icon;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: widget.keyboardType,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            helperText: widget.helper,
            errorText: widget.error,
            prefixIcon: widget.icon == null
                ? null
                : Icon(widget.icon, size: 16),
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
