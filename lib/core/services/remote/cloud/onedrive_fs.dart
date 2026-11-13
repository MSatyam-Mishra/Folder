import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:folders/core/services/remote/cloud/cloud_http.dart';
import 'package:folders/core/services/remote/cloud/cloud_oauth.dart';
import 'package:folders/core/services/remote/cloud/cloud_service.dart';
import 'package:folders/core/services/remote/cloud/cloud_sign_in_dialog.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// OneDrive's addresses and sign-in (Microsoft Graph), for personal and
/// work or school accounts.
class OneDriveService extends CloudService {
  OneDriveService({this.graph = 'https://graph.microsoft.com/v1.0', CloudOAuthConfig? oauth}) : oauth = oauth ?? live;

  static final live = CloudOAuthConfig(
    service: 'OneDrive',
    authorizeUrl: Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/authorize'),
    tokenUrl: Uri.parse('https://login.microsoftonline.com/common/oauth2/v2.0/token'),
    clientId: CloudIds.oneDriveClientId,
    scopes: const ['Files.ReadWrite.All', 'offline_access', 'User.Read'],
    authorizeParams: const {'prompt': 'select_account'},
    redirectHost: 'localhost',
    scopeOnRefresh: true,
  );

  final String graph;

  @override
  final CloudOAuthConfig oauth;

  @override
  RemoteProtocol get protocol => RemoteProtocol.oneDrive;

  @override
  String get label => 'OneDrive';

  @override
  Future<(String, String)> account(CloudHttp http) async {
    final me = (await http.send('GET', Uri.parse('$graph/me?\$select=displayName,mail,userPrincipalName'))).json;
    final mail = me['mail'] ?? me['userPrincipalName'];
    return (mail is String ? mail : '', '${me['displayName'] ?? ''}');
  }

  @override
  RemoteException errorOf(int status, String body) {
    final error = jsonObject(body)['error'];
    final code = error is Map ? '${error['code'] ?? ''}' : '';
    final message = error is Map ? '${error['message'] ?? ''}' : '';
    if (code == 'quotaLimitReached' || status == 507) {
      return const RemoteException(RemoteErrorKind.other, 'OneDrive is full. Free some space and try again.');
    }
    return switch (status) {
      404 => const RemoteException(RemoteErrorKind.notFound, "That isn't in OneDrive any more."),
      409 => const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.'),
      403 => const RemoteException(RemoteErrorKind.permission, "You don't have permission to do that in OneDrive."),
      423 => const RemoteException(
          RemoteErrorKind.other, "That file is locked: it's open somewhere else, or checked out. Try again later."),
      413 => const RemoteException(RemoteErrorKind.other, 'That file is too big for OneDrive.'),
      400 => RemoteException(RemoteErrorKind.other, 'OneDrive refused this${message.isEmpty ? '' : ': $message'}'),
      _ => RemoteException(RemoteErrorKind.other, 'OneDrive had a problem (error $status). Try again later.'),
    };
  }
}

/// OneDrive as a [RemoteFileSystem], addressed by path
/// (`/me/drive/root:/Photos/a.jpg:`). Folders shared with the user and added
/// to their OneDrive live on the owner's drive, and what's in them is
/// reached through that drive. Deleting moves to OneDrive's recycle bin.
class OneDriveFileSystem extends CloudFileSystem {
  OneDriveFileSystem(
    super.connection,
    super.secrets, {
    OneDriveService? service,
    super.sleep,
    this.chunkSize = 10 << 20,
    this.simpleUploadLimit = 4 << 20,
  }) : service = service ?? OneDriveService();

  static const info = RemoteProtocolInfo(
    protocol: RemoteProtocol.oneDrive,
    label: 'OneDrive',
    icon: LucideIcons.cloudy,
    create: _create,
    needsHost: false,
    usesPassword: false,
    signIn: _signIn,
    isAvailable: _available,
    deleteNote: "Deleted items go to OneDrive's recycle bin.",
  );

  static RemoteFileSystem _create(RemoteConnection connection, RemoteSecrets secrets) =>
      OneDriveFileSystem(connection, secrets);

  static Future<RemoteSignIn?> _signIn(BuildContext context) =>
      showCloudSignIn(context, OneDriveService(), icon: LucideIcons.cloudy);

  static bool _available() => OneDriveService().configured;

  @override
  final OneDriveService service;

  /// Bigger uploads go in pieces of this size, a multiple of 320 KiB.
  final int chunkSize;
  final int simpleUploadLimit;

  /// Shared folders added to this OneDrive: path → where they really are.
  final Map<String, ({String driveId, String itemId})> _mounts = {};

  /// Paths seen, so whether they're shared folders is known.
  final Set<String> _seen = {};

  /// Download addresses, which work without the token for a while.
  final Map<String, (Uri, DateTime)> _downloads = {};

  static const _json = {'content-type': 'application/json'};

  @override
  Future<void> check() => http.send('GET', Uri.parse('${service.graph}/me/drive?\$select=id,driveType'));

  @override
  Future<void> close() async {
    _mounts.clear();
    _seen.clear();
    _downloads.clear();
    await super.close();
  }

  /// Looks at the folders above [path] (and [path] itself when [self]) not
  /// seen yet, as when a saved place is opened straight away, to find shared
  /// folders on the way. Nothing to do once the browser has listed them.
  Future<void> _learnMounts(String path, {bool self = false}) async {
    var at = '';
    final parts = RemotePaths.normalize(path).split('/').where((s) => s.isNotEmpty).toList();
    if (!self && parts.isNotEmpty) parts.removeLast();
    for (final part in parts) {
      at = '$at/$part';
      if (_mounts.containsKey(at)) return;
      if (_seen.contains(at)) continue;
      try {
        final json = (await http.send('GET', _address(at, local: true))).json;
        if (!_entry(at, json).isDirectory || _mounts.containsKey(at)) return;
      } on RemoteException catch (e) {
        if (e.kind == RemoteErrorKind.notFound) return;
        rethrow;
      }
    }
  }

  /// Graph's address of [path], then `/[action]`. A shared folder's own entry
  /// in this OneDrive is [local]; what's in it is on the owner's drive.
  Uri _address(String path, {String action = '', String query = '', bool local = false}) {
    path = RemotePaths.normalize(path);
    String? mount;
    for (final m in _mounts.keys) {
      final inside = path.startsWith('$m/') || (path == m && !local);
      if (inside && (mount == null || m.length > mount.length)) mount = m;
    }
    final String base;
    final String rest;
    if (mount != null) {
      final target = _mounts[mount]!;
      base = 'drives/${target.driveId}/items/${target.itemId}';
      rest = path.substring(mount.length);
    } else {
      base = 'me/drive/root';
      rest = path;
    }
    final parts = rest.split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent).join('/');
    final item = parts.isEmpty ? base : '$base:/$parts:';
    return Uri.parse('${service.graph}/$item${action.isEmpty ? '' : '/$action'}${query.isEmpty ? '' : '?$query'}');
  }

  RemoteEntry _entry(String path, Map<String, Object?> json) {
    final remote = json['remoteItem'] is Map ? json['remoteItem'] as Map : null;
    final isDirectory = json['folder'] != null ||
        json['package'] != null ||
        json['root'] != null ||
        (remote != null && (remote['folder'] != null || remote['package'] != null));
    final file = json['file'] ?? remote?['file'];
    final info = json['fileSystemInfo'] ?? remote?['fileSystemInfo'];
    final modified = info is Map ? info['lastModifiedDateTime'] : null;
    final size = json['size'] ?? remote?['size'];
    _seen.add(path);
    if (remote != null && isDirectory && path != '/') {
      final reference = remote['parentReference'];
      final driveId = reference is Map ? reference['driveId'] : null;
      final itemId = remote['id'];
      if (driveId is String && itemId is String) _mounts[path] = (driveId: driveId, itemId: itemId);
    }
    return RemoteEntry(
      path: path,
      isDirectory: isDirectory,
      size: isDirectory || size is! num ? 0 : size.toInt(),
      modified: DateTime.tryParse('${modified ?? json['lastModifiedDateTime'] ?? ''}'),
      mimeType: file is Map ? file['mimeType'] as String? : null,
      remoteId: json['id'] as String?,
    );
  }

  void _forget(String path) {
    final prefix = '$path/';
    _mounts.removeWhere((key, _) => key == path || key.startsWith(prefix));
    _seen.removeWhere((key) => key == path || key.startsWith(prefix));
    _downloads.removeWhere((key, _) => key == path || key.startsWith(prefix));
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    path = RemotePaths.normalize(path);
    await _learnMounts(path, self: true);
    final out = <RemoteEntry>[];
    var url = _address(path, action: 'children', query: '\$top=1000');
    while (true) {
      final json = (await http.send('GET', url)).json;
      for (final item in (json['value'] as List?) ?? const []) {
        if (item is Map<String, Object?> && item['name'] is String) {
          out.add(_entry(RemotePaths.join(path, item['name'] as String), item));
        }
      }
      final next = json['@odata.nextLink'];
      if (next is! String) break;
      url = Uri.parse(next);
    }
    if (out.isEmpty && path != '/' && !(await stat(path)).isDirectory) {
      throw RemoteException(RemoteErrorKind.notFound, '${RemotePaths.nameOf(path)} is a file, not a folder.');
    }
    return out;
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    path = RemotePaths.normalize(path);
    await _learnMounts(path);
    final json = (await http.send('GET', _address(path, local: true))).json;
    return _entry(path, json);
  }

  Future<Uri> _downloadUrl(String path) async {
    final known = _downloads[path];
    if (known != null && known.$2.isAfter(DateTime.now())) return known.$1;
    await _learnMounts(path);
    final json = (await http.send('GET', _address(path))).json;
    if (json['folder'] != null || json['package'] != null) {
      throw RemoteException(RemoteErrorKind.other, '${RemotePaths.nameOf(path)} is a folder.');
    }
    final url = json['@microsoft.graph.downloadUrl'];
    if (url is! String) {
      throw RemoteException(RemoteErrorKind.unsupported, "OneDrive can't download ${RemotePaths.nameOf(path)}.");
    }
    final uri = Uri.parse(url);
    // They last about an hour.
    _downloads[path] = (uri, DateTime.now().add(const Duration(minutes: 10)));
    return uri;
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    path = RemotePaths.normalize(path);
    if (end != null && end <= start) return;
    final ranged = start > 0 || end != null;
    for (var again = true;; again = false) {
      final url = await _downloadUrl(path);
      // The download address carries its own permission: no token.
      final response = await http.open('GET', url,
          authorized: false,
          headers: {if (ranged) 'range': 'bytes=$start-${end == null ? '' : end - 1}'},
          accept: const {401, 403, 404, 410, 416});
      final status = response.statusCode;
      if (status == 416) {
        await response.drain<void>();
        return;
      }
      if (status >= 400) {
        await response.drain<void>();
        _downloads.remove(path);
        if (again) continue; // The address expired; ask for a new one.
        throw service.errorOf(status, '');
      }
      yield* http.guard(ranged && status == 200 ? sliceBytes(response, start, end) : response);
      return;
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
    path = RemotePaths.normalize(path);
    final name = RemotePaths.nameOf(path);
    final behavior = overwrite ? 'replace' : 'fail';
    _downloads.remove(path);
    await _learnMounts(path);
    var reader = ChunkReader(data);
    Directory? spool;
    try {
      final first = await reader.next(simpleUploadLimit + 1);
      if (first.length <= simpleUploadLimit) {
        if (length != null && first.length != length) throw _changed(name);
        await http.send(
          'PUT',
          _address(path, action: 'content', query: '@microsoft.graph.conflictBehavior=$behavior'),
          headers: {'content-type': 'application/octet-stream'},
          body: first,
          idempotent: overwrite,
        );
        onProgress?.call(first.length);
        return;
      }
      var pending = first;
      if (length == null) {
        // An upload session needs the size first: keep it in a file to count.
        spool = await Directory.systemTemp.createTemp('folders-upload-');
        final file = File('${spool.path}${Platform.pathSeparator}data');
        final sink = file.openWrite()..add(first);
        while (!await reader.atEnd()) {
          sink.add(await reader.next(chunkSize));
        }
        await sink.close();
        await reader.cancel();
        length = await file.length();
        reader = ChunkReader(file.openRead());
        pending = Uint8List(0);
      }
      await _uploadInPieces(path, behavior, pending, reader, length, onProgress);
    } finally {
      await reader.cancel();
      if (spool != null) {
        try {
          await spool.delete(recursive: true);
        } on FileSystemException {
          // Left for the system to clear.
        }
      }
    }
  }

  static RemoteException _changed(String name) =>
      RemoteException(RemoteErrorKind.other, '$name changed while it was being sent. Try again.');

  Future<void> _uploadInPieces(String path, String behavior, Uint8List pending, ChunkReader reader, int length,
      void Function(int sent)? onProgress) async {
    final session = await http.send(
      'POST',
      _address(path, action: 'createUploadSession'),
      headers: _json,
      body: utf8.encode(jsonEncode({
        'item': {'@microsoft.graph.conflictBehavior': behavior},
      })),
      idempotent: false,
    );
    final uploadUrl = session.json['uploadUrl'];
    if (uploadUrl is! String) {
      throw const RemoteException(RemoteErrorKind.other, "OneDrive didn't start the upload. Try again.");
    }
    final url = Uri.parse(uploadUrl);
    var offset = 0;
    try {
      while (true) {
        if (pending.length < chunkSize && !await reader.atEnd()) {
          final more = await reader.next(chunkSize - pending.length);
          pending = (BytesBuilder(copy: false)
                ..add(pending)
                ..add(more))
              .takeBytes();
        }
        final piece = pending.length > chunkSize ? Uint8List.sublistView(pending, 0, chunkSize) : pending;
        if (piece.isEmpty || offset + piece.length > length) throw _changed(RemotePaths.nameOf(path));
        final (done, next) = await _sendPiece(url, piece, offset, length);
        if (done) {
          if (offset + piece.length != length || !await reader.atEnd()) throw _changed(RemotePaths.nameOf(path));
          onProgress?.call(length);
          return;
        }
        if (next <= offset) {
          throw const RemoteException(RemoteErrorKind.other, 'OneDrive stopped taking the file. Try again.');
        }
        pending = Uint8List.sublistView(pending, next - offset);
        offset = next;
        onProgress?.call(offset);
      }
    } on Object {
      // Let OneDrive drop the unfinished upload.
      unawaited(http
          .send('DELETE', url, authorized: false, accept: const {404})
          .then((_) {}, onError: (Object _) {}));
      rethrow;
    }
  }

  /// Sends [piece] at [offset]: whether the file is complete, and if not,
  /// where OneDrive wants the next bytes from.
  Future<(bool, int)> _sendPiece(Uri url, Uint8List piece, int offset, int length) async {
    for (var attempt = 0;; attempt++) {
      CloudResponse? response;
      try {
        // The upload address carries its own permission: no token.
        response = await http.send('PUT', url,
            authorized: false,
            headers: {'content-range': 'bytes $offset-${offset + piece.length - 1}/$length'},
            body: piece,
            idempotent: false,
            accept: const {500, 502, 503, 504});
      } on RemoteException catch (e) {
        if (e.kind == RemoteErrorKind.notFound) {
          throw const RemoteException(
              RemoteErrorKind.other, 'The upload took too long and OneDrive dropped it. Try again.');
        }
        if (e.kind != RemoteErrorKind.network || attempt >= 3) rethrow;
      }
      if (response != null && response.statusCode < 500) {
        if (response.statusCode != 202) return (true, length);
        return (false, _nextExpected(response.json) ?? offset + piece.length);
      }
      if (response != null && attempt >= 3) throw service.errorOf(response.statusCode, response.text);
      await http.sleep(Duration(seconds: 1 << attempt));
      // Ask OneDrive how far it got.
      final status = await http.send('GET', url, authorized: false);
      final next = _nextExpected(status.json);
      if (next != null && next > offset) return (false, next);
    }
  }

  static int? _nextExpected(Map<String, Object?> json) {
    final ranges = json['nextExpectedRanges'];
    if (ranges is! List || ranges.isEmpty) return null;
    final first = '${ranges.first}';
    return int.tryParse(first.split('-').first);
  }

  @override
  Future<void> createDirectory(String path) async {
    path = RemotePaths.normalize(path);
    if (path == '/') throw const RemoteException(RemoteErrorKind.alreadyExists, 'That folder is already there.');
    await _learnMounts(path);
    await http.send(
      'POST',
      _address(RemotePaths.parentOf(path), action: 'children'),
      headers: _json,
      body: utf8.encode(jsonEncode({
        'name': RemotePaths.nameOf(path),
        'folder': <String, Object?>{},
        '@microsoft.graph.conflictBehavior': 'fail',
      })),
      idempotent: false,
    );
  }

  @override
  Future<void> delete(String path) async {
    path = RemotePaths.normalize(path);
    if (path == '/') throw const RemoteException(RemoteErrorKind.unsupported, "OneDrive itself can't be deleted.");
    await _learnMounts(path);
    // A shared folder's own entry: removes it from this OneDrive, not the owner's folder.
    await http.send('DELETE', _address(path, local: true));
    _forget(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    from = RemotePaths.normalize(from);
    to = RemotePaths.normalize(to);
    if (from == to) return;
    if (from == '/') throw const RemoteException(RemoteErrorKind.unsupported, "OneDrive itself can't be renamed.");
    if (to.startsWith('$from/')) {
      throw const RemoteException(RemoteErrorKind.other, "A folder can't go inside itself.");
    }
    await _learnMounts(from);
    await _learnMounts(to);
    final body = <String, Object?>{'name': RemotePaths.nameOf(to)};
    if (RemotePaths.parentOf(from) != RemotePaths.parentOf(to)) {
      final folder = (await http.send('GET', _address(RemotePaths.parentOf(to)))).json;
      final remote = folder['remoteItem'];
      final id = remote is Map ? remote['id'] : folder['id'];
      if (id is! String) throw const RemoteException(RemoteErrorKind.notFound, "That folder isn't in OneDrive any more.");
      body['parentReference'] = {'id': id};
    }
    // Graph's default when the name is taken is to fail; said anyway.
    await http.send(
      'PATCH',
      _address(from, local: true, query: '@microsoft.graph.conflictBehavior=fail'),
      headers: _json,
      body: utf8.encode(jsonEncode(body)),
    );
    final moved = {
      for (final e in _mounts.entries)
        if (e.key == from || e.key.startsWith('$from/')) to + e.key.substring(from.length): e.value,
    };
    _forget(from);
    _mounts.addAll(moved);
  }
}
