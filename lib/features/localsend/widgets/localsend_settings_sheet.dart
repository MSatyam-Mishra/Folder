import 'package:folders/core/services/localsend/localsend.dart';
import 'package:folders/core/services/localsend/localsend_platform.dart';
import 'package:folders/features/localsend/localsend_controller.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> showLsSettingsSheet(
  BuildContext context,
  LocalSendController controller,
) {
  final settings = controller.settings;
  if (settings == null) return Future.value();
  return AppSheet.show<void>(
    context,
    style: SheetStyle.side,
    maxHeightFraction: 0.86,
    child: _SettingsSheet(controller: controller, initial: settings),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.controller, required this.initial});

  final LocalSendController controller;
  final LsSettings initial;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final _alias = TextEditingController(text: widget.initial.alias);
  late final _port = TextEditingController(text: '${widget.initial.port}');
  late final _pin = TextEditingController(text: widget.initial.pin ?? '');
  late bool _https = widget.initial.https;
  late bool _autoAccept = widget.initial.autoAcceptTrusted;
  late bool _checksums = widget.initial.sendChecksums;
  late String _destination = widget.initial.destination;
  String? _portError;
  String? _destinationError;
  bool _saving = false;

  @override
  void dispose() {
    _alias.dispose();
    _port.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _pickDestination() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final ok = await LsSettingsStore.isWritable(path);
    setState(() {
      _destination = path;
      _destinationError = ok ? null : 'This folder is not writable';
    });
  }

  Future<void> _resetDestination() async {
    final (dir, _) = await LsSettingsStore.defaultDestination();
    setState(() {
      _destination = dir;
      _destinationError = null;
    });
  }

  Future<void> _save() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _portError = 'Use a port between 1024 and 65535');
      return;
    }
    if (_destinationError != null) return;
    setState(() => _saving = true);
    final alias = _alias.text.trim().isEmpty
        ? lsRandomAlias()
        : _alias.text.trim();
    final pin = _pin.text.trim();
    final next = widget.initial.copyWith(
      alias: alias,
      port: port,
      https: _https,
      pin: pin.isEmpty ? null : pin,
      clearPin: pin.isEmpty,
      autoAcceptTrusted: _autoAccept,
      destination: _destination,
      sendChecksums: _checksums,
    );
    await widget.controller.applySettings(next);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final trustedCount = widget.controller.trusted.length;
    // The sheet scrolls and handles the keyboard inset.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Nearby share settings', style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          'How this device appears to others and where files go.',
          style: text.bodySmall,
        ),
        const SectionLabel('Identity'),
        TextField(
          controller: _alias,
          decoration: InputDecoration(
            labelText: 'Device name',
            helperText: 'How other devices see this one',
            suffixIcon: IconButton(
              icon: const Icon(LucideIcons.dices, size: 18),
              tooltip: 'Random name',
              onPressed: () => _alias.text = lsRandomAlias(),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pin,
          decoration: const InputDecoration(
            labelText: 'Receive PIN (optional)',
            helperText: 'Senders must enter it before sending to you',
            prefixIcon: Icon(LucideIcons.keyRound, size: 16),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _port,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Port',
            helperText:
                'Default ${LsConst.defaultPort}. Other devices scan the default port.',
            errorText: _portError,
          ),
        ),
        const SectionLabel('Security'),
        SurfaceCard(
          padding: EdgeInsets.zero,
          clip: true,
          child: Column(
            children: [
              SwitchListTile(
                value: _https,
                onChanged: (v) => setState(() => _https = v),
                title: const Text('Encryption (HTTPS)'),
                subtitle: const Text(
                  'Turn off only for devices that use LocalSend without encryption',
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: _autoAccept,
                onChanged: (v) => setState(() => _autoAccept = v),
                title: const Text('Auto-accept trusted devices'),
                subtitle: Text(
                  trustedCount == 0
                      ? 'Mark a device as trusted when accepting its transfer'
                      : '$trustedCount trusted ${trustedCount == 1 ? 'device' : 'devices'}',
                ),
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: _checksums,
                onChanged: (v) => setState(() => _checksums = v),
                title: const Text('Send checksums'),
                subtitle: const Text(
                  'Receiver verifies each file (SHA-256); large files take longer to start',
                ),
              ),
            ],
          ),
        ),
        if (trustedCount > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: colors.destructive,
                ),
                onPressed: () async {
                  await widget.controller.forgetTrusted();
                  if (mounted) setState(() {});
                },
                icon: const Icon(LucideIcons.shieldOff, size: 16),
                label: const Text('Forget trusted devices'),
              ),
            ),
          ),
        const SectionLabel('Save received files to'),
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const IconBox(LucideIcons.folderDown, size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _destinationError ?? _destination,
                      style: text.bodyMedium?.copyWith(
                        color: _destinationError == null
                            ? null
                            : colors.destructive,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _pickDestination,
                    child: const Text('Change folder'),
                  ),
                  TextButton(
                    onPressed: _resetDestination,
                    child: const Text('Use default'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (widget.controller.fingerprint != null) ...[
          const SizedBox(height: 16),
          Text('Fingerprint', style: text.labelMedium),
          const SizedBox(height: 4),
          SelectableText(
            widget.controller.fingerprint!,
            style: CodeFont.style(
              fontSize: 12,
              color: colors.mutedForeground,
              height: 1.4,
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
