import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/cloud/dropbox_fs.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

import 'fake_cloud.dart';

class _Entry {
  _Entry(this.path, this.folder, [Uint8List? data]) : data = data ?? Uint8List(0);

  String path;
  final bool folder;
  Uint8List data;
  final id = 'id:${_ids++}';
  static var _ids = 0;

  String get name => path.substring(path.lastIndexOf('/') + 1);

  Map<String, Object?> toJson() => {
        '.tag': folder ? 'folder' : 'file',
        'name': name,
        'path_lower': path.toLowerCase(),
        'path_display': path,
        'id': id,
        if (!folder) ...{
          'size': data.length,
          'client_modified': '2025-05-06T07:08:09Z',
          'server_modified': '2026-01-01T00:00:00Z',
        },
      };
}

/// Dropbox API v2, as far as the app uses it.
class _FakeDropbox {
  late FakeCloud cloud;
  final entries = <String, _Entry>{}; // by lower-case path
  final sessions = <String, BytesBuilder>{};
  final deleted = <String>[];

  /// The n-th append is kept but its answer is lost.
  int dropAppend = 0;
  int _appends = 0;

  _Entry add(String path, {bool folder = false, List<int>? data}) {
    final parent = path.substring(0, path.lastIndexOf('/'));
    if (parent.isNotEmpty && !entries.containsKey(parent.toLowerCase())) add(parent, folder: true);
    return entries[path.toLowerCase()] =
        _Entry(path, folder, Uint8List.fromList(data ?? utf8.encode('${path.substring(path.lastIndexOf('/') + 1)}!')));
  }

  List<_Entry> _children(String folder) => [
        for (final e in entries.values)
          if (e.path.substring(0, e.path.lastIndexOf('/')).toLowerCase() == folder.toLowerCase()) e,
      ];

  Future<void> _error(HttpResponse r, String summary, [Map<String, Object?> error = const {}]) =>
      json(r, {'error_summary': '$summary/..', 'error': error}, status: 409);

  Future<void> handle(Seen s, HttpResponse r) async {
    if (!await cloud.authorized(s, r, body: {'error_summary': 'expired_access_token/', 'error': {'.tag': 'expired_access_token'}})) {
      return;
    }
    final endpoint = s.path.substring(3); // after /2/
    final Map<String, Object?> args;
    if (s.headers.containsKey('dropbox-api-arg')) {
      final header = s.headers['dropbox-api-arg']!;
      expect(header.codeUnits.every((c) => c < 0x7f), isTrue, reason: 'Dropbox-API-Arg must be ASCII');
      args = jsonDecode(header) as Map<String, Object?>;
    } else {
      args = s.body.isEmpty ? const {} : jsonDecode(utf8.decode(s.body)) as Map<String, Object?>;
    }
    switch (endpoint) {
      case 'users/get_current_account':
        return json(r, {'email': 'me@example.com', 'name': {'display_name': 'Me'}});
      case 'files/list_folder':
        final path = args['path'] as String;
        if (path.isNotEmpty && !(entries[path.toLowerCase()]?.folder ?? false)) {
          return _error(r, entries.containsKey(path.toLowerCase()) ? 'path/not_folder' : 'path/not_found');
        }
        return _page(r, path, 0);
      case 'files/list_folder/continue':
        final cursor = utf8.decode(base64.decode(args['cursor'] as String)).split('|');
        return _page(r, cursor[0], int.parse(cursor[1]));
      case 'files/get_metadata':
        final e = entries[(args['path'] as String).toLowerCase()];
        return e == null ? _error(r, 'path/not_found') : json(r, e.toJson());
      case 'files/download':
        final e = entries[(args['path'] as String).toLowerCase()];
        return e == null ? _error(r, 'path/not_found') : ranged(s, r, e.data);
      case 'files/upload':
        return _commit(r, args, s.body);
      case 'files/upload_session/start':
        final sid = 's${sessions.length}';
        sessions[sid] = BytesBuilder()..add(s.body);
        return json(r, {'session_id': sid});
      case 'files/upload_session/append_v2':
      case 'files/upload_session/finish':
        final cursor = args['cursor'] as Map<String, Object?>;
        final session = sessions[cursor['session_id']]!;
        if (cursor['offset'] != session.length) {
          final wrong = {'.tag': 'incorrect_offset', 'correct_offset': session.length};
          return endpoint.endsWith('finish')
              ? _error(r, 'lookup_failed/incorrect_offset', {'.tag': 'lookup_failed', 'lookup_failed': wrong})
              : _error(r, 'incorrect_offset', wrong);
        }
        session.add(s.body);
        if (endpoint.endsWith('finish')) return _commit(r, args['commit'] as Map<String, Object?>, session.toBytes());
        if (++_appends == dropAppend) {
          (await r.detachSocket(writeHeaders: false)).destroy();
          return;
        }
        return json(r, null);
      case 'files/create_folder_v2':
        final path = args['path'] as String;
        if (entries.containsKey(path.toLowerCase())) return _error(r, 'path/conflict/folder');
        return json(r, {'metadata': add(path, folder: true).toJson()});
      case 'files/delete_v2':
        final path = (args['path'] as String).toLowerCase();
        if (!entries.containsKey(path)) return _error(r, 'path_lookup/not_found');
        deleted.add(entries[path]!.path);
        entries.removeWhere((k, _) => k == path || k.startsWith('$path/'));
        return json(r, {'metadata': {}});
      case 'files/move_v2':
        final from = (args['from_path'] as String).toLowerCase();
        final to = args['to_path'] as String;
        if (!entries.containsKey(from)) return _error(r, 'from_lookup/not_found');
        if (entries.containsKey(to.toLowerCase()) && to.toLowerCase() != from) return _error(r, 'to/conflict/file');
        final moved = entries.entries.where((e) => e.key == from || e.key.startsWith('$from/')).toList();
        for (final e in moved) {
          entries.remove(e.key);
        }
        for (final e in moved) {
          e.value.path = to + e.value.path.substring(from.length);
          entries[e.value.path.toLowerCase()] = e.value;
        }
        return json(r, {'metadata': entries[to.toLowerCase()]!.toJson()});
    }
    r.statusCode = 400;
    r.write('Error in call to API function "$endpoint": unknown');
    await r.close();
  }

  Future<void> _page(HttpResponse r, String folder, int from) {
    final all = [
      ..._children(folder).map((e) => e.toJson()),
      {'.tag': 'deleted', 'name': 'gone.txt', 'path_lower': '$folder/gone.txt'},
    ];
    final page = all.skip(from).take(2).toList();
    return json(r, {
      'entries': page,
      'cursor': base64.encode(utf8.encode('$folder|${from + 2}')),
      'has_more': from + 2 < all.length,
    });
  }

  Future<void> _commit(HttpResponse r, Map<String, Object?> commit, Uint8List data) {
    expect(commit['autorename'], isFalse);
    final path = commit['path'] as String;
    final existing = entries[path.toLowerCase()];
    if (existing != null && commit['mode'] != 'overwrite') return _error(r, 'path/conflict/file');
    final e = existing ?? add(path);
    e.data = data;
    if (existing != null && existing.path != path) e.path = path;
    return json(r, e.toJson());
  }
}

void main() {
  late _FakeDropbox box;
  late FakeCloud cloud;
  late DropboxFileSystem fs;
  late MemoryRemoteSecrets secrets;
  final slept = <Duration>[];

  setUp(() async {
    slept.clear();
    box = _FakeDropbox();
    cloud = await FakeCloud(box.handle).start();
    box.cloud = cloud;
    secrets = MemoryRemoteSecrets({'accessToken': 'token0', 'refreshToken': 'refresh0'});
    fs = DropboxFileSystem(
      const RemoteConnection(id: 'd', protocol: RemoteProtocol.dropbox, name: 'Dropbox'),
      secrets,
      service: DropboxService(
        api: '${cloud.base}/2',
        content: '${cloud.base}/2',
        oauth: cloud.oauth(redirectHost: 'localhost', exactPort: true),
      ),
      sleep: (d) async => slept.add(d),
      chunkSize: 128 * 1024,
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

  test('lists folders in pages under the asked names, skipping deleted entries', () async {
    box.add('/Photos/a.jpg');
    box.add('/Photos/b.jpg');
    box.add('/Photos/Trip', folder: true);
    box.add(r'/Photos/back\slash.txt');
    box.add('/notes.txt');
    expect(await names('/'), ['Photos', 'notes.txt']);
    cloud.seen.clear();
    final list = await fs.list('/photos');
    expect([for (final e in list) e.path]..sort(),
        ['/photos/Trip', '/photos/a.jpg', '/photos/b.jpg', '/photos/back\uFF3Cslash.txt']);
    expect(cloud.requests('POST', 'list_folder/continue'), hasLength(2));
    final a = list.firstWhere((e) => e.name == 'a.jpg');
    expect(a.size, 6);
    expect(a.modified, DateTime.utc(2025, 5, 6, 7, 8, 9));
    expect(a.remoteId, startsWith('id:'));
    expect(utf8.decode(await read('/Photos/back\uFF3Cslash.txt')), r'back\slash.txt!');
    await expectLater(fs.list('/notes.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    await expectLater(fs.list('/nothing'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
  });

  test('stat', () async {
    box.add('/a/b.txt', data: sample(10));
    expect((await fs.stat('/')).isDirectory, isTrue);
    expect((await fs.stat('/a')).isDirectory, isTrue);
    expect((await fs.stat('/a/b.txt')).size, 10);
    await expectLater(fs.stat('/a/c.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
  });

  test('downloads all or part, with names beyond ASCII in the header', () async {
    final data = sample(3000);
    box.add('/café ☕/日本.bin', data: data);
    expect(await read('/café ☕/日本.bin'), data);
    expect(await read('/café ☕/日本.bin', start: 5, end: 9), data.sublist(5, 9));
    expect(cloud.seen.last.headers['dropbox-api-arg'], contains(r'\u2615'));
    expect(cloud.seen.last.headers['range'], 'bytes=5-8');
    expect(DropboxService.headerArg({'path': '/\u{1F600}'}), r'{"path":"/\ud83d\ude00"}');
  });

  test('small uploads: add fails on a taken name, overwrite replaces', () async {
    await fs.write('/a.txt', Stream.value(utf8.encode('one')), length: 3);
    expect(utf8.decode(box.entries['/a.txt']!.data), 'one');
    await expectLater(fs.write('/A.TXT', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await fs.write('/a.txt', Stream.value(utf8.encode('two')), overwrite: true);
    expect(utf8.decode(box.entries['/a.txt']!.data), 'two');
    final args = [for (final s in cloud.requests('POST', '/files/upload')) jsonDecode(s.headers['dropbox-api-arg']!)];
    expect(args.last['mode'], 'overwrite');
    expect(args.last['mute'], isTrue);
    expect(args.first['strict_conflict'], isTrue);
  });

  test('big uploads in a session, sized or not, and after a dropped append', () async {
    final data = sample(300 * 1024, 2);
    final sent = <int>[];
    await fs.write('/big.bin', pieces(data), length: data.length, onProgress: sent.add);
    expect(box.entries['/big.bin']!.data, data);
    expect(cloud.requests('POST', 'upload_session/start'), hasLength(1));
    expect(cloud.requests('POST', 'upload_session/append_v2'), hasLength(1));
    expect(cloud.requests('POST', 'upload_session/finish'), hasLength(1));
    expect(sent, [131072, 262144, 307200]);

    await fs.write('/unsized.bin', pieces(data));
    expect(box.entries['/unsized.bin']!.data, data);

    // The answer to an append is lost: sent again, Dropbox says it has it.
    cloud.seen.clear();
    box.dropAppend = box._appends + 1;
    await fs.write('/dropped.bin', pieces(data), length: data.length);
    expect(box.entries['/dropped.bin']!.data, data);
    expect(cloud.requests('POST', 'upload_session/append_v2'), hasLength(3));

    cloud.seen.clear();
    await expectLater(fs.write('/big.bin', pieces(data), length: data.length),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    expect(cloud.requests('POST', 'upload_session/start'), isEmpty, reason: 'checked before sending');
  });

  test('folders: make, move, rename and delete', () async {
    await fs.createDirectory('/A');
    await expectLater(fs.createDirectory('/a'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    box.add('/x.txt');
    box.add('/y.txt');
    await fs.rename('/x.txt', '/A/z.txt');
    expect(await names('/A'), ['z.txt']);
    await expectLater(fs.rename('/y.txt', '/A/z.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
    await expectLater(fs.rename('/nope.txt', '/n.txt'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
    await fs.rename('/A/z.txt', '/A/Z.txt');
    expect(await names('/A'), ['Z.txt']);
    expect(cloud.requests('POST', 'move_v2'), hasLength(5));
    await fs.delete('/A');
    expect(box.deleted, ['/A']);
    expect(await names('/'), ['y.txt']);
    await expectLater(fs.delete('/'),
        throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.unsupported)));
  });

  test('an expired token is renewed; busy answers wait; a full Dropbox says so', () async {
    box.add('/a.txt');
    cloud.validToken = 'token5';
    expect(await names('/'), ['a.txt']);
    expect(secrets.values['accessToken'], 'token1');

    cloud.faults.add(Fault((s) => s.path.endsWith('list_folder'), status: 429, headers: {'retry-after': '3'}));
    cloud.faults.add(Fault((s) => s.path.endsWith('create_folder_v2'),
        status: 409, body: jsonEncode({'error_summary': 'too_many_write_operations/..'})));
    expect(await names('/'), ['a.txt']);
    await fs.createDirectory('/B');
    expect(slept.first, const Duration(seconds: 3));
    expect(slept, hasLength(2));

    cloud.faults.add(Fault((s) => s.path.endsWith('/upload'),
        status: 409, body: jsonEncode({'error_summary': 'path/insufficient_space/..'})));
    await expectLater(fs.write('/c.txt', Stream.value([1])),
        throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('Dropbox is full'))));
  });
}
