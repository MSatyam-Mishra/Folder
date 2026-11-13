import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

/// An in-memory server for network places tests: folders and files, a
/// password, and ways to make it fail.
class FakeRemoteServer {
  final Map<String, Uint8List> files = {};
  final Map<String, DateTime> modified = {};
  final Set<String> folders = {'/'};
  String password = 'secret';

  /// Every connect, and every connection open now.
  int connects = 0;
  int open = 0;

  /// Connecting fails as if the host were off.
  bool down = false;

  /// The next call on a connection fails as if the line dropped (once).
  bool dropNext = false;

  /// The next write fails so, part way (once).
  bool dropNextWrite = false;

  /// Reads come in chunks this big, so cancelling part way can be tried.
  int chunkSize = 4;

  /// Called before each chunk is read (a test may cancel meanwhile).
  Future<void> Function()? beforeChunk;

  void addFolder(String path) {
    var p = RemotePaths.normalize(path);
    while (p != '/') {
      folders.add(p);
      p = RemotePaths.parentOf(p);
    }
  }

  void addFile(String path, String text, {DateTime? at}) {
    final p = RemotePaths.normalize(path);
    addFolder(RemotePaths.parentOf(p));
    files[p] = Uint8List.fromList(utf8.encode(text));
    modified[p] = at ?? DateTime(2026, 1, 2, 3, 4);
  }

  String? text(String path) {
    final bytes = files[RemotePaths.normalize(path)];
    return bytes == null ? null : utf8.decode(bytes);
  }

  bool exists(String path) {
    final p = RemotePaths.normalize(path);
    return folders.contains(p) || files.containsKey(p);
  }
}

/// [RemoteFileSystem] on a [FakeRemoteServer].
class FakeRemoteFileSystem implements RemoteFileSystem {
  FakeRemoteFileSystem(this.connection, this.secrets, this.server);

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;
  final FakeRemoteServer server;
  bool _connected = false;

  void _check() {
    if (!_connected) throw const RemoteException(RemoteErrorKind.network, 'Not connected');
    if (server.dropNext) {
      server.dropNext = false;
      _connected = false;
      server.open--;
      throw const RemoteException(RemoteErrorKind.network, 'The connection dropped.');
    }
  }

  @override
  Future<void> connect() async {
    await Future<void>.delayed(Duration.zero);
    if (server.down) throw const RemoteException(RemoteErrorKind.network, "Can't reach the server.");
    if (await secrets.read('password') != server.password) {
      throw const RemoteException(RemoteErrorKind.auth, 'The server refused the user name or password.');
    }
    server.connects++;
    server.open++;
    _connected = true;
  }

  RemoteEntry _entry(String path) {
    if (server.folders.contains(path)) return RemoteEntry(path: path, isDirectory: true);
    final bytes = server.files[path];
    if (bytes == null) throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(path)}" isn\'t there.');
    return RemoteEntry(path: path, isDirectory: false, size: bytes.length, modified: server.modified[path]);
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    _check();
    final folder = RemotePaths.normalize(path);
    if (!server.folders.contains(folder)) {
      throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(folder)}" isn\'t there.');
    }
    return [
      for (final p in [...server.folders, ...server.files.keys])
        if (p != folder && RemotePaths.parentOf(p) == folder) _entry(p),
    ];
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    _check();
    return _entry(RemotePaths.normalize(path));
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    _check();
    final p = RemotePaths.normalize(path);
    final bytes = server.files[p];
    if (bytes == null) throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(p)}" isn\'t there.');
    final stop = end == null || end > bytes.length ? bytes.length : end;
    for (var i = start; i < stop; i += server.chunkSize) {
      await server.beforeChunk?.call();
      yield bytes.sublist(i, i + server.chunkSize > stop ? stop : i + server.chunkSize);
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
    _check();
    final p = RemotePaths.normalize(path);
    if (!server.folders.contains(RemotePaths.parentOf(p))) {
      throw const RemoteException(RemoteErrorKind.notFound, 'No such folder');
    }
    if (server.folders.contains(p) || (!overwrite && server.files.containsKey(p))) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(p)}" is already there');
    }
    final out = <int>[];
    // Written as it comes, so a broken copy leaves a partial file behind.
    server.files[p] = Uint8List(0);
    await for (final chunk in data) {
      if (server.dropNextWrite && out.isNotEmpty) {
        server.dropNextWrite = false;
        _connected = false;
        server.open--;
        throw const RemoteException(RemoteErrorKind.network, 'The connection dropped.');
      }
      out.addAll(chunk);
      server.files[p] = Uint8List.fromList(out);
      onProgress?.call(out.length);
    }
    server.modified[p] = DateTime.now();
  }

  @override
  Future<void> createDirectory(String path) async {
    _check();
    final p = RemotePaths.normalize(path);
    if (server.exists(p)) throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(p)}" is already there');
    if (!server.folders.contains(RemotePaths.parentOf(p))) throw const RemoteException(RemoteErrorKind.notFound, 'No such folder');
    server.folders.add(p);
  }

  @override
  Future<void> delete(String path) async {
    _check();
    final p = RemotePaths.normalize(path);
    if (!server.exists(p)) throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(p)}" isn\'t there.');
    bool inside(String other) => other == p || other.startsWith('$p/');
    server.folders.removeWhere(inside);
    server.files.removeWhere((k, _) => inside(k));
  }

  @override
  Future<void> rename(String from, String to) async {
    _check();
    final a = RemotePaths.normalize(from);
    final b = RemotePaths.normalize(to);
    if (!server.exists(a)) throw RemoteException(RemoteErrorKind.notFound, '"${RemotePaths.nameOf(a)}" isn\'t there.');
    if (server.exists(b)) throw RemoteException(RemoteErrorKind.alreadyExists, '"${RemotePaths.nameOf(b)}" is already there');
    String moved(String p) => p == a ? b : '$b${p.substring(a.length)}';
    bool inside(String p) => p == a || p.startsWith('$a/');
    final folders = server.folders.where(inside).toList();
    final files = server.files.keys.where(inside).toList();
    for (final f in folders) {
      server.folders.remove(f);
      server.folders.add(moved(f));
    }
    for (final f in files) {
      server.files[moved(f)] = server.files.remove(f)!;
      final m = server.modified.remove(f);
      if (m != null) server.modified[moved(f)] = m;
    }
  }

  @override
  Future<void> close() async {
    if (_connected) server.open--;
    _connected = false;
  }
}

/// Registers a fake protocol (as [protocol]) whose places all live on the
/// servers in [servers], by place id (or the one named '' for any).
RemoteProtocolInfo registerFakeProtocol(
  Map<String, FakeRemoteServer> servers, {
  RemoteProtocol protocol = RemoteProtocol.sftp,
  String label = 'Fake files',
  bool usesPrivateKey = false,
  List<RemoteOptionField> options = const [],
  Future<RemoteSignIn?> Function(BuildContext context)? signIn,
  int? defaultPort = 2222,
}) {
  final info = RemoteProtocolInfo(
    protocol: protocol,
    label: label,
    icon: const IconData(0xe000),
    defaultPort: defaultPort,
    usesPrivateKey: usesPrivateKey,
    options: options,
    signIn: signIn,
    needsHost: signIn == null,
    usesPassword: signIn == null,
    create: (connection, secrets) =>
        FakeRemoteFileSystem(connection, secrets, servers[connection.id] ?? servers['']!),
  );
  RemoteProtocols.register(info);
  return info;
}
