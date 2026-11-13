import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_registry.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// "Add a place", or editing [place]: the protocol, then the fields it
/// asks for ([RemoteProtocolInfo]), Test connection and Save. Services
/// signed in through the browser show Sign in instead. Returns what was
/// saved, or null.
Future<RemoteConnection?> showPlaceEditor(BuildContext context, {RemoteConnection? place}) async {
  await RemotePlaces.instance.load();
  if (!context.mounted) return null;
  return AppSheet.show<RemoteConnection>(context, child: PlaceEditor(place: place));
}

class PlaceEditor extends StatefulWidget {
  const PlaceEditor({super.key, this.place});

  final RemoteConnection? place;

  @override
  State<PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<PlaceEditor> {
  late RemoteProtocolInfo? _info = widget.place == null
      ? _protocols.firstOrNull
      : RemoteProtocols.of(widget.place!.protocol);
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  final _folder = TextEditingController();
  final _texts = <String, TextEditingController>{};
  final _toggles = <String, bool>{};
  final _choices = <String, String>{};
  bool _showPassword = false;

  /// The private key chosen now (its text), or [_keyRemoved].
  String? _key;
  String? _keyName;
  bool _keyRemoved = false;
  Map<String, String> _saved = const {};

  bool _busy = false;
  String? _result;

  /// "Find on network": what was found so far, and whether it's looking.
  final _found = <RemoteFoundHost>[];
  StreamSubscription<RemoteFoundHost>? _finding;
  bool _resultOk = false;
  RemoteTrustException? _trust;

  static List<RemoteProtocolInfo> get _protocols {
    registerRemoteProtocols();
    return [for (final info in RemoteProtocols.all) if (info.available && info.builtInPlace == null) info];
  }

  bool get _editing => widget.place != null;

  /// Whether passwords only last until Folders closes (no keyring).
  bool get _keptInMemory => switch (RemotePlaces.instance.secretStore) {
        SecureRemoteSecretStore(:final persistent) => !persistent,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    final place = widget.place;
    if (place != null) {
      _name.text = place.name;
      _host.text = place.host;
      _port.text = place.port?.toString() ?? '';
      _user.text = place.username;
      _folder.text = place.rootPath == '/' ? '' : place.rootPath;
      RemotePlaces.instance.secretStore.readAll(place.id).then((saved) {
        if (mounted) setState(() => _saved = saved);
      });
    }
    _loadOptions();
  }

  void _loadOptions() {
    final place = widget.place;
    for (final option in _info?.options ?? const <RemoteOptionField>[]) {
      final value = place?.options[option.key] ?? option.defaultValue;
      switch (option.kind) {
        case RemoteOptionKind.toggle:
          _toggles[option.key] = value == 'true';
        case RemoteOptionKind.text:
          (_texts[option.key] ??= TextEditingController()).text = value;
        case RemoteOptionKind.choice:
          _choices[option.key] = option.choices.containsKey(value) ? value : option.choices.keys.firstOrNull ?? '';
      }
    }
  }

  void _find(RemoteProtocolInfo info) {
    _finding?.cancel();
    setState(_found.clear);
    _finding = info.discover!().listen(
      (host) {
        if (mounted && !_found.any((h) => h.host == host.host && h.port == host.port)) setState(() => _found.add(host));
      },
      onError: (Object _) {},
      onDone: () {
        if (mounted) setState(() => _finding = null);
      },
    );
    setState(() {});
  }

  void _pick(RemoteFoundHost host) => setState(() {
        _host.text = host.host;
        _port.text = host.port == null || host.port == _info?.defaultPort ? '' : '${host.port}';
        if (_name.text.trim().isEmpty) _name.text = host.name;
      });

  @override
  void dispose() {
    _finding?.cancel();
    for (final c in [_name, _host, _port, _user, _password, _passphrase, _folder, ..._texts.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The place as the form says, with [id].
  RemoteConnection _connection(String id) {
    final info = _info!;
    final options = <String, String>{...?widget.place?.options};
    for (final option in info.options) {
      options[option.key] = switch (option.kind) {
        RemoteOptionKind.toggle => '${_toggles[option.key] ?? false}',
        RemoteOptionKind.text => _texts[option.key]?.text.trim() ?? '',
        RemoteOptionKind.choice => _choices[option.key] ?? '',
      };
    }
    final host = _host.text.trim();
    final user = _user.text.trim();
    final typedName = _name.text.trim();
    final folder = _folder.text.trim();
    return RemoteConnection(
      id: id,
      protocol: info.protocol,
      name: typedName.isNotEmpty ? typedName : (host.isEmpty ? info.label : host),
      host: host,
      port: int.tryParse(_port.text.trim()),
      rootPath: RemotePaths.normalize(folder),
      username: user,
      options: options,
    );
  }

  /// The secrets as they'll be once saved: typed ones over saved ones.
  Map<String, String?> _secretChanges() => {
        if (_password.text.isNotEmpty) 'password': _password.text,
        if (_key != null) 'privateKey': _key,
        if (_keyRemoved) 'privateKey': null,
        if (_passphrase.text.isNotEmpty) 'passphrase': _passphrase.text,
        if (_keyRemoved) 'passphrase': null,
      };

  Map<String, String> _allSecrets() {
    final all = {..._saved};
    _secretChanges().forEach((key, value) => value == null ? all.remove(key) : all[key] = value);
    return all;
  }

  /// Shows [message] under the form, and stops being busy.
  void _say(String message, {required bool ok, RemoteTrustException? trust}) => setState(() {
        _busy = false;
        _result = message;
        _resultOk = ok;
        _trust = trust;
      });

  String? _problem() {
    final info = _info;
    if (info == null) return 'Choose what kind of place it is.';
    if (info.needsHost && _host.text.trim().isEmpty) return 'Type the server\'s name or address.';
    final port = _port.text.trim();
    if (port.isNotEmpty && (int.tryParse(port) == null || int.parse(port) <= 0 || int.parse(port) > 65535)) {
      return 'The port is a number from 1 to 65535.';
    }
    return null;
  }

  Future<void> _test() async {
    final problem = _problem();
    if (problem != null) return _say(problem, ok: false);
    setState(() {
      _busy = true;
      _result = null;
      _trust = null;
    });
    final connection = _connection(widget.place?.id ?? 'test');
    final fs = _info!.create(connection, MemoryRemoteSecrets(_allSecrets()));
    String message;
    var ok = false;
    RemoteTrustException? trust;
    try {
      await fs.connect().timeout(const Duration(seconds: 45));
      final items = await fs.list(connection.rootPath);
      ok = true;
      message = 'Connected. ${items.length} ${items.length == 1 ? 'item' : 'items'} in ${connection.rootPath}.';
    } on RemoteTrustException catch (e) {
      trust = e;
      message = e.message;
    } catch (e) {
      message = remoteError(e).message;
    } finally {
      try {
        await fs.close();
      } catch (_) {}
    }
    if (mounted) _say(message, ok: ok, trust: trust);
  }

  Future<void> _save() async {
    final problem = _problem();
    if (problem != null) return _say(problem, ok: false);
    final places = RemotePlaces.instance;
    final connection = _connection(widget.place?.id ?? places.newId());
    await places.save(connection, secrets: _secretChanges());
    // New settings: the next use connects with them.
    await RemotePool.instance.close(connection.id);
    if (mounted) Navigator.pop(context, connection);
  }

  Future<void> _signIn() async {
    final info = _info!;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await info.signIn!(context);
      if (result == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      final places = RemotePlaces.instance;
      final place = widget.place;
      final connection = RemoteConnection(
        id: place?.id ?? places.newId(),
        protocol: info.protocol,
        name: place?.name ?? result.name,
        username: result.username,
        options: result.options,
      );
      // Signed in afresh: the old tokens go.
      if (place != null) await places.secretStore.deleteAll(place.id);
      await places.save(connection, secrets: result.secrets);
      await RemotePool.instance.close(connection.id);
      if (mounted) Navigator.pop(context, connection);
    } catch (e) {
      if (mounted) _say(remoteError(e).message, ok: false);
    }
  }

  Future<void> _renameSignedIn() async {
    final place = widget.place!;
    final name = _name.text.trim();
    if (name.isNotEmpty && name != place.name) await RemotePlaces.instance.rename(place.id, name);
    if (mounted) Navigator.pop(context, RemotePlaces.instance.byId(place.id));
  }

  Future<void> _chooseKey() async {
    final picked = await FilePicker.platform.pickFiles(dialogTitle: 'Choose the private key');
    final path = picked?.files.singleOrNull?.path;
    if (path == null) return;
    String text;
    try {
      text = await File(path).readAsString();
    } catch (_) {
      text = '';
    }
    if (!mounted) return;
    if (!text.contains('PRIVATE KEY')) {
      _say("That file isn't a private key (OpenSSH or PEM).", ok: false);
      return;
    }
    setState(() {
      _key = text;
      _keyName = picked!.files.single.name;
      _keyRemoved = false;
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = context.colors;
    final info = _info;
    final protocols = _protocols;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_editing ? 'Edit place' : 'Add a place', style: text.titleLarge),
        const SizedBox(height: 4),
        Text(
          _editing ? info?.label ?? '' : 'Files on another computer, a NAS or a server.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 16),
        if (!_editing) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in protocols)
                ChoiceChip(
                  key: ValueKey('protocol-${p.protocol.name}'),
                  avatar: Icon(p.icon, size: 16),
                  label: Text(p.label),
                  selected: p.protocol == info?.protocol,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() {
                            _info = p;
                            _result = null;
                            _trust = null;
                            _finding?.cancel();
                            _finding = null;
                            _found.clear();
                            _loadOptions();
                          }),
                ),
            ],
          ),
          if (info?.description != null) ...[
            const SizedBox(height: 8),
            Text(info!.description!, style: text.bodySmall),
          ],
          const SizedBox(height: 16),
        ],
        if (info == null)
          Text('No kind of place can be used in this version.', style: text.bodyMedium)
        else if (info.signIn != null)
          ..._signInFields(info)
        else
          ..._fields(info),
        if (_result != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _resultOk ? LucideIcons.circleCheck : LucideIcons.circleAlert,
                size: 16,
                color: _resultOk ? Colors.green.shade600 : colors.destructive,
              ),
              const SizedBox(width: 8),
              Expanded(child: SelectableText(_result!, style: text.bodySmall)),
            ],
          ),
          if (_trust != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        await _trust!.trust();
                        await _test();
                      },
                icon: const Icon(LucideIcons.shieldCheck, size: 16),
                label: const Text('Trust it and try again'),
              ),
            ),
          ],
        ],
        if (_keptInMemory) ...[
          const SizedBox(height: 8),
          Text(
            "This device has no keyring to keep passwords in: they're kept until Folders closes.",
            style: text.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
        _buttons(info),
      ],
    );
  }

  List<Widget> _signInFields(RemoteProtocolInfo info) => [
        if (_editing) ...[
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name', prefixIcon: Icon(LucideIcons.tag, size: 18)),
          ),
          const SizedBox(height: 12),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('sign-in'),
            onPressed: _busy ? null : _signIn,
            icon: const Icon(LucideIcons.logIn, size: 16),
            label: Text(_editing ? 'Sign in again' : 'Sign in to ${info.label}'),
          ),
        ),
      ];

  List<Widget> _fields(RemoteProtocolInfo info) {
    final hasKey = (_key != null || (_saved['privateKey'] != null && !_keyRemoved));
    const gap = SizedBox(height: 12);
    return [
      if (info.discover != null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('find-on-network'),
            onPressed: _busy ? null : () => _find(info),
            icon: _finding != null
                ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.radar, size: 16),
            label: Text(_finding != null ? 'Looking on this network…' : 'Find on network'),
          ),
        ),
        for (final host in _found)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.server, size: 18),
            title: Text(host.name),
            subtitle: Text(host.port == null ? host.host : '${host.host}:${host.port}'),
            onTap: () => _pick(host),
          ),
        const SizedBox(height: 12),
      ],
      TextField(
        key: const ValueKey('field-host'),
        controller: _host,
        enabled: !_busy,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: 'Server',
          hintText: info.hostHint,
          prefixIcon: const Icon(LucideIcons.server, size: 18),
        ),
      ),
      gap,
      Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              key: const ValueKey('field-user'),
              controller: _user,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'User name', prefixIcon: Icon(LucideIcons.userRound, size: 18)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: TextField(
              key: const ValueKey('field-port'),
              controller: _port,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Port',
                hintText: info.defaultPort == null ? 'Usual' : '${info.defaultPort}',
                prefixIcon: const Icon(LucideIcons.hash, size: 18),
              ),
            ),
          ),
        ],
      ),
      if (info.usesPassword) ...[
        gap,
        TextField(
          key: const ValueKey('field-password'),
          controller: _password,
          enabled: !_busy,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            hintText: _saved['password'] != null ? 'Saved: type to change it' : (info.usesPrivateKey ? 'Or use a key below' : null),
            prefixIcon: const Icon(LucideIcons.lockKeyhole, size: 18),
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide' : 'Show',
              icon: Icon(_showPassword ? LucideIcons.eyeOff : LucideIcons.eye, size: 18),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
      ],
      if (info.usesPrivateKey) ...[
        gap,
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('choose-key'),
                onPressed: _busy ? null : _chooseKey,
                icon: const Icon(LucideIcons.keyRound, size: 16),
                label: Text(
                  _keyName ?? (hasKey ? 'Private key saved: choose another' : 'Private key file…'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (hasKey) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Remove the key',
                icon: const Icon(LucideIcons.x, size: 18),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _key = null;
                          _keyName = null;
                          _keyRemoved = true;
                        }),
              ),
            ],
          ],
        ),
        if (hasKey) ...[
          gap,
          TextField(
            key: const ValueKey('field-passphrase'),
            controller: _passphrase,
            enabled: !_busy,
            obscureText: true,
            decoration: InputDecoration(
              labelText: "Key's passphrase",
              hintText: _saved['passphrase'] != null ? 'Saved: type to change it' : 'If it has one',
              prefixIcon: const Icon(LucideIcons.keySquare, size: 18),
            ),
          ),
        ],
      ],
      gap,
      TextField(
        key: const ValueKey('field-folder'),
        controller: _folder,
        enabled: !_busy,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: 'Folder to open',
          hintText: '/ (the top)',
          prefixIcon: Icon(LucideIcons.folderOpen, size: 18),
        ),
      ),
      for (final option in info.options) ...[gap, _option(option)],
      gap,
      TextField(
        key: const ValueKey('field-name'),
        controller: _name,
        enabled: !_busy,
        decoration: const InputDecoration(
          labelText: 'Name in the sidebar',
          hintText: 'The server, if left empty',
          prefixIcon: Icon(LucideIcons.tag, size: 18),
        ),
      ),
    ];
  }

  Widget _option(RemoteOptionField option) {
    switch (option.kind) {
      case RemoteOptionKind.toggle:
        return SwitchListTile(
          key: ValueKey('option-${option.key}'),
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(LucideIcons.settings2, size: 18),
          title: Text(option.label),
          subtitle: option.description == null ? null : Text(option.description!),
          value: _toggles[option.key] ?? false,
          onChanged: _busy ? null : (on) => setState(() => _toggles[option.key] = on),
        );
      case RemoteOptionKind.text:
        return TextField(
          key: ValueKey('option-${option.key}'),
          controller: _texts[option.key] ??= TextEditingController(text: option.defaultValue),
          enabled: !_busy,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: option.label,
            hintText: option.hint,
            helperText: option.description,
            prefixIcon: const Icon(LucideIcons.settings2, size: 18),
          ),
        );
      case RemoteOptionKind.choice:
        return DropdownButtonFormField<String>(
          key: ValueKey('option-${option.key}'),
          initialValue: _choices[option.key],
          decoration: InputDecoration(
            labelText: option.label,
            helperText: option.description,
            prefixIcon: const Icon(LucideIcons.settings2, size: 18),
          ),
          items: [
            for (final MapEntry(key: value, value: label) in option.choices.entries)
              DropdownMenuItem(value: value, child: Text(label)),
          ],
          onChanged: _busy ? null : (value) => setState(() => _choices[option.key] = value ?? ''),
        );
    }
  }

  Widget _buttons(RemoteProtocolInfo? info) {
    final signIn = info?.signIn != null;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!signIn && info != null)
          OutlinedButton.icon(
            key: const ValueKey('test-connection'),
            onPressed: _busy ? null : _test,
            icon: _busy
                ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.plugZap, size: 16),
            label: const Text('Test connection'),
          ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (!signIn && info != null)
          FilledButton.icon(
            key: const ValueKey('save-place'),
            onPressed: _busy ? null : _save,
            icon: const Icon(LucideIcons.check, size: 16),
            label: const Text('Save'),
          ),
        if (signIn && _editing)
          FilledButton.icon(
            onPressed: _busy ? null : _renameSignedIn,
            icon: const Icon(LucideIcons.check, size: 16),
            label: const Text('Save'),
          ),
      ],
    );
  }
}
