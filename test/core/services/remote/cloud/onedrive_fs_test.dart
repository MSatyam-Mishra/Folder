import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/cloud/onedrive_fs.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

import 'fake_cloud.dart';

class _Node {
  _Node(this.id, this.name, {this.folder = false, Uint8List? data, this.remote}) : data = data ?? Uint8List(0);

  final String id;
  String name;
  final bool folder;
  Uint8List data;
  _Node? parent;
  final children = <_Node>[];

  /// A shared folder added to this drive: (drive, item) where it really is.
  final (String, String)? remote;

  _Node? child(String name) {
    for (final c in children) {
      if (c.name.toLowerCase() == name.toLowerCase()) return c;
    }
    return null;
  }

  void add(_Node node) {
    node.parent = this;
    children.add(node);
  }
}

class _Upload {
  _Upload(this.folder, this.name, this.replace);

  final _Node folder;
  final String name;
  final bool replace;
  final data = BytesBuilder();
}

/// Microsoft Graph's drive endpoints, as far as the app uses them.
class _FakeGraph {
  late FakeCloud cloud;
  var _next = 0;
  late final roots = {'me': _Node('root', 'root', folder: true), 'other': _Node('oroot', 'root', folder: true)};
  final uploads = <String, _Upload>{};
  final deleted = <String>[];

  /// Download addresses refused once, as if they'd expired.
  bool expireDownload = false;

  /// The n-th upload piece is kept but its answer is lost.
  int dropPiece = 0;
  int _pieces = 0;

  _Node node(String path, {String drive = 'me', bool folder = false, List<int>? data, (String, String)? remote}) {
    var at = roots[drive]!;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    for (final p in parts.take(parts.length - 1)) {
      var next = at.child(p);
      if (next == null) {
        next = _Node('n${_next++}', p, folder: true);
        at.add(next);
      }
      at = next;
    }
    final n = _Node('n${_next++}', parts.last,
        folder: folder, data: data == null ? Uint8List.fromList(utf8.encode('${parts.last}!')) : Uint8List.fromList(data), remote: remote);
    at.add(n);
    return n;
  }

  _Node? _byId(_Node from, String id) {
    if (from.id == id) return from;
    for (final c in from.children) {
      if (_byId(c, id) case final found?) return found;
    }
    return null;
  }

  Map<String, Object?> _json(_Node n) => {
        'id': n.id,
        'name': n.name,
        if (n.parent == null) 'root': <String, Object?>{},
        'size': n.folder ? 0 : n.data.length,
        'lastModifiedDateTime': '2026-03-04T05:06:07Z',
        'fileSystemInfo': {'lastModifiedDateTime': '2025-01-02T03:04:05Z'},
        if (n.folder && n.remote == null) 'folder': {'childCount': n.children.length},
        if (!n.folder) 'file': {'mimeType': 'text/plain'},
        if (!n.folder) '@microsoft.graph.downloadUrl': '${cloud.base}/download/${n.id}',
        if (n.remote != null)
          'remoteItem': {
            'id': n.remote!.$2,
            'folder': {'childCount': 1},
            'parentReference': {'driveId': n.remote!.$1},
          },
      };

  Future<void> _error(HttpResponse r, int status, String code) =>
      json(r, {'error': {'code': code, 'message': code}}, status: status);

  Future<void> handle(Seen s, HttpResponse r) async {
    final path = s.path;
    if (path.startsWith('/download/')) {
      expect(s.headers['authorization'], isNull);
      if (expireDownload) {
        expireDownload = false;
        r.statusCode = 401;
        return r.close();
      }
      final n = _byId(roots['me']!, path.substring(10)) ?? _byId(roots['other']!, path.substring(10));
      return ranged(s, r, n!.data);
    }
    if (path.startsWith('/upload/')) return _piece(s, r, path.substring(8));
    if (!await cloud.authorized(s, r, body: {'error': {'code': 'InvalidAuthenticationToken'}})) return;
    if (path == '/v1.0/me') return json(r, {'displayName': 'Me', 'userPrincipalName': 'me@example.com'});
    if (path == '/v1.0/me/drive') return json(r, {'id': 'me', 'driveType': 'personal'});

    final m = RegExp(r'^/v1\.0/(?:me/drive/root|drives/([^/]+)/items/([^/:]+))(?::(/[^:]*):)?(?:/(\w+))?$').firstMatch(path);
    if (m == null) return _error(r, 400, 'invalidRequest');
    _Node? at = m[1] == null ? roots['me'] : _byId(roots[m[1]]!, m[2]!);
    final segments = (m[3] ?? '').split('/').where((p) => p.isNotEmpty).map(Uri.decodeComponent).toList();
    final action = m[4] ?? '';
    final q = s.uri.queryParameters;
    final conflict = q['@microsoft.graph.conflictBehavior'];

    // Creating: the last part needn't exist.
    if (action == 'content' || action == 'createUploadSession') {
      for (final p in segments.take(segments.length - 1)) {
        var next = at!.child(p);
        if (next == null) {
          next = _Node('n${_next++}', p, folder: true);
          at.add(next);
        }
        at = next;
      }
      final name = segments.last;
      final existing = at!.child(name);
      final behavior = action == 'content'
          ? conflict
          : ((jsonDecode(utf8.decode(s.body)) as Map)['item'] as Map)['@microsoft.graph.conflictBehavior'];
      if (existing != null && behavior == 'fail') return _error(r, 409, 'nameAlreadyExists');
      if (action == 'createUploadSession') {
        final sid = 'u${uploads.length}';
        uploads[sid] = _Upload(at, name, behavior == 'replace');
        return json(r, {'uploadUrl': '${cloud.base}/upload/$sid', 'expirationDateTime': '2030-01-01T00:00:00Z'});
      }
      final n = existing ?? (_Node('n${_next++}', name)..parent = at);
      if (existing == null) at.children.add(n);
      n.data = s.body;
      return json(r, _json(n), status: existing == null ? 201 : 200);
    }

    for (final p in segments) {
      // Nothing is inside a shared folder's entry: it's on the other drive.
      at = at == null || at.remote != null ? null : at.child(p);
    }
    if (at == null) return _error(r, 404, 'itemNotFound');
    final n = at;
    switch ((s.method, action)) {
      case ('GET', ''):
        return json(r, _json(n));
      case ('GET', 'children'):
        if (n.remote != null) return json(r, {'value': <Object>[]});
        final top = int.parse(q[r'$top'] ?? '200').clamp(1, 3);
        final from = int.parse(q[r'$skiptoken'] ?? '0');
        final page = n.children.skip(from).take(top).toList();
        return json(r, {
          'value': [for (final c in page) _json(c)],
          if (from + top < n.children.length)
            '@odata.nextLink': '${cloud.base}${s.path}?\$top=$top&\$skiptoken=${from + top}',
        });
      case ('POST', 'children'):
        final body = jsonDecode(utf8.decode(s.body)) as Map<String, Object?>;
        expect(body['@microsoft.graph.conflictBehavior'], 'fail');
        if (n.child(body['name'] as String) != null) return _error(r, 409, 'nameAlreadyExists');
        final made = _Node('n${_next++}', body['name'] as String, folder: true);
        n.add(made);
        return json(r, _json(made), status: 201);
      case ('DELETE', ''):
        n.parent!.children.remove(n);
        deleted.add(n.name);
        r.statusCode = 204;
        return r.close();
      case ('PATCH', ''):
        final body = jsonDecode(utf8.decode(s.body)) as Map<String, Object?>;
        final reference = body['parentReference'] as Map?;
        final target = reference == null ? n.parent! : _byId(roots['me']!, reference['id'] as String)!;
        final name = body['name'] as String? ?? n.name;
        final clash = target.child(name);
        if (clash != null && clash != n) return _error(r, 409, 'nameAlreadyExists');
        n.parent!.children.remove(n);
        n.name = name;
        target.add(n);
        return json(r, _json(n));
    }
    return _error(r, 400, 'invalidRequest');
  }

  Future<void> _piece(Seen s, HttpResponse r, String sid) async {
    expect(s.headers['authorization'], isNull, reason: 'upload addresses take no token');
    final upload = uploads[sid];
    if (upload == null) return _error(r, 404, 'itemNotFound');
    if (s.method == 'DELETE') {
      uploads.remove(sid);
      r.statusCode = 204;
      return r.close();
    }
    if (s.method == 'GET') return json(r, {'nextExpectedRanges': ['${upload.data.length}-']});
    final m = RegExp(r'bytes (\d+)-(\d+)/(\d+)').firstMatch(s.headers['content-range']!)!;
    final total = int.parse(m[3]!);
    expect(int.parse(m[1]!), upload.data.length);
    upload.data.add(s.body);
    if (++_pieces == dropPiece) {
      (await r.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    if (upload.data.length < total) {
      return json(r, {'nextExpectedRanges': ['${upload.data.length}-']}, status: 202);
    }
    final existing = upload.folder.child(upload.name);
    if (existing != null && !upload.replace) return _error(r, 409, 'nameAlreadyExists');
    final n = existing ?? (_Node('n${_next++}', upload.name)..parent = upload.folder);
    if (existing == null) upload.folder.children.add(n);
    n.data = upload.data.toBytes();
    uploads.remove(sid);
    return json(r, _json(n), status: 201);
  }
}

void main() {
  late _FakeGraph graph;
  late FakeCloud cloud;
  late OneDriveFileSystem fs;
  late MemoryRemoteSecrets secrets;

  setUp(() async {
    graph = _FakeGraph();
    cloud = await FakeCloud(graph.handle).start();
    graph.cloud = cloud;
    cloud.rotateRefresh = true;
    secrets = MemoryRemoteSecrets({'accessToken': 'token0', 'refreshToken': 'refresh0'});
    fs = OneDriveFileSystem(
      const RemoteConnection(id: 'o', protocol: RemoteProtocol.oneDrive, name: 'OneDrive'),
      secrets,
      service: OneDriveService(
          graph: '${cloud.base}/v1.0', oauth: cloud.oauth(redirectHost: 'localhost', scopeOnRefresh: true)),
      sleep: (_) async {},
      chunkSize: 320 * 1024,
      simpleUploadLimit: 100 * 1024,
    );
    await fs.connect();
  });

  tearDown(() async {
    await fs.close();
    await cloud.close();
  });

  Future<List<int>> read(String path, {int start = 0, int? end}) =>
      fs.openRead(path, start: start, end: end).expand((c) => c).toList();

  Future<List<String>> names(String path) async => [for (final e in await fs.list(path)) e.name]..sort();

  test('lists by path, in pages, with odd names', () async {
    for (final name in ['a.txt', 'b c.txt', 'd#%.txt', 'e', 'f.txt']) {
      graph.node('/Docs/$name', folder: name == 'e');
    }
    expect(await names('/'), ['Docs']);
    final list = await fs.list('/Docs');
    expect([for (final e in list) e.name]..sort(), ['a.txt', 'b c.txt', 'd#%.txt', 'e', 'f.txt']);
    expect(cloud.requests('GET', '/children').length, 3, reason: 'two pages of /Docs');
    expect(list.firstWhere((e) => e.name == 'e').isDirectory, isTrue);
    final a = list.firstWhere((e) => e.name == 'a.txt');
    expect(a.size, 6);
    expect(a.modified, DateTime.utc(2025, 1, 2, 3, 4, 5));
    expect(a.mimeType, 'text/plain');
    expect(utf8.decode(await read('/Docs/d#%.txt')), 'd#%.txt!');
    expect(await names('/Docs/e'), isEmpty);
    await expectLater(fs.list('/Docs/a.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    await expectLater(fs.stat('/Docs/zzz'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    expect((await fs.stat('/')).isDirectory, isTrue);
  });

  test('reads through the download address, in part, and asks again when it expired', () async {
    final data = sample(4000);
    graph.node('/v.bin', data: data);
    expect(await read('/v.bin', start: 10, end: 20), data.sublist(10, 20));
    expect(cloud.seen.last.headers['range'], 'bytes=10-19');
    graph.expireDownload = true;
    expect(await read('/v.bin'), data);
    expect(cloud.requests('GET', '/download/'), hasLength(3));
  });

  test('small uploads fail on a taken name unless replacing', () async {
    await fs.write('/Notes/a.txt', Stream.value(utf8.encode('one')));
    expect(utf8.decode(graph.roots['me']!.child('Notes')!.child('a.txt')!.data), 'one');
    await expectLater(fs.write('/Notes/a.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await fs.write('/Notes/a.txt', Stream.value(utf8.encode('two')), overwrite: true);
    expect(utf8.decode(graph.roots['me']!.child('Notes')!.child('a.txt')!.data), 'two');
    expect(cloud.requests('PUT', '/content').last.uri.queryParameters['@microsoft.graph.conflictBehavior'], 'replace');
  });

  test('big uploads go through a session, sized or not, and resume after a drop', () async {
    final data = sample(700 * 1024, 5);
    final sent = <int>[];
    await fs.write('/big.bin', pieces(data), length: data.length, onProgress: sent.add);
    expect(graph.roots['me']!.child('big.bin')!.data, data);
    expect(cloud.requests('PUT', '/upload/').map((s) => s.headers['content-range']),
        ['bytes 0-327679/716800', 'bytes 327680-655359/716800', 'bytes 655360-716799/716800']);
    expect(sent.last, data.length);

    cloud.seen.clear();
    await fs.write('/unsized.bin', pieces(data));
    expect(graph.roots['me']!.child('unsized.bin')!.data, data);
    expect(cloud.requests('PUT', '/upload/').first.headers['content-range'], 'bytes 0-327679/716800');

    cloud.seen.clear();
    graph.dropPiece = graph._pieces + 1;
    await fs.write('/dropped.bin', pieces(data), length: data.length);
    expect(graph.roots['me']!.child('dropped.bin')!.data, data);
    expect(cloud.requests('GET', '/upload/'), hasLength(1), reason: 'asked where to go on from');

    await expectLater(fs.write('/big.bin', pieces(data), length: data.length),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
  });

  test('folders: make, rename, move and delete to the recycle bin', () async {
    await fs.createDirectory('/A');
    await expectLater(fs.createDirectory('/A'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await fs.createDirectory('/A/B');
    graph.node('/x.txt');
    graph.node('/y.txt');
    await fs.rename('/x.txt', '/X2.txt');
    expect(await names('/'), ['A', 'X2.txt', 'y.txt']);
    await fs.rename('/X2.txt', '/A/B/x.txt');
    expect(await names('/A/B'), ['x.txt']);
    expect(jsonDecode(utf8.decode(cloud.requests('PATCH').last.body))['parentReference'], isNotNull);
    await expectLater(fs.rename('/y.txt', '/A'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await fs.delete('/A');
    expect(graph.deleted, ['A']);
    expect(await names('/'), ['y.txt']);
  });

  test("a shared folder added to this OneDrive is read from its owner's drive", () async {
    final theirs = graph.node('/Project', drive: 'other', folder: true);
    graph.node('/Project/theirs.txt', drive: 'other');
    graph.node('/Shared Project', folder: true, remote: ('other', theirs.id));
    final top = await fs.list('/');
    expect(top.single.isDirectory, isTrue);
    expect(await names('/Shared Project'), ['theirs.txt']);
    expect(cloud.requests('GET', '/drives/other/items/${theirs.id}/children'), hasLength(1));
    expect(utf8.decode(await read('/Shared Project/theirs.txt')), 'theirs.txt!');

    // Opened straight away after a restart, without listing first.
    final cold = OneDriveFileSystem(fs.connection, secrets,
        service: OneDriveService(graph: '${cloud.base}/v1.0', oauth: cloud.oauth(scopeOnRefresh: true)));
    expect(utf8.decode(await cold.openRead('/Shared Project/theirs.txt').expand((c) => c).toList()), 'theirs.txt!');
    expect((await cold.stat('/Shared Project/theirs.txt')).size, 11);
    await cold.close();
    final calls = cloud.seen.length;
    await fs.list('/Shared Project');
    expect(cloud.seen.length, calls + 1, reason: 'nothing to learn once listed');

    // Deleting it removes it from this OneDrive, not the owner's folder.
    await fs.delete('/Shared Project');
    expect(graph.roots['other']!.child('Project'), isNotNull);
    expect(graph.roots['me']!.children, isEmpty);
  });

  test('a refused token is renewed and the new refresh token kept', () async {
    graph.node('/a.txt');
    cloud.validToken = 'token9';
    expect(await names('/'), ['a.txt']);
    expect(secrets.values['accessToken'], 'token1');
    expect(secrets.values['refreshToken'], 'refresh1');
    final refresh = Uri.splitQueryString(utf8.decode(cloud.requests('POST', '/token').single.body));
    expect(refresh['scope'], 'files');
    expect(OneDriveService.live.scopeOnRefresh, isTrue);
    expect(OneDriveService.live.scopes, contains('offline_access'));
    expect(refresh.containsKey('client_secret'), isFalse);
  });

  test('a full OneDrive and a locked file say so', () async {
    cloud.faults.add(Fault((s) => s.path.endsWith('/content'),
        status: 507, body: jsonEncode({'error': {'code': 'quotaLimitReached'}})));
    await expectLater(fs.write('/a.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('OneDrive is full'))));
    cloud.faults.add(Fault((s) => s.method == 'DELETE', status: 423, body: jsonEncode({'error': {'code': 'resourceLocked'}})));
    await expectLater(fs.delete('/a.txt'),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('locked'))));
  });
}
