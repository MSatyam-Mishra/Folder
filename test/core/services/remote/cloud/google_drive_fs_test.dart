import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/cloud/google_drive_fs.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

import 'fake_cloud.dart';

const _folder = 'application/vnd.google-apps.folder';
const _doc = 'application/vnd.google-apps.document';

class _File {
  _File(this.id, this.name, this.mime, this.parents, this.data, this.created, {this.driveId, this.target, this.shared = false});

  final String id;
  String name;
  final String mime;
  List<String> parents;
  Uint8List data;
  final DateTime created;
  final String? driveId;
  final _File? target;
  final bool shared;
  bool trashed = false;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'mimeType': mime,
        if (!mime.startsWith('application/vnd.google-apps.')) 'size': '${data.length}',
        'modifiedTime': created.toIso8601String(),
        'createdTime': created.toIso8601String(),
        if (driveId != null) 'driveId': driveId,
        'trashed': trashed,
        if (target != null) 'shortcutDetails': {'targetId': target!.id, 'targetMimeType': target!.mime},
      };
}

class _Session {
  _Session(this.metadata, this.targetId, this.total);

  final Map<String, Object?> metadata;
  final String? targetId;
  final int? total;
  final data = BytesBuilder();
  _File? done;
}

/// Drive API v3, as far as the app uses it, over in-memory files.
class _FakeDrive {
  late FakeCloud cloud;
  final files = <String, _File>{};
  final drives = <Map<String, String>>[];
  final sessions = <String, _Session>{};
  var _next = 0;
  var _time = DateTime.utc(2026, 1, 1);

  /// The n-th piece of an upload is kept but its answer is lost.
  int dropPiece = 0;
  int _pieces = 0;

  _File add(String name, {String parent = 'root', String mime = 'text/plain', List<int>? data, String? driveId, _File? target, bool shared = false}) {
    final id = 'id${_next++}';
    _time = _time.add(const Duration(minutes: 1));
    return files[id] = _File(id, name, mime, shared ? [] : [parent], Uint8List.fromList(data ?? utf8.encode('$name!')), _time,
        driveId: driveId, target: target, shared: shared);
  }

  Future<void> handle(Seen s, HttpResponse r) async {
    if (!await cloud.authorized(s, r, body: {'error': {'code': 401, 'message': 'Invalid Credentials'}})) return;
    final q = s.uri.queryParameters;
    final parts = s.path.split('/').where((p) => p.isNotEmpty).toList();
    final upload = parts.first == 'upload';
    if (upload) parts.removeAt(0);
    // drive v3 ...
    final rest = parts.sublist(2);
    if (rest.first == 'about') return json(r, {'user': {'emailAddress': 'me@example.com', 'displayName': 'Me'}});
    if (rest.first == 'drives') {
      final size = int.parse(q['pageSize'] ?? '100');
      return json(r, {'drives': drives.take(size).toList()});
    }
    final id = rest.length > 1 ? rest[1] : null;
    if (upload && s.method == 'PUT') return _piece(s, r);
    if (upload) return _upload(s, r, id);
    if (id == null && s.method == 'GET') return _list(s, r);
    if (id == null && s.method == 'POST') {
      final meta = jsonDecode(utf8.decode(s.body)) as Map<String, Object?>;
      final f = add(meta['name'] as String, parent: (meta['parents'] as List).first as String, mime: meta['mimeType'] as String, data: []);
      return json(r, f.toJson());
    }
    final f = files[id];
    if (f == null) return json(r, {'error': {'code': 404, 'message': 'File not found: $id.', 'errors': [{'reason': 'notFound'}]}}, status: 404);
    if (s.method == 'GET' && rest.length > 2 && rest[2] == 'export') {
      return bytes(r, utf8.encode('EXPORTED ${f.name} as ${q['mimeType']}'));
    }
    if (s.method == 'GET' && q['alt'] == 'media') return ranged(s, r, f.data);
    if (s.method == 'GET') return json(r, f.toJson());
    if (s.method == 'PATCH') {
      final meta = jsonDecode(utf8.decode(s.body)) as Map<String, Object?>;
      if (meta['trashed'] == true) f.trashed = true;
      if (meta['name'] case final String name) f.name = name;
      if (q['addParents'] case final String add) f.parents = [...f.parents.where((p) => p != q['removeParents']), add];
      return json(r, f.toJson());
    }
    r.statusCode = 405;
    await r.close();
  }

  Future<void> _list(Seen s, HttpResponse r) async {
    final q = s.uri.queryParameters;
    final query = q['q']!;
    final parent = RegExp(r"^'([^']+)' in parents and trashed = false$").firstMatch(query)?[1];
    final all = [
      for (final f in files.values)
        if (!f.trashed && (parent != null ? f.parents.contains(parent) : query.startsWith('sharedWithMe') && f.shared)) f,
    ];
    if (q['corpora'] == 'drive') expect(all.every((f) => f.driveId == q['driveId']), isTrue);
    final size = int.parse(q['pageSize']!).clamp(1, 3);
    final from = int.parse(q['pageToken'] ?? '0');
    final page = all.skip(from).take(size).toList();
    return json(r, {
      'files': [for (final f in page) f.toJson()],
      if (from + size < all.length) 'nextPageToken': '${from + size}',
    });
  }

  Future<void> _upload(Seen s, HttpResponse r, String? id) async {
    final q = s.uri.queryParameters;
    if (q['uploadType'] == 'multipart') {
      final (meta, media) = _multipart(s.body, s.headers['content-type']!);
      final _File f;
      if (id != null) {
        f = files[id]!..data = media;
      } else {
        f = add(meta['name'] as String, parent: (meta['parents'] as List).first as String, data: media);
      }
      return json(r, f.toJson());
    }
    expect(q['uploadType'], 'resumable');
    final meta = jsonDecode(utf8.decode(s.body)) as Map<String, Object?>;
    final sid = 'session${sessions.length}';
    final total = s.headers['x-upload-content-length'];
    sessions[sid] = _Session(meta, id, total == null ? null : int.parse(total));
    r.headers.set('location', '${cloud.base}/upload/drive/v3/files?uploadType=resumable&upload_id=$sid');
    await r.close();
  }

  Future<void> _piece(Seen s, HttpResponse r) async {
    final session = sessions[s.uri.queryParameters['upload_id']]!;
    final range = s.headers['content-range']!;
    Future<void> incomplete() async {
      r.statusCode = 308;
      final n = session.data.length;
      if (n > 0) r.headers.set('range', 'bytes=0-${n - 1}');
      await r.close();
    }

    if (range.startsWith('bytes */')) {
      return session.done != null ? json(r, session.done!.toJson()) : incomplete();
    }
    final m = RegExp(r'bytes (\d+)-(\d+)/(\d+|\*)').firstMatch(range)!;
    expect(int.parse(m[2]!) - int.parse(m[1]!) + 1, s.body.length);
    if (int.parse(m[1]!) != session.data.length) return incomplete();
    session.data.add(s.body);
    if (++_pieces == dropPiece) {
      (await r.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    final total = m[3] == '*' ? null : int.parse(m[3]!);
    if (total == null || session.data.length < total) return incomplete();
    final data = session.data.toBytes();
    if (session.targetId != null) {
      session.done = files[session.targetId]!..data = data;
    } else {
      session.done = add(session.metadata['name'] as String,
          parent: (session.metadata['parents'] as List).first as String, data: data);
    }
    return json(r, session.done!.toJson());
  }

  static (Map<String, Object?>, Uint8List) _multipart(Uint8List body, String type) {
    final boundary = RegExp(r'boundary=(\S+)').firstMatch(type)![1]!;
    int find(List<int> needle, int from) {
      outer:
      for (var i = from; i <= body.length - needle.length; i++) {
        for (var j = 0; j < needle.length; j++) {
          if (body[i + j] != needle[j]) continue outer;
        }
        return i;
      }
      return -1;
    }

    final delimiter = ascii.encode('\r\n--$boundary');
    final parts = <Uint8List>[];
    var pos = find(ascii.encode('--$boundary\r\n'), 0) + boundary.length + 4;
    while (true) {
      final head = find(ascii.encode('\r\n\r\n'), pos) + 4;
      final end = find(delimiter, head);
      parts.add(body.sublist(head, end));
      pos = end + delimiter.length;
      if (body[pos] == 0x2d) break;
      pos += 2;
    }
    return (jsonDecode(utf8.decode(parts[0])) as Map<String, Object?>, parts[1]);
  }
}

void main() {
  late _FakeDrive drive;
  late FakeCloud cloud;
  late GoogleDriveFileSystem fs;
  late MemoryRemoteSecrets secrets;
  final slept = <Duration>[];

  setUp(() async {
    slept.clear();
    drive = _FakeDrive();
    cloud = await FakeCloud(drive.handle).start();
    drive.cloud = cloud;
    secrets = MemoryRemoteSecrets({'accessToken': 'token0', 'refreshToken': 'refresh0'});
    fs = GoogleDriveFileSystem(
      const RemoteConnection(id: 'g', protocol: RemoteProtocol.googleDrive, name: 'Google Drive (me@example.com)'),
      secrets,
      service: GoogleDriveService(
        api: '${cloud.base}/drive/v3',
        upload: '${cloud.base}/upload/drive/v3',
        oauth: cloud.oauth(clientSecret: 's'),
      ),
      sleep: (d) async => slept.add(d),
      chunkSize: 256 * 1024,
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

  test("the top holds Google's three, Shared drives only when there are some", () async {
    expect(await names('/'), ['My Drive', 'Shared with me']);
    drive.drives.add({'id': 'd1', 'name': 'Team'});
    expect(await names('/'), ['My Drive', 'Shared drives', 'Shared with me']);
    expect((await fs.stat('/My Drive')).isDirectory, isTrue);
  });

  test('My Drive in pages, with repeated names, Google Docs, shortcuts and odd names', () async {
    drive.add('a.txt');
    drive.add('a.txt', data: [1, 2, 3]);
    drive.add('a (2).txt');
    drive.add('Report', mime: _doc);
    drive.add('Survey', mime: 'application/vnd.google-apps.form');
    drive.add('x/y.txt');
    final photos = drive.add('Photos', mime: _folder);
    drive.add('p.jpg', parent: photos.id, mime: 'image/jpeg');
    drive.add('Link', target: photos, mime: 'application/vnd.google-apps.shortcut');

    final list = await fs.list('/My Drive');
    expect([for (final e in list) e.name]..sort(),
        ['Link', 'Photos', 'Report.docx', 'a (2).txt', 'a (3).txt', 'a.txt', 'x\uFF0Fy.txt']);
    expect(drive.cloud.requests('GET', '/drive/v3/files').length, greaterThan(2), reason: 'paged');
    final report = list.firstWhere((e) => e.name == 'Report.docx');
    expect(report.size, 0);
    expect(report.mimeType, contains('wordprocessingml'));
    expect(list.firstWhere((e) => e.name == 'Link').isDirectory, isTrue);
    expect((await read('/My Drive/a (3).txt')), [1, 2, 3]);
    expect(await names('/My Drive/Link'), ['p.jpg']);
    expect(utf8.decode(await read('/My Drive/x\uFF0Fy.txt')), 'x/y.txt!');
  });

  test('stat, and something gone since it was listed', () async {
    final f = drive.add('notes.txt', data: sample(1234));
    final entry = await fs.stat('/My Drive/notes.txt');
    expect(entry.size, 1234);
    expect(entry.remoteId, f.id);
    expect(entry.modified, f.created);
    expect(entry.isDirectory, isFalse);

    f.trashed = true;
    await expectLater(fs.stat('/My Drive/notes.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    await expectLater(fs.list('/My Drive/nothing'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
  });

  test('reads all of a file or part of it, and exports Google Docs', () async {
    final data = sample(5000);
    drive.add('big.bin', data: data);
    drive.add('Report', mime: _doc);
    expect(await read('/My Drive/big.bin'), data);
    expect(await read('/My Drive/big.bin', start: 100, end: 200), data.sublist(100, 200));
    expect(cloud.seen.last.headers['range'], 'bytes=100-199');
    expect(await read('/My Drive/big.bin', start: 4990), data.sublist(4990));
    expect(await read('/My Drive/big.bin', start: 9000), isEmpty);

    final exported = utf8.decode(await read('/My Drive/Report.docx'));
    expect(exported, startsWith('EXPORTED Report as application/vnd.openxmlformats'));
    expect(utf8.decode(await read('/My Drive/Report.docx', start: 9, end: 15)), 'Report');

    cloud.faults.add(Fault((s) => s.path.endsWith('/export'),
        status: 403, body: jsonEncode({'error': {'code': 403, 'errors': [{'reason': 'exportSizeLimitExceeded'}]}})));
    await expectLater(read('/My Drive/Report.docx'),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('too big'))));
  });

  test('small uploads in one go; existing files only when overwriting', () async {
    final sent = <int>[];
    await fs.write('/My Drive/hello.txt', Stream.value(utf8.encode('hello')), length: 5, onProgress: sent.add);
    final f = drive.files.values.singleWhere((f) => f.name == 'hello.txt');
    expect(utf8.decode(f.data), 'hello');
    expect(f.parents, ['root']);
    expect(sent, [5]);
    expect(cloud.requests('POST', '/upload').single.uri.queryParameters['uploadType'], 'multipart');

    await expectLater(fs.write('/My Drive/hello.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await fs.write('/My Drive/hello.txt', Stream.value(utf8.encode('again')), overwrite: true);
    expect(utf8.decode(f.data), 'again');
    expect(drive.files.values.where((f) => f.name == 'hello.txt'), hasLength(1));

    drive.add('Report', mime: _doc);
    await expectLater(fs.write('/My Drive/Report.docx', Stream.value([1]), overwrite: true),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.unsupported)));
    await expectLater(fs.write('/Shared with me/x.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.unsupported)));
    await expectLater(fs.write('/x.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.unsupported)));
  });

  test('big uploads in pieces, with or without the size, and after a dropped piece', () async {
    final data = sample(600 * 1024, 3);
    final sent = <int>[];
    await fs.write('/My Drive/big.bin', pieces(data), length: data.length, onProgress: sent.add);
    expect(drive.files.values.singleWhere((f) => f.name == 'big.bin').data, data);
    final puts = cloud.requests('PUT', '/upload');
    expect(puts.map((s) => s.headers['content-range']),
        ['bytes 0-262143/614400', 'bytes 262144-524287/614400', 'bytes 524288-614399/614400']);
    expect(sent, [262144, 524288, 614400]);

    cloud.seen.clear();
    await fs.write('/My Drive/unknown.bin', pieces(data));
    expect(drive.files.values.singleWhere((f) => f.name == 'unknown.bin').data, data);
    expect(cloud.requests('PUT', '/upload').map((s) => s.headers['content-range']),
        ['bytes 0-262143/*', 'bytes 262144-524287/*', 'bytes 524288-614399/614400']);

    cloud.seen.clear();
    drive.dropPiece = drive._pieces + 2;
    await fs.write('/My Drive/dropped.bin', pieces(data), length: data.length);
    expect(drive.files.values.singleWhere((f) => f.name == 'dropped.bin').data, data);
    expect(cloud.requests('PUT', '/upload').map((s) => s.headers['content-range']), contains('bytes */614400'));

    // Replacing a big file updates it in place.
    final other = sample(300 * 1024, 9);
    await fs.write('/My Drive/big.bin', pieces(other), length: other.length, overwrite: true);
    expect(drive.files.values.singleWhere((f) => f.name == 'big.bin').data, other);
    expect(cloud.requests('PATCH', '/upload'), hasLength(1));
  });

  test('folders: make, delete to the trash, rename and move', () async {
    await fs.createDirectory('/My Drive/New');
    final folder = drive.files.values.singleWhere((f) => f.name == 'New');
    expect(folder.mime, _folder);
    await expectLater(fs.createDirectory('/My Drive/New'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await expectLater(fs.createDirectory('/Shared with me/New'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.unsupported)));

    final doc = drive.add('Report', mime: _doc);
    await fs.rename('/My Drive/Report.docx', '/My Drive/Final.docx');
    expect(doc.name, 'Final');
    expect(await names('/My Drive'), ['Final.docx', 'New']);

    await fs.rename('/My Drive/Final.docx', '/My Drive/New/Final.docx');
    expect(doc.parents, [folder.id]);
    final patch = cloud.requests('PATCH', '/files/${doc.id}').last.uri.queryParameters;
    expect(patch['addParents'], folder.id);
    expect(patch['removeParents'], 'root');
    expect(await names('/My Drive/New'), ['Final.docx']);

    drive.add('taken.txt');
    drive.add('mine.txt');
    await expectLater(fs.rename('/My Drive/mine.txt', '/My Drive/taken.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));

    await fs.delete('/My Drive/New');
    expect(folder.trashed, isTrue);
    expect(drive.files.containsKey(folder.id), isTrue, reason: 'in the trash, not gone');
    expect(await names('/My Drive'), ['mine.txt', 'taken.txt']);
    await expectLater(fs.delete('/My Drive'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.unsupported)));
  });

  test('Shared with me and shared drives', () async {
    drive.add('From Ann.pdf', shared: true);
    drive.drives.add({'id': 'd1', 'name': 'Team'});
    drive.add('plan.txt', parent: 'd1', driveId: 'd1');
    expect(await names('/Shared with me'), ['From Ann.pdf']);
    expect(await names('/Shared drives'), ['Team']);
    expect(await names('/Shared drives/Team'), ['plan.txt']);
    final listing = cloud.requests('GET', '/drive/v3/files').last.uri.queryParameters;
    expect(listing['corpora'], 'drive');
    expect(listing['driveId'], 'd1');
    await fs.write('/Shared drives/Team/new.txt', Stream.value([1, 2]));
    expect(drive.files.values.singleWhere((f) => f.name == 'new.txt').parents, ['d1']);
  });

  test('a refused token is renewed; rate limits wait; a full Drive says so', () async {
    drive.add('a.txt');
    cloud.validToken = 'token7';
    expect(await names('/My Drive'), ['a.txt']);
    expect(secrets.values['accessToken'], 'token1');

    cloud.faults.add(Fault((s) => s.path.endsWith('/files'),
        status: 403,
        body: jsonEncode({'error': {'code': 403, 'errors': [{'reason': 'userRateLimitExceeded'}]}})));
    expect(await names('/My Drive'), ['a.txt']);
    expect(slept, hasLength(1));

    cloud.faults.add(Fault((s) => s.path.contains('/upload/'),
        status: 403,
        body: jsonEncode({'error': {'code': 403, 'message': 'quota', 'errors': [{'reason': 'storageQuotaExceeded'}]}})));
    await expectLater(fs.write('/My Drive/b.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('Google Drive is full'))));
  });

  test('connect fails plainly when the sign-in is gone', () async {
    final gone = GoogleDriveFileSystem(
      const RemoteConnection(id: 'g2', protocol: RemoteProtocol.googleDrive, name: 'x'),
      MemoryRemoteSecrets({'accessToken': 'nope', 'refreshToken': 'withdrawn'}),
      service: GoogleDriveService(api: '${cloud.base}/drive/v3', oauth: cloud.oauth(clientSecret: 's')),
    );
    await expectLater(gone.connect(),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.auth)));
    await gone.close();
  });
}
