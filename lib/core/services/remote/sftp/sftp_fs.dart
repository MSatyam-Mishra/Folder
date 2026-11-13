import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:folders/core/services/remote/known_hosts.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_pool.dart' show remoteError;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// "SFTP" in "Add a place": files over SSH, with a password or a private
/// key (and its passphrase).
final sftpProtocol = RemoteProtocolInfo(
  protocol: RemoteProtocol.sftp,
  label: 'SFTP (SSH)',
  description: 'Linux and Mac computers, servers, many NAS',
  icon: LucideIcons.squareTerminal,
  defaultPort: 22,
  usesPrivateKey: true,
  hostHint: 'server.local or 192.168.1.5',
  create: (connection, secrets) => SftpFileSystem(connection, secrets),
);

/// [RemoteFileSystem] over SFTP (dartssh2). The server's host key is
/// trusted on first use and kept ([RemoteKnownHosts]); if it changes, the
/// connection stops with a [RemoteTrustException].
class SftpFileSystem implements RemoteFileSystem {
  SftpFileSystem(this.connection, this.secrets, {RemoteKnownHosts? knownHosts})
      : knownHosts = knownHosts ?? RemoteKnownHosts.instance;

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;
  final RemoteKnownHosts knownHosts;

  SSHClient? _client;
  SftpClient? _sftp;

  int get _port => connection.port ?? 22;

  String get _hostKey => RemoteKnownHosts.keyFor('sftp', connection.host, _port);

  SftpClient get _open {
    final sftp = _sftp;
    final client = _client;
    if (sftp == null || client == null || client.isClosed) {
      throw const RemoteException(RemoteErrorKind.network, 'The connection to the server closed.');
    }
    return sftp;
  }

  @override
  Future<void> connect() async {
    await close();
    final password = await secrets.read('password');
    final key = await secrets.read('privateKey');
    final passphrase = await secrets.read('passphrase');
    List<SSHKeyPair>? identities;
    if (key != null && key.trim().isNotEmpty) {
      identities = await _keys(key, passphrase == null || passphrase.isEmpty ? null : passphrase);
    }
    if ((password == null || password.isEmpty) && identities == null) {
      throw const RemoteException(RemoteErrorKind.auth, 'Give a password or a private key.');
    }

    String? offered;
    var changed = false;
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(connection.host, _port, timeout: const Duration(seconds: 15));
    } catch (e) {
      throw remoteError(e);
    }
    final client = SSHClient(
      socket,
      username: connection.username,
      identities: identities,
      onPasswordRequest: password == null || password.isEmpty ? null : () => password,
      onVerifyHostKey: (type, fingerprint) async {
        final text = '$type ${utf8.decode(fingerprint, allowMalformed: true)}';
        offered = text;
        final ok = await knownHosts.check(_hostKey, text);
        changed = !ok;
        return ok;
      },
    );
    _client = client;
    try {
      await client.authenticated.timeout(const Duration(seconds: 30));
      _sftp = await client.sftp();
    } catch (e) {
      client.close();
      _client = null;
      if (changed && offered != null) {
        final fingerprint = offered!;
        throw RemoteTrustException(
          "The server's identity (its host key) changed since last time. If you "
          "didn't change or reinstall the server, someone may be listening in.\n\n$fingerprint",
          fingerprint: fingerprint,
          trust: () => knownHosts.remember(_hostKey, fingerprint),
        );
      }
      throw _error(e);
    }
  }

  /// Keys read before, by their text and passphrase: opening an encrypted
  /// key takes seconds (bcrypt), so it's done once per run, off the UI.
  static final _keyCache = <String, List<SSHKeyPair>>{};

  static Future<List<SSHKeyPair>> _keys(String pem, String? passphrase) async {
    final cacheKey = '${pem.hashCode}:${passphrase.hashCode}:${pem.length}';
    final cached = _keyCache[cacheKey];
    if (cached != null) return cached;
    final (keys, error) = await Isolate.run(() => _decode(pem, passphrase));
    if (error != null) throw RemoteException(RemoteErrorKind.auth, error);
    return _keyCache[cacheKey] = keys!;
  }

  static (List<SSHKeyPair>?, String?) _decode(String pem, String? passphrase) {
    try {
      if (passphrase == null && SSHKeyPair.isEncryptedPem(pem)) return (null, 'The private key needs its passphrase.');
      return (SSHKeyPair.fromPem(pem, passphrase), null);
    } on SSHKeyDecryptError {
      return (null, "The private key's passphrase is wrong.");
    } catch (e) {
      return (null, "The private key couldn't be read: ${_plain(e)}");
    }
  }

  RemoteEntry _entry(String path, SftpFileAttrs attrs, {bool? isDirectory}) => RemoteEntry(
        path: path,
        isDirectory: isDirectory ?? attrs.isDirectory,
        size: (isDirectory ?? attrs.isDirectory) ? 0 : attrs.size ?? 0,
        modified: attrs.modifyTime == null ? null : DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000),
      );

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final sftp = _open;
    final folder = RemotePaths.normalize(path);
    try {
      final names = await sftp.listdir(folder);
      final entries = <RemoteEntry>[];
      for (final name in names) {
        if (name.filename == '.' || name.filename == '..') continue;
        final child = RemotePaths.join(folder, name.filename);
        var attrs = name.attr;
        if (attrs.isSymbolicLink) {
          // Where it leads decides: a folder or a file.
          try {
            attrs = await sftp.stat(child);
          } catch (_) {}
        }
        entries.add(_entry(child, attrs));
      }
      return entries;
    } catch (e) {
      throw _error(e, path: folder);
    }
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    final normal = RemotePaths.normalize(path);
    try {
      return _entry(normal, await _open.stat(normal));
    } catch (e) {
      throw _error(e, path: normal);
    }
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    final normal = RemotePaths.normalize(path);
    final SftpFile file;
    try {
      file = await _open.open(normal, mode: SftpFileOpenMode.read);
    } catch (e) {
      throw _error(e, path: normal);
    }
    try {
      if (end != null && end <= start) return;
      yield* file.read(offset: start, length: end == null ? null : end - start).handleError((Object e) => throw _error(e, path: normal));
    } finally {
      unawaited(file.close().catchError((_) {}));
    }
  }

  @override
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  }) async {
    final normal = RemotePaths.normalize(path);
    final sftp = _open;
    if (!overwrite && await _exists(normal)) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(normal)}" is already there');
    }
    final SftpFile file;
    try {
      file = await sftp.open(
        normal,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            (overwrite ? SftpFileOpenMode.truncate : SftpFileOpenMode.exclusive),
      );
    } catch (e) {
      throw _error(e, path: normal);
    }
    try {
      await file.write(
        data.map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
        onProgress: onProgress,
      );
    } catch (e) {
      throw _error(e, path: normal);
    } finally {
      await file.close().catchError((_) {});
    }
  }

  Future<bool> _exists(String path) async {
    try {
      await _open.stat(path);
      return true;
    } on SftpStatusError catch (e) {
      if (e.code == SftpStatusCode.noSuchFile) return false;
      throw _error(e, path: path);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    final normal = RemotePaths.normalize(path);
    try {
      await _open.mkdir(normal);
    } catch (e) {
      if (await _exists(normal)) {
        throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(normal)}" is already there');
      }
      throw _error(e, path: normal);
    }
  }

  @override
  Future<void> delete(String path) async {
    final normal = RemotePaths.normalize(path);
    final sftp = _open;
    try {
      final attrs = await sftp.stat(normal, followLink: false);
      if (attrs.isDirectory) {
        for (final name in await sftp.listdir(normal)) {
          if (name.filename == '.' || name.filename == '..') continue;
          await delete(RemotePaths.join(normal, name.filename));
        }
        await sftp.rmdir(normal);
      } else {
        await sftp.remove(normal);
      }
    } catch (e) {
      throw _error(e, path: normal);
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = RemotePaths.normalize(from);
    final target = RemotePaths.normalize(to);
    // Changing only the case is a rename, even where names ignore it.
    if (source.toLowerCase() != target.toLowerCase() && await _exists(target)) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(target)}" is already there');
    }
    try {
      await _open.rename(source, target);
    } catch (e) {
      throw _error(e, path: source);
    }
  }

  @override
  Future<void> close() async {
    final sftp = _sftp;
    final client = _client;
    _sftp = null;
    _client = null;
    try {
      await sftp?.close();
    } catch (_) {}
    client?.close();
  }

  static String _plain(Object e) => e is SSHMessageError ? e.message : '$e';

  RemoteException _error(Object e, {String? path}) {
    if (e is RemoteException) return e;
    final name = path == null ? '' : RemotePaths.nameOf(path);
    if (e is SftpStatusError) {
      return switch (e.code) {
        SftpStatusCode.noSuchFile => RemoteException(RemoteErrorKind.notFound, '"$name" isn\'t there any more.'),
        SftpStatusCode.permissionDenied =>
          RemoteException(RemoteErrorKind.permission, 'The server didn\'t allow it${name.isEmpty ? '' : ' for "$name"'}.'),
        SftpStatusCode.opUnsupported => const RemoteException(RemoteErrorKind.unsupported, "The server can't do that."),
        SftpStatusCode.noConnection || SftpStatusCode.connectionLost =>
          const RemoteException(RemoteErrorKind.network, 'The connection to the server dropped.'),
        _ => RemoteException(RemoteErrorKind.other, e.message.isEmpty ? 'The server refused it.' : e.message),
      };
    }
    if (e is SSHAuthError) {
      return const RemoteException(RemoteErrorKind.auth, 'The server refused the user name, password or key.');
    }
    if (e is SSHHostkeyError) {
      return RemoteException(RemoteErrorKind.permission, "The server's identity couldn't be checked: ${e.message}");
    }
    if (e is SSHSocketError || e is SSHStateError || e is SSHDisconnectError || e is SSHHandshakeError) {
      return RemoteException(RemoteErrorKind.network, 'The connection to the server failed: ${_plain(e)}');
    }
    if (e is StateError) {
      return const RemoteException(RemoteErrorKind.network, 'The connection to the server closed.');
    }
    if (e is SocketException || e is TimeoutException) return remoteError(e);
    return RemoteException(RemoteErrorKind.other, _plain(e));
  }
}
