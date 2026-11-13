import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:folders/core/services/remote/cloud/cloud_service.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:url_launcher/url_launcher.dart';

/// Signs in to [service] in the browser while a small dialog waits, with
/// Cancel, Open again and Copy link. Null when the user gave up; throws
/// [RemoteException] when the sign-in failed.
///
/// On Android the page opens in a Custom Tab over the app, so closing it
/// comes back here; elsewhere in the default browser.
Future<RemoteSignIn?> showCloudSignIn(
  BuildContext context,
  CloudService service, {
  IconData icon = LucideIcons.cloud,
  @visibleForTesting CloudSignInFlow? flow,
  @visibleForTesting Future<bool> Function(Uri url)? openBrowser,
}) async {
  final result = await showDialog<_Outcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CloudSignInDialog(
      flow: flow ?? CloudSignInFlow(service),
      icon: icon,
      openBrowser: openBrowser ?? _openBrowser,
    ),
  );
  if (result == null) return null;
  if (result.error case final error?) throw error;
  return result.signIn;
}

Future<bool> _openBrowser(Uri url) async {
  try {
    return await launchUrl(
      url,
      mode: Platform.isAndroid ? LaunchMode.inAppBrowserView : LaunchMode.externalApplication,
    );
  } on PlatformException {
    return false;
  }
}

class _Outcome {
  const _Outcome({this.signIn, this.error});

  final RemoteSignIn? signIn;
  final Object? error;
}

@visibleForTesting
class CloudSignInDialog extends StatefulWidget {
  const CloudSignInDialog({super.key, required this.flow, required this.icon, required this.openBrowser});

  final CloudSignInFlow flow;
  final IconData icon;
  final Future<bool> Function(Uri url) openBrowser;

  @override
  State<CloudSignInDialog> createState() => _CloudSignInDialogState();
}

class _CloudSignInDialogState extends State<CloudSignInDialog> {
  bool _browserFailed = false;
  bool _copied = false;
  bool _closed = false;

  String get _label => widget.flow.service.label;

  @override
  void initState() {
    super.initState();
    unawaited(widget.flow.run(openBrowser: _open).then(
      (signIn) => _close(_Outcome(signIn: signIn)),
      onError: (Object e) => _close(_Outcome(error: e)),
    ));
  }

  Future<bool> _open(Uri url) async {
    final ok = await widget.openBrowser(url);
    if (mounted) setState(() => _browserFailed = !ok);
    return ok;
  }

  void _close(_Outcome outcome) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(outcome);
  }

  void _cancel() {
    widget.flow.cancel();
    _close(const _Outcome());
  }

  Future<void> _copy() async {
    final url = widget.flow.url;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url.toString()));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.flow.url;
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        title: Row(
          children: [
            Icon(widget.icon, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text('Sign in to $_label')),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_browserFailed
                  ? "Couldn't open a browser. Copy the link and open it in one; Folders carries on by itself once "
                      "you've signed in."
                  : 'Finish signing in on the page that opened in your browser. Folders carries on by itself once '
                      "you've signed in."),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              if (_browserFailed && url != null) ...[
                const SizedBox(height: 12),
                SelectableText(url.toString(), maxLines: 3, style: text.bodySmall),
              ],
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: url == null ? null : _copy,
            icon: Icon(_copied ? LucideIcons.check : LucideIcons.copy, size: 16),
            label: Text(_copied ? 'Copied' : 'Copy link'),
          ),
          TextButton.icon(
            onPressed: url == null ? null : () => _open(url),
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('Open again'),
          ),
          TextButton.icon(
            onPressed: _cancel,
            icon: const Icon(LucideIcons.x, size: 16),
            label: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
