import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:folders/core/services/file_server/app_file_server_resources.dart';
import 'package:folders/core/services/file_server/ftp_file_server.dart';
import 'package:folders/core/services/file_server/http_file_server.dart';
import 'package:folders/core/services/incoming_files.dart';
import 'package:folders/core/services/localsend/localsend_platform.dart';
import 'package:folders/core/services/task_notifications.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:folders/shared/widgets/round_qr_code.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

enum ShareProtocol { http, ftp }

/// Shares a folder over Wi-Fi: as a web page (HTTP) or over FTP.
///
/// Sharing runs while this screen is open, also with the app in the background:
/// a notification says so, leads back here and can stop it. Pops with `true`
/// when files were added from another device, so the caller can refresh its
/// folder.
class FileServerScreen extends StatefulWidget {
  const FileServerScreen({
    super.key,
    required this.initialFolder,
    this.protocol = ShareProtocol.http,
    this.only,
    this.startNow = false,
  });

  final String initialFolder;
  final ShareProtocol protocol;

  /// Share just these items of [initialFolder] (read-only), not all of it.
  final List<String>? only;

  /// Start sharing right away (chosen from a Share menu).
  final bool startNow;

  /// Goes back to the screen that's sharing; false when none is.
  static bool showRunning() {
    final state = _FileServerScreenState._sharing;
    if (state == null || !state.mounted) return false;
    final route = ModalRoute.of(state.context);
    if (route != null) Navigator.of(state.context).popUntil((other) => other == route);
    return true;
  }

  @override
  State<FileServerScreen> createState() => _FileServerScreenState();
}

class _FileServerScreenState extends State<FileServerScreen> {
  static _FileServerScreenState? _sharing;

  late ShareProtocol _protocol = widget.protocol;
  late String _folder = widget.initialFolder;
  bool _allowChanges = false;
  bool _requirePassword = true;
  final String _username = 'explorer';
  String _password = _newPassword();

  HttpFileServer? _http;
  FtpFileServer? _ftp;
  bool _starting = false;
  String? _error;
  final _received = <String>[];
  StreamSubscription<String>? _receivedSub;

  bool get _running => _http != null || _ftp != null;

  @override
  void initState() {
    super.initState();
    if (widget.startNow) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  List<String> get _urls => _http?.urls ?? _ftp?.urls ?? const [];

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  static String _newPassword() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(6, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      if (_protocol == ShareProtocol.http) {
        final settings = context.read<ThemeCubit>().state;
        final server = HttpFileServer(
          resources: AppFileServerResources(iconStyle: settings.fileIconStyle),
        );
        await server.start(
          _folder,
          theme: webThemeFor(settings.colorTheme),
          deviceName: await LsSettingsStore.deviceModel(),
          allowUploads: _allowChanges,
          only: widget.only,
        );
        _receivedSub = server.received.listen(_onReceived);
        _http = server;
      } else {
        final server = FtpFileServer();
        await server.start(
          _folder,
          allowChanges: _allowChanges,
          username: _requirePassword ? _username : null,
          password: _requirePassword ? _password : null,
          only: widget.only,
        );
        _receivedSub = server.received.listen(_onReceived);
        _ftp = server;
      }
      await DeviceFiles.keepAwake(true);
      _sharing = this;
      _showNotification();
    } catch (e) {
      _error = "Couldn't start sharing: $e";
    }
    if (mounted) setState(() => _starting = false);
  }

  void _onReceived(String path) {
    DeviceFiles.invalidate();
    if (mounted) setState(() => _received.add(p.basename(path)));
    _showNotification();
  }

  void _showNotification() {
    TaskNotifications.instance.show(
      TaskNotifications.sharingId,
      title: _protocol == ShareProtocol.ftp ? 'Sharing over FTP' : 'Sharing in the browser',
      name: _urls.firstOrNull ?? '',
      detail: _received.isEmpty ? _folderLabel : '${_received.length} received',
      bar: false,
      icon: 'share',
      route: IncomingRoute.fileServer,
      action: 'Stop',
      onAction: () {
        if (mounted) setState(_stop);
      },
    );
  }

  void _stop() {
    _receivedSub?.cancel();
    _receivedSub = null;
    _http?.stop();
    _ftp?.stop();
    _http = null;
    _ftp = null;
    DeviceFiles.keepAwake(false);
    if (_sharing == this) {
      _sharing = null;
      TaskNotifications.instance.cancel(TaskNotifications.sharingId);
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Folder to share',
      initialDirectory: _folder,
    );
    if (path != null && mounted) setState(() => _folder = path);
  }

  void _setAllowChanges(bool value) {
    setState(() => _allowChanges = value);
    _http?.allowUploads = value;
    _ftp?.allowChanges = value;
  }

  void _setRequirePassword(bool value) {
    setState(() => _requirePassword = value);
    _ftp
      ?..username = value ? _username : null
      ..password = value ? _password : null;
  }

  void _regeneratePassword() {
    setState(() => _password = _newPassword());
    if (_requirePassword) _ftp?.password = _password;
  }

  void _copy(String value, String what) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Future<void> _confirmLeave() async {
    final colors = context.colors;
    final stop = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop sharing?'),
        content: const Text('Other devices will lose access to the folder.'),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep sharing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (stop == true && mounted) {
      setState(_stop);
      Navigator.pop(context, _received.isNotEmpty);
    }
  }

  String get _folderLabel {
    final only = widget.only;
    if (only != null) return only.length == 1 ? p.basename(only.single) : '${only.length} items';
    if (Platform.isAndroid && _folder == ExplorerPaths.androidInternalStorage) {
      return 'Internal storage';
    }
    final name = p.basename(_folder);
    return name.isEmpty ? _folder : name;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final top = AppTopBarScaffold.contentTopInset(context);
    final running = _running;
    final ftp = _protocol == ShareProtocol.ftp;

    return PopScope(
      canPop: !running,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: ExplorerScaffold(
        title: 'Wi-Fi sharing',
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                top + 16,
                16,
                MediaQuery.paddingOf(context).bottom + 24,
              ),
              children: [
                Text(
                  widget.only == null
                      ? 'Share a folder with computers and phones on the same Wi-Fi.'
                      : 'Share ${widget.only!.length == 1 ? 'it' : 'them'} with computers and '
                          'phones on the same Wi-Fi. Nothing else in the folder can be opened.',
                  style: text.bodyMedium?.copyWith(
                    color: context.colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<ShareProtocol>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: ShareProtocol.http,
                      icon: Icon(LucideIcons.globe, size: 16),
                      label: Text('Browser'),
                    ),
                    ButtonSegment(
                      value: ShareProtocol.ftp,
                      icon: Icon(LucideIcons.server, size: 16),
                      label: Text('FTP'),
                    ),
                  ],
                  selected: {_protocol},
                  onSelectionChanged: running
                      ? null
                      : (s) => setState(() => _protocol = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  ftp
                      ? 'For File Explorer on Windows, Finder on a Mac, '
                            'FileZilla and other FTP apps.'
                      : 'Open the address in any web browser. Nothing to '
                            'install.',
                  style: text.bodySmall,
                ),
                const SizedBox(height: 16),
                _FolderCard(
                  label: _folderLabel,
                  path: _folder,
                  onChange: running || widget.only != null ? null : _pickFolder,
                ),
                if (running) ...[
                  const SizedBox(height: 16),
                  _StatusPanel(
                    protocol: _protocol,
                    urls: _urls,
                    ftp: _ftp,
                    username: _requirePassword ? _username : null,
                    password: _requirePassword ? _password : null,
                    received: _received,
                    onCopy: _copy,
                    onStop: () => setState(_stop),
                  ),
                ],
                const SizedBox(height: 8),
                if (widget.only == null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowChanges,
                  onChanged: _setAllowChanges,
                  title: Text(ftp ? 'Allow changes' : 'Allow uploads'),
                  subtitle: Text(
                    ftp
                        ? 'Other devices can upload, rename and delete files '
                              'in this folder.'
                        : 'Anyone with the address can add files to this '
                              'folder.',
                  ),
                ),
                if (ftp) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _requirePassword,
                    onChanged: _setRequirePassword,
                    title: const Text('Require a password'),
                    subtitle: const Text(
                      'Without one, anyone on this network can sign in.',
                    ),
                  ),
                  if (_requirePassword)
                    _Credentials(
                      username: _username,
                      password: _password,
                      onCopy: _copy,
                      onRegenerate: _regeneratePassword,
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: text.bodySmall?.copyWith(
                      color: context.colors.destructive,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (!running)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                    ),
                    onPressed: _starting ? null : _start,
                    icon: _starting
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.wifi, size: 18),
                    label: const Text('Start sharing'),
                  ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      LucideIcons.info,
                      size: 14,
                      color: context.colors.mutedForeground,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'The screen stays on while sharing. Sharing stops '
                        'when you leave this screen.',
                        style: text.bodySmall,
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

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.label,
    required this.path,
    required this.onChange,
  });

  final String label;
  final String path;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AppPanel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Row(
        children: [
          const FolderIcon(size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onChange, child: const Text('Change')),
        ],
      ),
    );
  }
}

class _Credentials extends StatelessWidget {
  const _Credentials({
    required this.username,
    required this.password,
    required this.onCopy,
    required this.onRegenerate,
  });

  final String username;
  final String password;
  final void Function(String value, String what) onCopy;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Column(
        children: [
          _CredentialRow(
            label: 'User',
            value: username,
            trailing: AppIconButton(
              icon: const Icon(LucideIcons.copy, size: 16),
              tooltip: 'Copy user name',
              onPressed: () => onCopy(username, 'User name'),
            ),
          ),
          Divider(height: 1, color: context.colors.border),
          _CredentialRow(
            label: 'Password',
            value: password,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIconButton(
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  tooltip: 'New password',
                  onPressed: onRegenerate,
                ),
                AppIconButton(
                  icon: const Icon(LucideIcons.copy, size: 16),
                  tooltip: 'Copy password',
                  onPressed: () => onCopy(password, 'Password'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  const _CredentialRow({
    required this.label,
    required this.value,
    required this.trailing,
  });

  final String label;
  final String value;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(label, style: text.bodySmall)),
          Expanded(
            child: Text(
              value,
              style: text.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.protocol,
    required this.urls,
    required this.ftp,
    required this.username,
    required this.password,
    required this.received,
    required this.onCopy,
    required this.onStop,
  });

  final ShareProtocol protocol;
  final List<String> urls;
  final FtpFileServer? ftp;
  final String? username;
  final String? password;
  final List<String> received;
  final void Function(String value, String what) onCopy;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final url = urls.isEmpty ? '' : urls.first;
    final isFtp = protocol == ShareProtocol.ftp;

    return AppPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF22C55E),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isFtp ? 'Sharing over FTP' : 'Sharing in the browser',
                style: text.titleSmall,
              ),
              const Spacer(),
              if (ftp != null)
                ValueListenableBuilder<int>(
                  valueListenable: ftp!.clients,
                  builder: (context, count, _) => Text(
                    count == 1 ? '1 connected' : '$count connected',
                    style: text.bodySmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Container(
              // A quiet margin around the code helps scanners.
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.border),
              ),
              child: RoundQrCode(
                data: url,
                size: 168,
                semanticsLabel: 'QR code for $url',
              ),
            ),
          ),
          const SizedBox(height: 16),
          _AddressField(url: url, onCopy: () => onCopy(url, 'Address')),
          if (urls.length > 1) ...[
            const SizedBox(height: 6),
            Text('Also at ${urls.skip(1).join(', ')}', style: text.bodySmall),
          ],
          if (isFtp && username != null && password != null) ...[
            const SizedBox(height: 8),
            Text(
              'Sign in as $username with password $password.',
              style: text.bodySmall?.copyWith(color: colors.foreground),
            ),
          ],
          const SizedBox(height: 12),
          for (final tip
              in isFtp
                  ? const [
                      'Windows: type the address in File Explorer\'s address bar.',
                      'Mac: in Finder choose Go → Connect to Server (read only).',
                      'Or use FileZilla, WinSCP or an FTP app.',
                    ]
                  : const [
                      'Open the address in any browser, or scan the code.',
                    ])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.mutedForeground,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(child: Text(tip, style: text.bodySmall)),
                ],
              ),
            ),
          if (received.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: colors.muted,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.circleCheck,
                    size: 18,
                    color: colors.foreground,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      received.length == 1
                          ? 'Received ${received.single}'
                          : 'Received ${received.length} files, latest '
                                '${received.last}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              backgroundColor: colors.destructive,
              foregroundColor: colors.destructiveForeground,
            ),
            onPressed: onStop,
            icon: const Icon(LucideIcons.circleStop, size: 18),
            label: const Text('Stop sharing'),
          ),
        ],
      ),
    );
  }
}

class _AddressField extends StatelessWidget {
  const _AddressField({required this.url, required this.onCopy});

  final String url;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: colors.input),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onCopy,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(LucideIcons.link, size: 16, color: colors.mutedForeground),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    url,
                    maxLines: 1,
                    style: TextStyle(
                      color: colors.foreground,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AppIconButton(
                icon: const Icon(LucideIcons.copy, size: 18),
                tooltip: 'Copy address',
                onPressed: onCopy,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
