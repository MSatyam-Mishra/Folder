import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/shizuku/shizuku.dart';
import 'package:folders/core/services/remote/shizuku/shizuku_fs.dart';
import 'package:folders/shared/ui/app_sheet.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:url_launcher/url_launcher.dart';

/// Gets Shizuku ready for App folders, step by step in plain words: install
/// it, start it, let Folders use it. The sheet follows along when the user
/// comes back from Shizuku or the store.
abstract final class ShizukuSetup {
  /// True once Folders may use Shizuku, asking and explaining as needed.
  static Future<bool> ensureReady(BuildContext context) async {
    final status = await Shizuku.status();
    if (status.state == ShizukuState.ready) return true;
    if (!context.mounted) return false;
    final ready = await AppSheet.show<bool>(context, child: ShizukuSetupView(initial: status));
    return ready ?? false;
  }

  /// For "Add a place" ([RemoteProtocolInfo.signIn]): the App folders place
  /// once Shizuku is ready, or null.
  static Future<RemoteSignIn?> signIn(BuildContext context) async {
    if (!await ensureReady(context)) return null;
    return const RemoteSignIn(name: ShizukuPlaces.name, secrets: {});
  }
}

/// What to do next, for each [ShizukuState]. Closes itself with true once
/// Shizuku is ready.
class ShizukuSetupView extends StatefulWidget {
  const ShizukuSetupView({super.key, this.initial, @visibleForTesting this.check});

  final ShizukuStatus? initial;

  /// In place of [Shizuku.status], for tests.
  final Future<ShizukuStatus> Function()? check;

  @override
  State<ShizukuSetupView> createState() => _ShizukuSetupViewState();
}

class _ShizukuSetupViewState extends State<ShizukuSetupView> {
  ShizukuStatus? _status;
  bool _asking = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _status = widget.initial;
    // Back from Shizuku, the store or Settings: maybe a step further.
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    if (_status == null) _refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await (widget.check ?? Shizuku.status)();
    if (!mounted) return;
    setState(() => _status = status);
    if (status.state == ShizukuState.ready) Navigator.pop(context, true);
  }

  Future<void> _allow() async {
    setState(() => _asking = true);
    await Shizuku.requestPermission();
    if (!mounted) return;
    setState(() => _asking = false);
    await _refresh();
  }

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _openShizuku() async {
    if (!await Shizuku.openApp() && mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final state = _status?.state;
    final (String step, String help, List<Widget> actions) = switch (state) {
      null => ('Checking Shizuku…', '', <Widget>[]),
      ShizukuState.unsupported => ('App folders need Android', 'Shizuku runs on Android phones and tablets only.', <Widget>[]),
      ShizukuState.notInstalled => (
          'First, install Shizuku',
          'It\'s free, from Google Play or its own site.',
          [
            _action(LucideIcons.download, 'Get Shizuku', () => _open(Shizuku.playStoreUrl), primary: true),
            _action(LucideIcons.externalLink, 'Download it from its site', () => _open(Shizuku.releasesUrl)),
          ],
        ),
      ShizukuState.notRunning => (
          'Start Shizuku',
          'Open Shizuku and start it. On Android 11 and newer it starts with Wireless debugging, with no computer: '
              'turn on Developer options, then follow Shizuku\'s steps to pair. Or start it from a computer with adb. '
              'After the phone restarts, start it again.',
          [
            _action(LucideIcons.play, 'Open Shizuku', _openShizuku, primary: true),
            _action(LucideIcons.bookOpen, 'How to start it', () => _open(Shizuku.setupGuideUrl)),
          ],
        ),
      ShizukuState.tooOld => (
          'Update Shizuku',
          'This Shizuku is too old for Folders. Install the newest one, then come back.',
          [_action(LucideIcons.download, 'Get Shizuku', () => _open(Shizuku.playStoreUrl), primary: true)],
        ),
      ShizukuState.notAllowed => (
          'Let Folders use Shizuku',
          'Shizuku is running. It will ask whether Folders may use it.',
          [_action(LucideIcons.shieldCheck, 'Allow', _asking ? null : _allow, primary: true)],
        ),
      ShizukuState.denied => (
          'Folders was refused',
          'Open Shizuku, go to its list of apps, and turn Folders on.',
          [_action(LucideIcons.play, 'Open Shizuku', _openShizuku, primary: true)],
        ),
      ShizukuState.ready => ('Ready', '', <Widget>[]),
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(LucideIcons.folderLock, size: 20, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(ShizukuPlaces.name, style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Android keeps the files other apps keep in Android/data and Android/obb locked. Shizuku, a free app, '
          'lets Folders open them without rooting the phone.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 16),
        Text(step, style: text.titleSmall),
        if (help.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(help, style: text.bodySmall),
        ],
        const SizedBox(height: 12),
        for (final action in actions) ...[action, const SizedBox(height: 8)],
        if (state != null && state != ShizukuState.unsupported)
          TextButton.icon(
            onPressed: _refresh,
            icon: const Icon(LucideIcons.refreshCw, size: 18),
            label: const Text('Check again'),
          ),
      ],
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onPressed, {bool primary = false}) {
    final child = Text(label);
    return primary
        ? FilledButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: child)
        : OutlinedButton.icon(onPressed: onPressed, icon: Icon(icon, size: 18), label: child);
  }
}

/// Registers App folders, and learns Android's version for
/// [ShizukuPlaces.redirect].
void registerShizuku() {
  RemoteProtocols.register(shizukuProtocolInfo());
  unawaited(ShizukuPlaces.init());
}

/// App folders for [RemoteProtocols]: offered on Android only.
RemoteProtocolInfo shizukuProtocolInfo() => RemoteProtocolInfo(
      protocol: RemoteProtocol.shizuku,
      label: '${ShizukuPlaces.name} (Shizuku)',
      icon: LucideIcons.folderLock,
      create: (connection, _) => ShizukuFileSystem(connection),
      needsHost: false,
      usesPassword: false,
      signIn: ShizukuSetup.signIn,
      isAvailable: () => Platform.isAndroid,
    );
