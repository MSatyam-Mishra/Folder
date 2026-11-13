import 'dart:async';
import 'dart:io';

import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

import '../remote_fs.dart';
import 'smb_file_system.dart';
import 'windows_smb_file_system.dart';

/// Windows shares (SMB 2 and 3) for the remote-places browser.
///
/// On Windows, at the standard port, Windows' own SMB client is used
/// ([WindowsSmbFileSystem]): it brings Kerberos, the user's own sign-in, DFS,
/// multichannel and native speed. Everywhere else, and on Windows when that
/// route can't be used (another port, Windows already signed in to the same
/// server as someone else, guests blocked by policy, the connection set to
/// require signing or encryption from this side), the plain-Dart client
/// ([DartSmbFileSystem]) does the job.
///
/// Options (in [RemoteConnection.options]): `domain`; `showHiddenShares`
/// (`true` lists `C$` and the like); `encrypt` (`true`: SMB 3 encryption
/// always); `signing` (`required`); `engine` (`dart` or `windows`, to force
/// one of the two on Windows). The password is the secret `password`; an
/// empty user name means a guest (or, through Windows, the Windows sign-in).
class SmbRemoteFileSystem implements RemoteFileSystem {
  SmbRemoteFileSystem(this.connection, this.secrets, {this.windowsAllowed});

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;

  /// For tests: whether the Windows route may be tried (default: on Windows).
  final bool? windowsAllowed;

  RemoteFileSystem? _impl;
  Future<void>? _connecting;

  /// Which client is in use, once connected: `windows` or `dart`.
  String? get engine => switch (_impl) {
        WindowsSmbFileSystem() => 'windows',
        DartSmbFileSystem() => 'dart',
        _ => null,
      };

  bool get _wantsWindows {
    final o = connection.options;
    final engine = o['engine'];
    if (engine == 'dart') return false;
    if (!(windowsAllowed ?? Platform.isWindows)) return false;
    if (connection.port != null && connection.port != 445) return false;
    if (engine == 'windows') return true;
    // Windows can't be told to require encryption or signing per connection.
    return o['encrypt'] != 'true' && o['signing'] != 'required';
  }

  @override
  Future<void> connect() async {
    final old = _impl;
    _impl = null;
    await old?.close();
    if (_wantsWindows) {
      final w = WindowsSmbFileSystem(connection, secrets);
      try {
        await w.connect();
        _impl = w;
        return;
      } on WindowsSmbException catch (e) {
        await w.close();
        final guestRefused = connection.username.trim().isEmpty && e.remote.kind == RemoteErrorKind.auth;
        if (connection.options['engine'] == 'windows' || !(e.worthFallback || guestRefused)) throw e.remote;
      } on RemoteException catch (e) {
        await w.close();
        // With no user name Windows tried the Windows sign-in; a guest may
        // still get in through the plain client.
        final guestRefused = connection.username.trim().isEmpty &&
            (e.kind == RemoteErrorKind.auth || e.kind == RemoteErrorKind.permission);
        if (connection.options['engine'] == 'windows' || !guestRefused) rethrow;
      }
    }
    final d = DartSmbFileSystem(connection, secrets);
    await d.connect();
    _impl = d;
  }

  Future<RemoteFileSystem> _ready() async {
    final impl = _impl;
    if (impl != null) return impl;
    await (_connecting ??= connect().whenComplete(() => _connecting = null));
    return _impl!;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async => (await _ready()).list(path);

  @override
  Future<RemoteEntry> stat(String path) async => (await _ready()).stat(path);

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    yield* (await _ready()).openRead(path, start: start, end: end);
  }

  @override
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  }) async =>
      (await _ready()).write(path, data, length: length, overwrite: overwrite, onProgress: onProgress);

  @override
  Future<void> createDirectory(String path) async => (await _ready()).createDirectory(path);

  @override
  Future<void> delete(String path) async => (await _ready()).delete(path);

  @override
  Future<void> rename(String from, String to) async => (await _ready()).rename(from, to);

  @override
  Future<void> close() async {
    final impl = _impl;
    _impl = null;
    await impl?.close();
  }
}

/// What "Add a place" shows for Windows shares.
final RemoteProtocolInfo smbProtocolInfo = RemoteProtocolInfo(
  protocol: RemoteProtocol.smb,
  label: 'Windows share (SMB)',
  icon: LucideIcons.server,
  defaultPort: 445,
  usesPassword: true,
  create: (connection, secrets) => SmbRemoteFileSystem(connection, secrets),
);
