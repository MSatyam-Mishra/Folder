import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:folders/core/services/remote/cloud/cloud_http.dart';
import 'package:folders/core/services/remote/cloud/cloud_oauth.dart';
import 'package:folders/core/services/remote/cloud/cloud_service.dart';
import 'package:folders/core/services/remote/cloud/cloud_sign_in_dialog.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Google Drive's addresses and sign-in (Drive API v3).
class GoogleDriveService extends CloudService {
  GoogleDriveService({
    this.api = 'https://www.googleapis.com/drive/v3',
    this.upload = 'https://www.googleapis.com/upload/drive/v3',
    CloudOAuthConfig? oauth,
  }) : oauth = oauth ?? live;

  static final live = CloudOAuthConfig(
    service: 'Google Drive',
    authorizeUrl: Uri.parse('https://accounts.google.com/o/oauth2/v2/auth'),
    tokenUrl: Uri.parse('https://oauth2.googleapis.com/token'),
    clientId: CloudIds.googleClientId,
    clientSecret: CloudIds.googleClientSecret,
    scopes: const ['https://www.googleapis.com/auth/drive'],
    // offline and consent: a refresh token every time, not only the first.
    authorizeParams: const {'access_type': 'offline', 'prompt': 'consent'},
  );

  final String api;
  final String upload;

  @override
  final CloudOAuthConfig oauth;

  @override
  RemoteProtocol get protocol => RemoteProtocol.googleDrive;

  @override
  String get label => 'Google Drive';

  /// A desktop client needs its secret as well as its id.
  @override
  bool get configured => oauth.configured && oauth.clientSecret.isNotEmpty;

  Uri apiUrl(String path, [Map<String, String>? query]) => Uri.parse('$api/$path').replace(queryParameters: query);

  Uri uploadUrl(String path, Map<String, String> query) => Uri.parse('$upload/$path').replace(queryParameters: query);

  @override
  Future<(String, String)> account(CloudHttp http) async {
    final response = await http.send('GET', apiUrl('about', {'fields': 'user(displayName,emailAddress)'}));
    final user = response.json['user'];
    if (user is! Map) return ('', '');
    return ('${user['emailAddress'] ?? ''}', '${user['displayName'] ?? ''}');
  }

  static (String, String) _reason(String body) {
    final error = jsonObject(body)['error'];
    if (error is! Map) return ('', '');
    final errors = error['errors'];
    final first = errors is List && errors.isNotEmpty && errors.first is Map ? errors.first as Map : const {};
    return ('${first['reason'] ?? ''}', '${error['message'] ?? ''}');
  }

  @override
  bool retryIf(int status, String body) {
    if (status != 403) return false;
    final (reason, _) = _reason(body);
    return reason == 'rateLimitExceeded' || reason == 'userRateLimitExceeded';
  }

  @override
  RemoteException errorOf(int status, String body) {
    final (reason, message) = _reason(body);
    return switch ((status, reason)) {
      (404, _) => const RemoteException(RemoteErrorKind.notFound, "That isn't in Google Drive any more."),
      (409, _) => const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.'),
      (403, 'storageQuotaExceeded' || 'quotaExceeded') =>
        const RemoteException(RemoteErrorKind.other, 'Google Drive is full. Free some space and try again.'),
      (403, 'dailyLimitExceeded') => const RemoteException(
          RemoteErrorKind.other, "Folders has used up today's Google Drive allowance. Try again tomorrow."),
      (403, 'cannotDownloadAbusiveFile') =>
        const RemoteException(RemoteErrorKind.permission, 'Google flagged this file as harmful, so it can\'t be downloaded.'),
      (403, 'teamDriveFileLimitExceeded' || 'numChildrenInNonRootLimitExceeded') =>
        const RemoteException(RemoteErrorKind.other, 'This folder is holding as many items as Google Drive allows.'),
      (403, _) => const RemoteException(RemoteErrorKind.permission, "You don't have permission to do that in Google Drive."),
      (400, _) => RemoteException(RemoteErrorKind.other, 'Google Drive refused this${message.isEmpty ? '' : ': $message'}'),
      _ => RemoteException(RemoteErrorKind.other, 'Google Drive had a problem (error $status). Try again later.'),
    };
  }
}

typedef _Export = ({String mime, String ext});

enum _Kind { top, myDrive, sharedWithMe, sharedDrives, drive, folder, file }

/// A file or folder found in Drive, under its name in the browser.
class _Item {
  const _Item(
    this.kind, {
    this.id = '',
    String? contentId,
    this.driveName = '',
    this.mimeType = '',
    this.size = 0,
    this.modified,
    this.created,
    this.driveId,
    this.export,
  }) : contentId = contentId ?? id;

  final _Kind kind;

  /// Its own id: renamed and trashed by it (a shortcut's own).
  final String id;

  /// What it shows: a shortcut's target, else [id].
  final String contentId;

  /// Its name in Drive, which may hold `/` and need not be unique.
  final String driveName;
  final String mimeType;
  final int size;
  final DateTime? modified;
  final DateTime? created;

  /// The shared drive it's on.
  final String? driveId;

  /// Google Docs, Sheets and Slides: what they're downloaded as.
  final _Export? export;

  bool get isFolder => kind != _Kind.file;

  /// Can hold new files and folders.
  bool get holdsFiles => kind == _Kind.myDrive || kind == _Kind.drive || kind == _Kind.folder;

  /// An item of Drive's own (My Drive, a shared drive...), not renamed or deleted here.
  bool get isFixed => kind != _Kind.folder && kind != _Kind.file;
}

/// Google Drive as a [RemoteFileSystem].
///
/// The top folder holds Google's own three: My Drive, Shared with me and
/// Shared drives (when there are any). Drive finds things by id, so paths are
/// resolved by listing each folder on the way, and remembered. Names in Drive
/// may repeat in one folder; the later ones show as "name (2).ext". Google
/// Docs, Sheets, Slides and Drawings show with the extension they download
/// as (.docx, .xlsx, .pptx, .png). Deleting moves to Drive's trash.
class GoogleDriveFileSystem extends CloudFileSystem {
  GoogleDriveFileSystem(
    super.connection,
    super.secrets, {
    GoogleDriveService? service,
    super.sleep,
    this.chunkSize = 8 << 20,
    this.simpleUploadLimit = 5 << 20,
  }) : service = service ?? GoogleDriveService() {
    _reset();
  }

  static const myDrive = 'My Drive';
  static const sharedWithMe = 'Shared with me';
  static const sharedDrives = 'Shared drives';

  static const info = RemoteProtocolInfo(
    protocol: RemoteProtocol.googleDrive,
    label: 'Google Drive',
    icon: LucideIcons.cloud,
    create: _create,
    needsHost: false,
    usesPassword: false,
    signIn: _signIn,
    isAvailable: _available,
    deleteNote: "Deleted items go to Google Drive's trash, where they stay for 30 days.",
  );

  static RemoteFileSystem _create(RemoteConnection connection, RemoteSecrets secrets) =>
      GoogleDriveFileSystem(connection, secrets);

  static Future<RemoteSignIn?> _signIn(BuildContext context) =>
      showCloudSignIn(context, GoogleDriveService(), icon: LucideIcons.cloud);

  static bool _available() => GoogleDriveService().configured;

  @override
  final GoogleDriveService service;

  /// Uploads bigger than [simpleUploadLimit] go in pieces of this size, a
  /// multiple of 256 KiB.
  final int chunkSize;
  final int simpleUploadLimit;

  static const _folderMime = 'application/vnd.google-apps.folder';
  static const _shortcutMime = 'application/vnd.google-apps.shortcut';
  static const _fields = 'id,name,mimeType,size,modifiedTime,createdTime,driveId,trashed,'
      'shortcutDetails(targetId,targetMimeType)';
  static const Map<String, _Export> _exports = {
    'application/vnd.google-apps.document':
        (mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', ext: '.docx'),
    'application/vnd.google-apps.spreadsheet':
        (mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', ext: '.xlsx'),
    'application/vnd.google-apps.presentation':
        (mime: 'application/vnd.openxmlformats-officedocument.presentationml.presentation', ext: '.pptx'),
    'application/vnd.google-apps.drawing': (mime: 'image/png', ext: '.png'),
    'application/vnd.google-apps.script': (mime: 'application/vnd.google-apps.script+json', ext: '.json'),
  };

  /// What each path seen so far is.
  final Map<String, _Item> _items = {};

  void _reset() {
    _items
      ..clear()
      ..['/'] = const _Item(_Kind.top)
      ..['/$myDrive'] = const _Item(_Kind.myDrive, id: 'root')
      ..['/$sharedWithMe'] = const _Item(_Kind.sharedWithMe)
      ..['/$sharedDrives'] = const _Item(_Kind.sharedDrives);
  }

  @override
  Future<void> check() => service.account(http);

  @override
  Future<void> close() async {
    _reset();
    await super.close();
  }

  // ---------------------------------------------------------------------------
  // Finding things
  // ---------------------------------------------------------------------------

  Future<_Item> _resolve(String path) async {
    path = RemotePaths.normalize(path);
    final known = _items[path];
    if (known != null) return known;
    final parent = await _resolve(RemotePaths.parentOf(path));
    if (!parent.isFolder) throw _missing(path);
    await _children(RemotePaths.parentOf(path), parent);
    return _items[path] ?? (throw _missing(path));
  }

  /// [path] and what it is, or null when it isn't there.
  Future<_Item?> _find(String path) async {
    try {
      return await _resolve(path);
    } on RemoteException catch (e) {
      if (e.kind == RemoteErrorKind.notFound) return null;
      rethrow;
    }
  }

  static RemoteException _missing(String path) =>
      RemoteException(RemoteErrorKind.notFound, '${RemotePaths.nameOf(path)} isn\'t in Google Drive any more.');

  /// Lists [folder] from Drive and remembers what's in it under their names.
  Future<List<(String, _Item)>> _children(String folder, _Item item) async {
    final List<_Item> found;
    switch (item.kind) {
      case _Kind.top:
        found = [
          const _Item(_Kind.myDrive, id: 'root', driveName: myDrive),
          const _Item(_Kind.sharedWithMe, driveName: sharedWithMe),
          if (await _hasSharedDrives()) const _Item(_Kind.sharedDrives, driveName: sharedDrives),
        ];
      case _Kind.sharedDrives:
        found = await _sharedDrives();
      case _Kind.sharedWithMe:
        found = await _query('sharedWithMe = true and trashed = false');
      case _Kind.file:
        throw RemoteException(RemoteErrorKind.notFound, '${RemotePaths.nameOf(folder)} is a file, not a folder.');
      case _Kind.myDrive || _Kind.drive || _Kind.folder:
        final driveId = item.kind == _Kind.drive ? item.contentId : item.driveId;
        found = await _query("'${item.contentId}' in parents and trashed = false", driveId: driveId);
    }
    final named = item.kind == _Kind.top
        ? [for (final f in found) (f.driveName, f)]
        : _name(found);
    _forgetChanged(folder, {for (final (name, f) in named) name: f.id});
    for (final (name, f) in named) {
      _items[RemotePaths.join(folder, name)] = f;
    }
    return named;
  }

  /// Forgets what was under [folder] and is gone or now another item.
  void _forgetChanged(String folder, Map<String, String> now) {
    final stale = [
      for (final MapEntry(key: path, value: item) in _items.entries)
        if (path != '/' && RemotePaths.parentOf(path) == folder && now[RemotePaths.nameOf(path)] != item.id) path,
    ];
    stale.forEach(_forget);
  }

  void _forget(String path) {
    final prefix = '$path/';
    _items.removeWhere((key, _) => key == path || key.startsWith(prefix));
  }

  Future<bool> _hasSharedDrives() async {
    final response = await http.send('GET', service.apiUrl('drives', {'pageSize': '1', 'fields': 'drives(id)'}));
    final drives = response.json['drives'];
    return drives is List && drives.isNotEmpty;
  }

  Future<List<_Item>> _sharedDrives() async {
    final out = <_Item>[];
    String? page;
    do {
      final response = await http.send('GET', service.apiUrl('drives', {
        'pageSize': '100',
        'fields': 'nextPageToken,drives(id,name,createdTime)',
        if (page != null) 'pageToken': page,
      }));
      final json = response.json;
      for (final d in (json['drives'] as List?) ?? const []) {
        if (d is! Map || d['id'] is! String) continue;
        out.add(_Item(_Kind.drive,
            id: d['id'] as String,
            driveName: '${d['name'] ?? ''}',
            driveId: d['id'] as String,
            created: DateTime.tryParse('${d['createdTime'] ?? ''}')));
      }
      page = json['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return out;
  }

  Future<List<_Item>> _query(String q, {String? driveId}) async {
    final out = <_Item>[];
    String? page;
    do {
      final response = await http.send('GET', service.apiUrl('files', {
        'q': q,
        'fields': 'nextPageToken,files($_fields)',
        'pageSize': '1000',
        'supportsAllDrives': 'true',
        'includeItemsFromAllDrives': 'true',
        if (driveId != null) ...{'corpora': 'drive', 'driveId': driveId},
        if (page != null) 'pageToken': page,
      }));
      final json = response.json;
      for (final f in (json['files'] as List?) ?? const []) {
        if (f is Map<String, Object?>) {
          if (_fromJson(f) case final item?) out.add(item);
        }
      }
      page = json['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return out;
  }

  /// Null for what can't be shown as a file (Forms, Sites, Maps...).
  static _Item? _fromJson(Map<String, Object?> f) {
    final id = f['id'];
    if (id is! String || f['trashed'] == true) return null;
    var mime = '${f['mimeType'] ?? ''}';
    var contentId = id;
    if (mime == _shortcutMime) {
      final details = f['shortcutDetails'];
      if (details is! Map || details['targetId'] is! String) return null;
      contentId = details['targetId'] as String;
      mime = '${details['targetMimeType'] ?? ''}';
    }
    final isFolder = mime == _folderMime;
    final export = _exports[mime];
    if (!isFolder && export == null && mime.startsWith('application/vnd.google-apps.')) return null;
    return _Item(
      isFolder ? _Kind.folder : _Kind.file,
      id: id,
      contentId: contentId,
      driveName: '${f['name'] ?? ''}',
      mimeType: mime,
      size: int.tryParse('${f['size'] ?? ''}') ?? 0,
      modified: DateTime.tryParse('${f['modifiedTime'] ?? ''}'),
      created: DateTime.tryParse('${f['createdTime'] ?? ''}'),
      driveId: f['driveId'] as String?,
      export: export,
    );
  }

  /// A Drive name as one part of a path: no `/` or `\`, never empty, `.` or `..`.
  static String _safe(String name) {
    final s = name.replaceAll('/', '\uFF0F').replaceAll('\\', '\uFF3C');
    return switch (s) { '' => '_', '.' => '\uFF0E', '..' => '\uFF0E\uFF0E', _ => s };
  }

  static String _baseName(_Item item) {
    final name = _safe(item.driveName);
    final ext = item.export?.ext;
    return ext == null || name.toLowerCase().endsWith(ext) ? name : '$name$ext';
  }

  /// Names for [items] that don't repeat: real files keep their names; the
  /// later of several with the same name (by creation, then id) become
  /// "name (2).ext", "name (3).ext"...
  static List<(String, _Item)> _name(List<_Item> items) {
    final groups = <String, List<_Item>>{};
    for (final item in items) {
      groups.putIfAbsent(_baseName(item), () => []).add(item);
    }
    final taken = groups.keys.toSet();
    final out = <(String, _Item)>[];
    for (final MapEntry(key: name, value: group) in groups.entries) {
      group.sort((a, b) {
        // A real "Report.docx" before a Google Doc named "Report".
        final converted = (a.export != null ? 1 : 0) - (b.export != null ? 1 : 0);
        if (converted != 0) return converted;
        final at = a.created ?? DateTime(0), bt = b.created ?? DateTime(0);
        final byTime = at.compareTo(bt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
      out.add((name, group.first));
      final dot = group.first.isFolder ? -1 : name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      var n = 2;
      for (final item in group.skip(1)) {
        var candidate = '$stem ($n)$ext';
        while (taken.contains(candidate)) {
          candidate = '$stem (${++n})$ext';
        }
        taken.add(candidate);
        out.add((candidate, item));
        n++;
      }
    }
    return out;
  }

  RemoteEntry _entry(String path, _Item item) => RemoteEntry(
        path: path,
        isDirectory: item.isFolder,
        size: item.isFolder || item.export != null ? 0 : item.size,
        modified: item.modified,
        mimeType: item.isFolder ? null : (item.export?.mime ?? item.mimeType),
        remoteId: item.id.isEmpty ? null : item.id,
      );

  // ---------------------------------------------------------------------------
  // RemoteFileSystem
  // ---------------------------------------------------------------------------

  @override
  Future<List<RemoteEntry>> list(String path) async {
    path = RemotePaths.normalize(path);
    final item = await _resolve(path);
    if (!item.isFolder) {
      throw RemoteException(RemoteErrorKind.notFound, '${RemotePaths.nameOf(path)} is a file, not a folder.');
    }
    try {
      final children = await _children(path, item);
      return [for (final (name, child) in children) _entry(RemotePaths.join(path, name), child)];
    } on RemoteException catch (e) {
      if (e.kind != RemoteErrorKind.notFound || item.isFixed) rethrow;
      _forget(path);
      throw _missing(path);
    }
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    path = RemotePaths.normalize(path);
    final item = await _resolve(path);
    if (item.isFixed) return _entry(path, item);
    try {
      final response = await http.send('GET', service.apiUrl('files/${item.id}', {
        'fields': _fields,
        'supportsAllDrives': 'true',
      }));
      final fresh = _fromJson(response.json);
      if (fresh == null) throw _missing(path);
      _items[path] = fresh;
      return _entry(path, fresh);
    } on RemoteException catch (e) {
      if (e.kind != RemoteErrorKind.notFound) rethrow;
      // Gone or moved: look again from its folder.
      _forget(path);
      return _entry(path, await _resolve(path));
    }
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    path = RemotePaths.normalize(path);
    if (end != null && end <= start) return;
    var item = await _resolve(path);
    if (item.isFolder) {
      throw RemoteException(RemoteErrorKind.other, '${RemotePaths.nameOf(path)} is a folder.');
    }
    for (var again = true;; again = false) {
      try {
        yield* await _download(item, start, end);
        return;
      } on RemoteException catch (e) {
        if (e.kind != RemoteErrorKind.notFound || !again) rethrow;
        _forget(path);
        item = await _resolve(path);
      }
    }
  }

  Future<Stream<List<int>>> _download(_Item item, int start, int? end) async {
    final export = item.export;
    if (export != null) {
      // Exports come whole; Drive can't send part of one.
      final response = await http.open('GET', service.apiUrl('files/${item.contentId}/export', {
        'mimeType': export.mime,
      }));
      return http.guard(start == 0 && end == null ? response : sliceBytes(response, start, end));
    }
    final ranged = start > 0 || end != null;
    final response = await http.open(
      'GET',
      service.apiUrl('files/${item.contentId}', {'alt': 'media', 'supportsAllDrives': 'true'}),
      headers: {if (ranged) 'range': 'bytes=$start-${end == null ? '' : end - 1}'},
      accept: const {416},
    );
    if (response.statusCode == 416) {
      await response.drain<void>();
      return const Stream.empty();
    }
    // A server that ignored the range sent everything.
    final whole = ranged && response.statusCode == 200;
    return http.guard(whole ? sliceBytes(response, start, end) : response);
  }

  /// The folder [path] goes in, which must be able to hold files.
  Future<_Item> _home(String path) async {
    final parent = await _resolve(RemotePaths.parentOf(path));
    if (parent.holdsFiles) return parent;
    if (!parent.isFolder) {
      throw RemoteException(
          RemoteErrorKind.notFound, '${RemotePaths.nameOf(RemotePaths.parentOf(path))} is a file, not a folder.');
    }
    throw const RemoteException(RemoteErrorKind.unsupported,
        "Google Drive can't keep anything here. Open My Drive, a shared drive or a folder first.");
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
    final parent = await _home(path);
    final existing = await _find(path);
    if (existing != null) {
      if (!overwrite || existing.isFolder) {
        throw RemoteException(RemoteErrorKind.alreadyExists, '$name is already there.');
      }
      if (existing.export != null || existing.id != existing.contentId) {
        throw RemoteException(RemoteErrorKind.unsupported,
            '$name is a Google ${existing.id != existing.contentId ? 'shortcut' : 'document'}, which a file can\'t replace.');
      }
    }
    final mime = lookupMimeType(name) ?? 'application/octet-stream';
    final metadata = existing == null
        ? {'name': name, 'parents': [parent.contentId]}
        : <String, Object?>{};
    final reader = ChunkReader(data);
    try {
      final first = await reader.next(simpleUploadLimit + 1);
      final Map<String, Object?> file;
      if (first.length <= simpleUploadLimit) {
        file = await _uploadWhole(existing?.id, metadata, mime, first);
        onProgress?.call(first.length);
      } else {
        file = await _uploadInPieces(existing?.id, metadata, mime, first, reader, length, onProgress);
      }
      if (length != null && reader.position != length) {
        throw RemoteException(RemoteErrorKind.other, '$name changed while it was being sent. Try again.');
      }
      final item = _fromJson(file);
      if (item != null) _items[path] = item;
    } finally {
      await reader.cancel();
    }
  }

  Future<Map<String, Object?>> _uploadWhole(
      String? id, Map<String, Object?> metadata, String mime, Uint8List bytes) async {
    final boundary = 'folders${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\ncontent-type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode(metadata)}\r\n--$boundary\r\ncontent-type: $mime\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final query = {'uploadType': 'multipart', 'supportsAllDrives': 'true', 'fields': _fields};
    final response = await http.send(
      id == null ? 'POST' : 'PATCH',
      service.uploadUrl(id == null ? 'files' : 'files/$id', query),
      headers: {'content-type': 'multipart/related; boundary=$boundary'},
      body: body.takeBytes(),
      // A new file sent twice would be two files.
      idempotent: id != null,
    );
    return response.json;
  }

  /// Drive's resumable upload: a session, then the file in pieces, each
  /// tried again where Drive says it got to when the connection drops.
  Future<Map<String, Object?>> _uploadInPieces(String? id, Map<String, Object?> metadata, String mime,
      Uint8List first, ChunkReader reader, int? length, void Function(int sent)? onProgress) async {
    final session = await http.send(
      id == null ? 'POST' : 'PATCH',
      service.uploadUrl(id == null ? 'files' : 'files/$id',
          {'uploadType': 'resumable', 'supportsAllDrives': 'true', 'fields': _fields}),
      headers: {
        'content-type': 'application/json; charset=UTF-8',
        'x-upload-content-type': mime,
        if (length != null) 'x-upload-content-length': '$length',
      },
      body: utf8.encode(jsonEncode(metadata)),
    );
    final location = session.headers.value('location');
    if (location == null) {
      throw const RemoteException(RemoteErrorKind.other, "Google Drive didn't start the upload. Try again.");
    }
    final url = Uri.parse(location);
    var pending = first;
    var offset = 0;
    while (true) {
      // Whole pieces only, except the last.
      if (pending.length < chunkSize && !await reader.atEnd()) {
        final more = await reader.next(chunkSize - pending.length);
        pending = (BytesBuilder(copy: false)
              ..add(pending)
              ..add(more))
            .takeBytes();
      }
      final piece = pending.length > chunkSize ? Uint8List.sublistView(pending, 0, chunkSize) : pending;
      final last = pending.length <= chunkSize && await reader.atEnd();
      final total = length ?? (last ? offset + piece.length : null);
      final (done, received) = await _sendPiece(url, piece, offset, total);
      if (done != null) {
        onProgress?.call(offset + piece.length);
        return done;
      }
      if (received <= offset) {
        throw const RemoteException(RemoteErrorKind.other, 'Google Drive stopped taking the file. Try again.');
      }
      pending = Uint8List.sublistView(pending, received - offset);
      offset = received;
      onProgress?.call(offset);
    }
  }

  /// Sends [piece] at [offset]: the finished file, or how far Drive got.
  Future<(Map<String, Object?>?, int)> _sendPiece(Uri url, Uint8List piece, int offset, int? total) async {
    final size = total == null ? '*' : '$total';
    for (var attempt = 0;; attempt++) {
      CloudResponse? response;
      try {
        response = await http.send('PUT', url,
            headers: {'content-range': 'bytes $offset-${offset + piece.length - 1}/$size'},
            body: piece,
            idempotent: false,
            accept: const {308, 500, 502, 503, 504});
      } on RemoteException catch (e) {
        if (e.kind != RemoteErrorKind.network || attempt >= 3) rethrow;
      }
      if (response != null && response.statusCode < 500) {
        return response.statusCode == 308 ? (null, _received(response)) : (response.json, offset + piece.length);
      }
      if (response != null && attempt >= 3) throw service.errorOf(response.statusCode, response.text);
      await http.sleep(Duration(seconds: 1 << attempt));
      // Ask Drive how far it got, then go on from there.
      final status = await http.send('PUT', url, headers: {'content-range': 'bytes */$size'}, accept: const {308});
      if (status.statusCode != 308) return (status.json, offset + piece.length);
      final got = _received(status);
      if (got > offset) return (null, got);
    }
  }

  /// The end of Drive's "Range: bytes=0-N", as a count; 0 when it has nothing.
  static int _received(CloudResponse response) {
    final range = response.headers.value('range');
    final end = range == null ? null : int.tryParse(range.substring(range.lastIndexOf('-') + 1));
    return end == null ? 0 : end + 1;
  }

  @override
  Future<void> createDirectory(String path) async {
    path = RemotePaths.normalize(path);
    final name = RemotePaths.nameOf(path);
    if (path == '/' || (_items[path]?.isFixed ?? false)) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '$name is already there.');
    }
    final parent = await _home(path);
    if (await _find(path) != null) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '$name is already there.');
    }
    final response = await http.send(
      'POST',
      service.apiUrl('files', {'supportsAllDrives': 'true', 'fields': _fields}),
      headers: {'content-type': 'application/json; charset=UTF-8'},
      body: utf8.encode(jsonEncode({
        'name': name,
        'mimeType': _folderMime,
        'parents': [parent.contentId],
      })),
      idempotent: false,
    );
    if (_fromJson(response.json) case final item?) _items[path] = item;
  }

  @override
  Future<void> delete(String path) async {
    path = RemotePaths.normalize(path);
    final item = await _resolve(path);
    if (item.isFixed) {
      throw RemoteException(RemoteErrorKind.unsupported, "${RemotePaths.nameOf(path)} belongs to Google Drive and can't be deleted here.");
    }
    await http.send(
      'PATCH',
      service.apiUrl('files/${item.id}', {'supportsAllDrives': 'true', 'fields': 'id'}),
      headers: {'content-type': 'application/json; charset=UTF-8'},
      body: utf8.encode(jsonEncode({'trashed': true})),
    );
    _forget(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    from = RemotePaths.normalize(from);
    to = RemotePaths.normalize(to);
    if (from == to) return;
    final item = await _resolve(from);
    if (item.isFixed) {
      throw RemoteException(RemoteErrorKind.unsupported, "${RemotePaths.nameOf(from)} belongs to Google Drive and can't be renamed.");
    }
    if (to.startsWith('$from/')) {
      throw const RemoteException(RemoteErrorKind.other, "A folder can't go inside itself.");
    }
    final oldParent = await _resolve(RemotePaths.parentOf(from));
    final sameFolder = RemotePaths.parentOf(from) == RemotePaths.parentOf(to);
    final newParent = sameFolder ? oldParent : await _home(to);
    if (await _find(to) != null) {
      throw RemoteException(RemoteErrorKind.alreadyExists, '${RemotePaths.nameOf(to)} is already there.');
    }
    final moving = !sameFolder && oldParent.contentId != newParent.contentId;
    if (moving && !oldParent.holdsFiles) {
      throw const RemoteException(
          RemoteErrorKind.unsupported, "Items shared with you can't be moved from Shared with me; copy them instead.");
    }
    var name = RemotePaths.nameOf(to);
    final ext = item.export?.ext;
    if (ext != null && name.toLowerCase().endsWith(ext) && name.length > ext.length) {
      name = name.substring(0, name.length - ext.length);
    }
    final response = await http.send(
      'PATCH',
      service.apiUrl('files/${item.id}', {
        'supportsAllDrives': 'true',
        'fields': _fields,
        if (moving) ...{'addParents': newParent.contentId, 'removeParents': oldParent.contentId},
      }),
      headers: {'content-type': 'application/json; charset=UTF-8'},
      body: utf8.encode(jsonEncode({'name': name})),
    );
    _forget(from);
    if (_fromJson(response.json) case final moved?) _items[to] = moved;
  }
}
