import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../remote_fs.dart';
import 'smb_client.dart';
import 'smb_connection.dart';
import 'smb_constants.dart';
import 'smb_discovery.dart';
import 'smb_errors.dart';

/// [RemoteFileSystem] over the plain-Dart SMB2/3 client: `/` lists the
/// shares, `/Share/folder/...` is inside them. Reconnects by itself when the
/// server drops an idle connection, and picks a read up where it broke.
class DartSmbFileSystem implements RemoteFileSystem {
  DartSmbFileSystem(this.connection, this.secrets, {SmbOptions? options}) : _baseOptions = options;

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;
  final SmbOptions? _baseOptions;

  SmbClient? _client;
  Future<SmbClient>? _connecting;

  int get port => connection.port ?? 445;

  bool get showHiddenShares => connection.options['showHiddenShares'] == 'true';

  /// The client of the moment, for tests and the facade.
  SmbClient? get client => _client;

  SmbOptions get options {
    final base = _baseOptions ?? const SmbOptions();
    final o = connection.options;
    return SmbOptions(
      dialects: base.dialects,
      requireSigning: base.requireSigning || o['signing'] == 'required',
      requireEncryption: base.requireEncryption || o['encrypt'] == 'true',
      ciphers: base.ciphers,
      signingAlgorithms: base.signingAlgorithms,
      connectTimeout: base.connectTimeout,
      requestTimeout: base.requestTimeout,
      validateNegotiate: base.validateNegotiate,
    );
  }

  /// `DOMAIN\user` in the user name works as well as the domain option.
  (String, String) get _userAndDomain {
    final u = connection.username.trim();
    var domain = (connection.options['domain'] ?? '').trim();
    final slash = u.indexOf(r'\');
    if (slash > 0 && domain.isEmpty) return (u.substring(slash + 1), u.substring(0, slash));
    return (u, domain);
  }

  bool get _isGuest => connection.username.trim().isEmpty;

  RemoteException _map(Object e, [String? share]) =>
      smbError(e, host: connection.host, port: connection.port, share: share, guest: _isGuest || (_client?.isGuest ?? false));

  @override
  Future<void> connect() async {
    _drop();
    final c = await _ensure();
    final (share, _) = _split(connection.rootPath);
    if (share.isNotEmpty) {
      try {
        await c.tree(share);
      } catch (e) {
        throw _map(e, share);
      }
    }
  }

  Future<SmbClient> _ensure() {
    final c = _client;
    if (c != null && !c.isClosed) return Future.value(c);
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<SmbClient> _open() async {
    final host = connection.host.trim();
    if (host.isEmpty) throw const RemoteException(RemoteErrorKind.other, 'There\'s no server address.');
    final password = await secrets.read('password') ?? '';
    final (user, domain) = _userAndDomain;
    try {
      final address = await resolveSmbHost(host);
      final c = await SmbClient.connect(
        host: host,
        address: address,
        port: port,
        user: user,
        password: password,
        domain: domain,
        workstation: _workstation(),
        options: options,
      );
      _client = c;
      return c;
    } catch (e) {
      throw _map(e);
    }
  }

  static String _workstation() {
    try {
      final h = Platform.localHostname.split('.').first.toUpperCase();
      return h.length > 15 ? h.substring(0, 15) : h;
    } catch (_) {
      return '';
    }
  }

  void _drop() {
    final c = _client;
    _client = null;
    c?.connection.destroy();
  }

  /// Runs [op] on a live client, reconnecting once if the connection had
  /// gone (servers drop idle ones).
  Future<T> _run<T>(Future<T> Function(SmbClient c) op, {String? share}) async {
    for (var attempt = 0;; attempt++) {
      final c = await _ensure();
      try {
        return await op(c);
      } catch (e) {
        if (attempt == 0 && smbShouldReconnect(e)) {
          if (e is SmbStatusException && e.status == NtStatus.networkNameDeleted && share != null && !c.isClosed) {
            c.forgetTree(share);
          } else {
            _drop();
          }
          continue;
        }
        throw _map(e, share);
      }
    }
  }

  /// (share, path inside it) of a connection path.
  static (String, String) _split(String path) {
    final parts = RemotePaths.normalize(path).split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return ('', '');
    return (parts.first, parts.skip(1).join('/'));
  }

  RemoteEntry _entry(String folder, SmbFileInfo f) => RemoteEntry(
        path: RemotePaths.join(folder, f.name),
        isDirectory: f.isDirectory,
        size: f.isDirectory ? 0 : f.size,
        modified: f.modified,
      );

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final norm = RemotePaths.normalize(path);
    final (share, rel) = _split(norm);
    if (share.isEmpty) {
      final shares = await _run((c) async {
        try {
          return await c.listShares();
        } on SmbStatusException catch (e) {
          if (e.status == NtStatus.accessDenied) {
            throw const RemoteException(
              RemoteErrorKind.permission,
              'This server doesn\'t list its shares for this account. Type the share\'s name in the path instead, '
              'for example /Public.',
            );
          }
          rethrow;
        }
      });
      return [
        for (final s in shares)
          if (s.isDisk && (showHiddenShares || !s.isSpecial)) RemoteEntry(path: '/${s.name}', isDirectory: true),
      ];
    }
    final items = await _run((c) async => c.list(await c.tree(share), rel), share: share);
    return [for (final f in items) _entry(norm, f)];
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    final norm = RemotePaths.normalize(path);
    final (share, rel) = _split(norm);
    if (share.isEmpty) return const RemoteEntry(path: '/', isDirectory: true);
    final f = await _run((c) async => c.stat(await c.tree(share), rel), share: share);
    return RemoteEntry(path: norm, isDirectory: f.isDirectory, size: f.isDirectory ? 0 : f.size, modified: f.modified);
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) throw const RemoteException(RemoteErrorKind.other, 'That\'s a folder, not a file.');
    var pos = start;
    for (var attempt = 0;; attempt++) {
      SmbClient? c;
      SmbHandle? h;
      try {
        c = await _ensure();
        final tree = await c.tree(share);
        h = await c.create(
          tree,
          rel,
          access: FileAccess.readData | FileAccess.readAttributes | FileAccess.synchronize,
          share: ShareAccess.all,
          options: CreateOptions.nonDirectoryFile,
        );
        final stop = end == null ? h.endOfFile : min(end, h.endOfFile);
        if (pos < stop) {
          await for (final chunk in c.readRange(h, pos, stop)) {
            pos += chunk.length;
            yield chunk;
          }
        }
        return;
      } catch (e) {
        if (e is RemoteException) rethrow;
        // Picks up where it broke, on a fresh connection.
        if (attempt < 2 && smbShouldReconnect(e)) {
          _drop();
          continue;
        }
        throw _map(e, share);
      } finally {
        if (h != null && c != null && !c.isClosed) unawaited(c.closeHandle(h).catchError((_) {}));
      }
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
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Files go inside a share, not next to them.');
    }
    final disposition = overwrite ? CreateDisposition.overwriteIf : CreateDisposition.create;
    const base = FileAccess.writeData |
        FileAccess.appendData |
        FileAccess.readAttributes |
        FileAccess.writeAttributes |
        FileAccess.synchronize;
    // Opening may reconnect (nothing has been read from [data] yet).
    var withDelete = true;
    final (c, h) = await _run((c) async {
      final tree = await c.tree(share);
      SmbHandle h;
      try {
        h = await c.create(tree, rel, access: base | FileAccess.delete, share: ShareAccess.read, disposition: disposition, options: CreateOptions.nonDirectoryFile);
      } on SmbStatusException catch (e) {
        if (e.status != NtStatus.accessDenied) rethrow;
        withDelete = false;
        h = await c.create(tree, rel, access: base, share: ShareAccess.read, disposition: disposition, options: CreateOptions.nonDirectoryFile);
      }
      return (c, h);
    }, share: share);
    try {
      await c.writeStream(h, data, onProgress: onProgress);
      await c.closeHandle(h);
    } catch (e) {
      // Don't leave half a file behind when this write made it.
      if (h.created && withDelete && !c.isClosed) {
        try {
          await c.setInfo(h, FileInfoClass.disposition, Uint8List.fromList(const [1]));
        } catch (_) {}
      }
      try {
        await c.closeHandle(h);
      } catch (_) {}
      throw _map(e, share);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'New shares can only be made on the server itself.');
    }
    await _run((c) async => c.createDirectory(await c.tree(share), rel), share: share);
  }

  @override
  Future<void> delete(String path) async {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Shares can only be removed on the server itself.');
    }
    await _run((c) async {
      final tree = await c.tree(share);
      final info = await c.stat(tree, rel);
      if (info.isDirectory && (info.attributes & FileAttr.reparsePoint) == 0) {
        await _deleteTree(c, tree, rel);
      } else {
        await c.deleteEntry(tree, rel, directory: info.isDirectory);
      }
    }, share: share);
  }

  Future<void> _deleteTree(SmbClient c, SmbTree tree, String rel) async {
    final entries = await c.list(tree, rel);
    final files = entries.where((e) => !e.isDirectory || (e.attributes & FileAttr.reparsePoint) != 0).toList();
    // Several deletes at once: thousands of small files otherwise take ages.
    for (var i = 0; i < files.length; i += 16) {
      await Future.wait([
        for (final f in files.skip(i).take(16)) c.deleteEntry(tree, '$rel/${f.name}', directory: f.isDirectory),
      ]);
    }
    for (final d in entries.where((e) => e.isDirectory && (e.attributes & FileAttr.reparsePoint) == 0)) {
      await _deleteTree(c, tree, '$rel/${d.name}');
    }
    await c.deleteEntry(tree, rel, directory: true);
  }

  @override
  Future<void> rename(String from, String to) async {
    final (s1, r1) = _split(from);
    final (s2, r2) = _split(to);
    if (s1.isEmpty || r1.isEmpty || s2.isEmpty || r2.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Shares can only be renamed on the server itself.');
    }
    if (s1.toLowerCase() != s2.toLowerCase()) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Moving between shares can\'t be done in one step.');
    }
    await _run((c) async => c.rename(await c.tree(s1), r1, r2), share: s1);
  }

  @override
  Future<void> close() async {
    final c = _client;
    _client = null;
    if (c != null) {
      try {
        await c.close();
      } catch (_) {}
    }
  }
}
