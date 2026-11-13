import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:folders/core/services/remote/cloud/cloud_http.dart';
import 'package:folders/core/services/remote/cloud/cloud_oauth.dart';
import 'package:folders/core/services/remote/cloud/cloud_service.dart';
import 'package:folders/core/services/remote/cloud/cloud_sign_in_dialog.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Dropbox's addresses and sign-in (API v2).
class DropboxService extends CloudService {
  DropboxService({
    this.api = 'https://api.dropboxapi.com/2',
    this.content = 'https://content.dropboxapi.com/2',
    CloudOAuthConfig? oauth,
  }) : oauth = oauth ?? live;

  static final live = CloudOAuthConfig(
    service: 'Dropbox',
    authorizeUrl: Uri.parse('https://www.dropbox.com/oauth2/authorize'),
    tokenUrl: Uri.parse('https://api.dropboxapi.com/oauth2/token'),
    clientId: CloudIds.dropboxAppKey,
    authorizeParams: const {'token_access_type': 'offline'},
    // Dropbox accepts only the exact address registered for the app.
    redirectHost: 'localhost',
    exactPort: true,
  );

  final String api;
  final String content;

  @override
  final CloudOAuthConfig oauth;

  @override
  RemoteProtocol get protocol => RemoteProtocol.dropbox;

  @override
  String get label => 'Dropbox';

  /// A call to one of the API's JSON endpoints.
  Future<Map<String, Object?>> rpc(CloudHttp http, String endpoint, Object? args, {bool idempotent = true}) async {
    final response = await http.send(
      'POST',
      Uri.parse('$api/$endpoint'),
      headers: args == null ? const {} : const {'content-type': 'application/json'},
      body: args == null ? null : utf8.encode(jsonEncode(args)),
      idempotent: idempotent,
    );
    return response.json;
  }

  @override
  Future<(String, String)> account(CloudHttp http) async {
    final json = await rpc(http, 'users/get_current_account', null);
    final name = json['name'];
    return ('${json['email'] ?? ''}', name is Map ? '${name['display_name'] ?? ''}' : '');
  }

  /// Dropbox-API-Arg: JSON in a header, so ASCII only.
  static String headerArg(Object? args) {
    final out = StringBuffer();
    for (final unit in jsonEncode(args).codeUnits) {
      if (unit < 0x7F) {
        out.writeCharCode(unit);
      } else {
        out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
      }
    }
    return out.toString();
  }

  static String summary(String body) => '${jsonObject(body)['error_summary'] ?? ''}';

  @override
  bool retryIf(int status, String body) => status == 409 && summary(body).contains('too_many_write_operations');

  @override
  RemoteException errorOf(int status, String body) {
    if (status == 409) {
      final s = summary(body);
      bool has(String what) => s.contains(what);
      if (has('not_found')) return const RemoteException(RemoteErrorKind.notFound, "That isn't in Dropbox any more.");
      if (has('not_folder')) return const RemoteException(RemoteErrorKind.notFound, "That's a file, not a folder.");
      if (has('conflict')) {
        return const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.');
      }
      if (has('insufficient_space')) {
        return const RemoteException(RemoteErrorKind.other, 'Dropbox is full. Free some space and try again.');
      }
      if (has('no_write_permission') || has('access_denied') || has('team_folder') || has('restricted_content')) {
        return const RemoteException(RemoteErrorKind.permission, "You don't have permission to do that in Dropbox.");
      }
      if (has('disallowed_name') || has('malformed_path')) {
        return const RemoteException(RemoteErrorKind.other, "Dropbox doesn't allow that name.");
      }
      if (has('cant_move_folder_into_itself')) {
        return const RemoteException(RemoteErrorKind.other, "A folder can't go inside itself.");
      }
      if (has('too_large')) return const RemoteException(RemoteErrorKind.other, 'That file is too big for Dropbox.');
      return RemoteException(RemoteErrorKind.other, "Dropbox couldn't do that${s.isEmpty ? '' : ' ($s)'}.");
    }
    return switch (status) {
      403 => const RemoteException(RemoteErrorKind.permission, "You don't have permission to do that in Dropbox."),
      404 => const RemoteException(RemoteErrorKind.notFound, "That isn't in Dropbox any more."),
      400 => const RemoteException(RemoteErrorKind.other, 'Dropbox refused this request.'),
      _ => RemoteException(RemoteErrorKind.other, 'Dropbox had a problem (error $status). Try again later.'),
    };
  }
}

/// Dropbox as a [RemoteFileSystem], addressed by path. Deleted files stay
/// restorable on dropbox.com for 30 days or more, depending on the plan.
class DropboxFileSystem extends CloudFileSystem {
  DropboxFileSystem(
    super.connection,
    super.secrets, {
    DropboxService? service,
    super.sleep,
    this.chunkSize = 8 << 20,
    this.simpleUploadLimit = 8 << 20,
  }) : service = service ?? DropboxService();

  static const info = RemoteProtocolInfo(
    protocol: RemoteProtocol.dropbox,
    label: 'Dropbox',
    icon: LucideIcons.box,
    create: _create,
    needsHost: false,
    usesPassword: false,
    signIn: _signIn,
    isAvailable: _available,
    deleteNote: 'Dropbox keeps deleted files for at least 30 days; they can be restored on dropbox.com.',
  );

  static RemoteFileSystem _create(RemoteConnection connection, RemoteSecrets secrets) =>
      DropboxFileSystem(connection, secrets);

  static Future<RemoteSignIn?> _signIn(BuildContext context) =>
      showCloudSignIn(context, DropboxService(), icon: LucideIcons.box);

  static bool _available() => DropboxService().configured;

  @override
  final DropboxService service;

  /// Bigger uploads go in pieces of this size.
  final int chunkSize;
  final int simpleUploadLimit;

  @override
  Future<void> check() => service.account(http);

  /// Dropbox's path for [path]: "" for the top, and `\` given back where
  /// the browser shows `＼`.
  static String _dropboxPath(String path) {
    final p = RemotePaths.normalize(path);
    return p == '/' ? '' : p.replaceAll('\uFF3C', '\\');
  }

  /// A Dropbox name as one part of a path.
  static String _name(String name) => name.replaceAll('\\', '\uFF3C');

  Future<Map<String, Object?>> _rpc(String endpoint, Object? args, {bool idempotent = true}) =>
      service.rpc(http, endpoint, args, idempotent: idempotent);

  static RemoteEntry _entry(String path, Map<String, Object?> json) {
    final isDirectory = json['.tag'] == 'folder';
    final modified = json['client_modified'] ?? json['server_modified'];
    final size = json['size'];
    return RemoteEntry(
      path: path,
      isDirectory: isDirectory,
      size: isDirectory || size is! num ? 0 : size.toInt(),
      modified: modified is String ? DateTime.tryParse(modified) : null,
      remoteId: json['id'] as String?,
    );
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    path = RemotePaths.normalize(path);
    final out = <RemoteEntry>[];
    var json = await _rpc('files/list_folder', {
      'path': _dropboxPath(path),
      'recursive': false,
      'include_deleted': false,
      'include_non_downloadable_files': false,
      'limit': 2000,
    });
    while (true) {
      for (final e in (json['entries'] as List?) ?? const []) {
        if (e is! Map<String, Object?> || e['name'] is! String) continue;
        if (e['.tag'] != 'file' && e['.tag'] != 'folder') continue;
        // Its own name under the asked path: path_display may have other case.
        out.add(_entry(RemotePaths.join(path, _name(e['name'] as String)), e));
      }
      final cursor = json['cursor'];
      if (json['has_more'] != true || cursor is! String) break;
      json = await _rpc('files/list_folder/continue', {'cursor': cursor});
    }
    return out;
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    path = RemotePaths.normalize(path);
    if (path == '/') return const RemoteEntry(path: '/', isDirectory: true);
    final json = await _rpc('files/get_metadata', {'path': _dropboxPath(path)});
    if (json['.tag'] == 'deleted') throw RemoteException(RemoteErrorKind.notFound, "${RemotePaths.nameOf(path)} isn't in Dropbox any more.");
    return _entry(path, json);
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    path = RemotePaths.normalize(path);
    if (end != null && end <= start) return;
    final ranged = start > 0 || end != null;
    final response = await http.open(
      'POST',
      Uri.parse('${service.content}/files/download'),
      headers: {
        'dropbox-api-arg': DropboxService.headerArg({'path': _dropboxPath(path)}),
        if (ranged) 'range': 'bytes=$start-${end == null ? '' : end - 1}',
      },
      accept: const {416},
    );
    if (response.statusCode == 416) {
      await response.drain<void>();
      return;
    }
    yield* http.guard(ranged && response.statusCode == 200 ? sliceBytes(response, start, end) : response);
  }

  Future<CloudResponse> _content(String endpoint, Object? args, List<int> body,
          {bool idempotent = false, Set<int> accept = const {}}) =>
      http.send(
        'POST',
        Uri.parse('${service.content}/$endpoint'),
        headers: {
          'dropbox-api-arg': DropboxService.headerArg(args),
          'content-type': 'application/octet-stream',
        },
        body: body,
        idempotent: idempotent,
        accept: accept,
      );

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
    final commit = {
      'path': _dropboxPath(path),
      'mode': overwrite ? 'overwrite' : 'add',
      'autorename': false,
      'mute': true,
      // Otherwise "add" quietly succeeds when the same file is already there.
      if (!overwrite) 'strict_conflict': true,
    };
    final reader = ChunkReader(data);
    try {
      final first = await reader.next(simpleUploadLimit + 1);
      if (first.length <= simpleUploadLimit) {
        if (length != null && first.length != length) throw _changed(name);
        await _content('files/upload', commit, first, idempotent: overwrite);
        onProgress?.call(first.length);
        return;
      }
      // Fail before sending gigabytes, not after.
      if (!overwrite && await _exists(path)) {
        throw RemoteException(RemoteErrorKind.alreadyExists, '$name is already there.');
      }
      await _uploadInPieces(commit, first, reader, onProgress);
      if (length != null && reader.position != length) throw _changed(name);
    } finally {
      await reader.cancel();
    }
  }

  Future<bool> _exists(String path) async {
    try {
      await stat(path);
      return true;
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return false;
      rethrow;
    }
  }

  static RemoteException _changed(String name) =>
      RemoteException(RemoteErrorKind.other, '$name changed while it was being sent. Try again.');

  /// An upload session: start, append each piece, finish with the last.
  Future<void> _uploadInPieces(Map<String, Object?> commit, Uint8List pending, ChunkReader reader,
      void Function(int sent)? onProgress) async {
    String? session;
    var offset = 0;
    while (true) {
      if (pending.length < chunkSize && !await reader.atEnd()) {
        final more = await reader.next(chunkSize - pending.length);
        pending = (BytesBuilder(copy: false)
              ..add(pending)
              ..add(more))
            .takeBytes();
      }
      final piece = pending.length > chunkSize ? Uint8List.sublistView(pending, 0, chunkSize) : pending;
      final last = pending.length <= chunkSize && await reader.atEnd();
      if (session == null) {
        final started = await _content('files/upload_session/start', {'close': false}, piece);
        session = started.json['session_id'] as String?;
        if (session == null) {
          throw const RemoteException(RemoteErrorKind.other, "Dropbox didn't start the upload. Try again.");
        }
        offset = piece.length;
      } else {
        offset = await _append(session, offset, piece, last ? commit : null);
        if (last) {
          onProgress?.call(offset);
          return;
        }
      }
      pending = Uint8List.sublistView(pending, piece.length);
      onProgress?.call(offset);
      if (last) {
        // Everything went with the start: finish with nothing more.
        await _append(session, offset, Uint8List(0), commit);
        return;
      }
    }
  }

  /// Appends [piece] at [offset], or finishes with it when [commit] is set.
  /// Gives the new offset. After a dropped connection, Dropbox says where it
  /// got to and the rest is sent from there.
  Future<int> _append(String session, int offset, Uint8List piece, Map<String, Object?>? commit) async {
    var at = offset;
    for (var attempt = 0;; attempt++) {
      final sent = Uint8List.sublistView(piece, at - offset);
      final cursor = {'session_id': session, 'offset': at};
      final CloudResponse response;
      try {
        response = commit != null
            ? await _content('files/upload_session/finish', {'cursor': cursor, 'commit': commit}, sent,
                accept: const {409})
            : await _content('files/upload_session/append_v2', {'cursor': cursor, 'close': false}, sent,
                accept: const {409});
      } on RemoteException catch (e) {
        if (e.kind != RemoteErrorKind.network || attempt >= 3) rethrow;
        await http.sleep(Duration(seconds: 1 << attempt));
        continue;
      }
      if (response.statusCode != 409) return offset + piece.length;
      if (attempt < 3 && service.retryIf(409, response.text)) {
        await http.sleep(Duration(seconds: 1 << attempt));
        continue;
      }
      final correct = _correctOffset(response.json);
      if (correct == null || attempt >= 3 || correct < offset || correct > offset + piece.length) {
        throw service.errorOf(409, response.text);
      }
      at = correct;
    }
  }

  /// Where Dropbox's "incorrect_offset" says the upload is.
  static int? _correctOffset(Object? json) {
    if (json is! Map) return null;
    final value = json['correct_offset'];
    if (value is num) return value.toInt();
    for (final inner in json.values) {
      if (_correctOffset(inner) case final found?) return found;
    }
    return null;
  }

  @override
  Future<void> createDirectory(String path) async {
    path = RemotePaths.normalize(path);
    if (path == '/') throw const RemoteException(RemoteErrorKind.alreadyExists, 'That folder is already there.');
    await _rpc('files/create_folder_v2', {'path': _dropboxPath(path), 'autorename': false}, idempotent: false);
  }

  @override
  Future<void> delete(String path) async {
    path = RemotePaths.normalize(path);
    if (path == '/') throw const RemoteException(RemoteErrorKind.unsupported, "Dropbox itself can't be deleted.");
    await _rpc('files/delete_v2', {'path': _dropboxPath(path)}, idempotent: false);
  }

  @override
  Future<void> rename(String from, String to) async {
    from = RemotePaths.normalize(from);
    to = RemotePaths.normalize(to);
    if (from == to) return;
    if (from == '/') throw const RemoteException(RemoteErrorKind.unsupported, "Dropbox itself can't be renamed.");
    if (from.toLowerCase() == to.toLowerCase()) {
      // Only the case changes, which Dropbox's names ignore: by way of another name.
      final step = '$to.folders-${DateTime.now().microsecondsSinceEpoch}';
      await _move(from, step);
      await _move(step, to);
      return;
    }
    await _move(from, to);
  }

  Future<void> _move(String from, String to) => _rpc(
        'files/move_v2',
        {
          'from_path': _dropboxPath(from),
          'to_path': _dropboxPath(to),
          'autorename': false,
          'allow_ownership_transfer': false,
        },
        idempotent: false,
      );
}
