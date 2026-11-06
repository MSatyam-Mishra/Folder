import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:folders/core/services/file_server/http_file_server.dart';
import 'package:folders/core/services/file_server/zip_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeResources implements FileServerResources {
  @override
  String get folderIcon => 'folder';

  @override
  String iconFor(String name, {required bool dark}) => dark ? 'd' : 'l';

  @override
  Future<String?> iconSvg(String id) async =>
      id == 'l' || id == 'folder' ? '<svg/>' : null;

  @override
  Future<Uint8List?> font() async => null;

  @override
  Future<Uint8List?> thumbnail(File file, int size) async =>
      Uint8List.fromList([0xFF, 0xD8, size & 0xFF]);
}

void main() {
  late Directory temp;
  late Directory shared;
  late HttpFileServer server;
  late HttpClient client;
  late Uri base;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('file_server_test');
    shared = await Directory(p.join(temp.path, 'Shared')).create();
    await File(p.join(temp.path, 'secret.txt')).writeAsString('secret');
    await File(p.join(shared.path, 'hello.txt')).writeAsString('hello world');
    await File(p.join(shared.path, 'photo.jpg')).writeAsBytes([1, 2, 3]);
    await File(p.join(shared.path, "R&D 'notes'.txt")).writeAsString('x');
    await File(p.join(shared.path, '.hidden')).writeAsString('h');
    await File(p.join(shared.path, 'index.html')).writeAsString('<p>mine</p>');
    final sub = await Directory(p.join(shared.path, 'Sub folder')).create();
    await File(p.join(sub.path, 'ünïcode.md')).writeAsString('# hi');
    await Directory(p.join(sub.path, 'empty')).create();

    server = HttpFileServer(resources: _FakeResources());
    await server.start(shared.path, theme: WebTheme.fallback, port: 0);
    base = Uri.parse(server.url!).replace(host: '127.0.0.1');
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await temp.delete(recursive: true);
  });

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
    bool follow = true,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    request.followRedirects = follow;
    headers.forEach(request.headers.set);
    if (body != null) request.add(body);
    return request.close();
  }

  Future<String> text(HttpClientResponse r) => utf8.decodeStream(r);

  Future<List<int>> bytes(HttpClientResponse r) async =>
      (await r.toList()).expand((c) => c).toList();

  test(
    'lists the folder as a page, never serving index.html instead',
    () async {
      final response = await send('GET', '/', headers: {'accept': 'text/html'});
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/html');
      final html = await text(response);
      expect(html, contains('<h1>Shared</h1>'));
      expect(html, contains('data-name="hello.txt"'));
      expect(html, contains('data-name="index.html"'));
      expect(html, contains('href="Sub%20folder/"'));
      expect(html, contains('R&amp;D &#39;notes&#39;.txt'));
      expect(html, isNot(contains("R&D 'notes'")));
      expect(html, contains('data-hidden="1"'));
      expect(html, contains('data-upload="0"'));
      expect(html, contains('1 folder'));
      expect(html, contains('photo.jpg?thumb=360'));
    },
  );

  test('shares only the chosen items, read-only', () async {
    await server.start(
      shared.path,
      theme: WebTheme.fallback,
      port: 0,
      only: [p.join(shared.path, 'hello.txt'), p.join(shared.path, 'Sub folder')],
    );
    base = Uri.parse(server.url!).replace(host: '127.0.0.1');
    final html = await text(await send('GET', '/', headers: {'accept': 'text/html'}));
    expect(html, contains('data-name="hello.txt"'));
    expect(html, contains('href="Sub%20folder/"'));
    expect(html, isNot(contains('photo.jpg')));
    expect(html, isNot(contains('index.html')));

    final hidden = await send('GET', '/photo.jpg');
    expect(hidden.statusCode, 404);
    await hidden.drain<void>();
    final inside = await send('GET', '/Sub%20folder/%C3%BCn%C3%AFcode.md');
    expect(inside.statusCode, 200);
    expect(await text(inside), '# hi');

    final archive = ZipDecoder().decodeBytes(await bytes(await send('GET', '/?zip')));
    expect(
      archive.files.where((f) => f.isFile).map((f) => f.name).toSet(),
      {'Shared/hello.txt', 'Shared/Sub folder/ünïcode.md'},
    );

    server.allowUploads = true;
    final upload = await send(
      'POST',
      '/?upload',
      headers: {'x-file-name': 'new.txt'},
      body: utf8.encode('data'),
    );
    expect(upload.statusCode, 403);
    await upload.drain<void>();
  });

  test('redirects folders to their URL with a trailing slash', () async {
    final response = await send('GET', '/Sub%20folder', follow: false);
    expect(response.statusCode, 302);
    expect(response.headers.value('location'), '/Sub%20folder/');
    await response.drain<void>();
  });

  test('streams files, with ranges', () async {
    final whole = await send('GET', '/hello.txt');
    expect(whole.statusCode, 200);
    expect(whole.headers.value('accept-ranges'), 'bytes');
    expect(await text(whole), 'hello world');

    final part = await send(
      'GET',
      '/hello.txt',
      headers: {'range': 'bytes=6-'},
    );
    expect(part.statusCode, 206);
    expect(part.headers.value('content-range'), 'bytes 6-10/11');
    expect(await text(part), 'world');

    final bad = await send(
      'GET',
      '/hello.txt',
      headers: {'range': 'bytes=50-'},
    );
    expect(bad.statusCode, 416);
    await bad.drain<void>();

    final download = await send('GET', '/hello.txt?download');
    expect(
      download.headers.value('content-disposition'),
      startsWith('attachment;'),
    );
    await download.drain<void>();

    final html = await send('GET', '/index.html');
    expect(
      html.headers.value('content-security-policy'),
      startsWith('sandbox'),
    );
    await html.drain<void>();
  });

  test("can't leave the shared folder", () async {
    for (final path in [
      '/..%2Fsecret.txt',
      '/%2E%2E/secret.txt',
      '/Sub%20folder/..%2F..%2Fsecret.txt',
      '/missing.txt',
    ]) {
      final response = await send('GET', path);
      expect(response.statusCode, 404, reason: path);
      expect(await text(response), isNot(contains('secret')), reason: path);
    }
  });

  test('downloads a folder as a ZIP', () async {
    final response = await send('GET', '/?zip');
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, 'application/zip');
    final data = await bytes(response);
    expect(data.length, response.headers.contentLength);
    final archive = ZipDecoder().decodeBytes(data, verify: true);
    final files = {
      for (final f in archive.files)
        if (f.isFile) f.name: utf8.decode(f.content as List<int>),
    };
    expect(files['Shared/hello.txt'], 'hello world');
    expect(files['Shared/Sub folder/ünïcode.md'], '# hi');
    expect(
      archive.files.map((f) => f.name),
      contains('Shared/Sub folder/empty/'),
    );
  });

  test('zip stream length matches its bytes for an empty folder', () async {
    final zip = ZipStream([ZipStreamEntry.directory('Empty', DateTime(1970))]);
    final data = await zip.stream().expand((c) => c).toList();
    expect(data.length, zip.length);
    expect(ZipDecoder().decodeBytes(data).files.single.name, 'Empty/');
  });

  test('uploads only when allowed, without overwriting', () async {
    final denied = await send(
      'POST',
      '/?upload',
      headers: {'x-file-name': 'new.txt'},
      body: utf8.encode('data'),
    );
    expect(denied.statusCode, 403);
    await denied.drain<void>();
    expect(File(p.join(shared.path, 'new.txt')).existsSync(), isFalse);

    server.allowUploads = true;
    final received = <String>[];
    final sub = server.received.listen(received.add);

    final ok = await send(
      'POST',
      '/Sub%20folder/?upload',
      headers: {'x-file-name': Uri.encodeComponent('../héllo.txt')},
      body: utf8.encode('data'),
    );
    expect(ok.statusCode, 201);
    expect(jsonDecode(await text(ok)), {'name': 'héllo.txt'});
    expect(
      File(p.join(shared.path, 'Sub folder', 'héllo.txt')).readAsStringSync(),
      'data',
    );

    final again = await send(
      'POST',
      '/?upload',
      headers: {'x-file-name': 'hello.txt'},
      body: utf8.encode('second'),
    );
    expect(jsonDecode(await text(again)), {'name': 'hello (1).txt'});
    expect(
      File(p.join(shared.path, 'hello.txt')).readAsStringSync(),
      'hello world',
    );

    final crossSite = await send(
      'POST',
      '/?upload',
      headers: {'x-file-name': 'x.txt', 'origin': 'http://evil.example'},
      body: [1],
    );
    expect(crossSite.statusCode, 403);
    await crossSite.drain<void>();

    await Future<void>.delayed(Duration.zero);
    expect(received.map(p.basename), ['héllo.txt', 'hello (1).txt']);
    expect(
      shared.listSync(recursive: true).where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
    await sub.cancel();
  });

  test('serves thumbnails, icons and page assets', () async {
    final thumb = await send('GET', '/photo.jpg?thumb=200');
    expect(thumb.statusCode, 200);
    expect(thumb.headers.contentType?.mimeType, 'image/jpeg');
    expect(await bytes(thumb), [0xFF, 0xD8, 200]);

    final notImage = await send('GET', '/hello.txt?thumb=200');
    expect(notImage.statusCode, 404);
    await notImage.drain<void>();

    for (final path in [
      '/__explorer/app.css',
      '/__explorer/app.js',
      '/__explorer/logo.svg',
      '/__explorer/icon/l.svg',
    ]) {
      final response = await send('GET', path);
      expect(response.statusCode, 200, reason: path);
      expect(await text(response), isNotEmpty, reason: path);
    }
    final missing = await send('GET', '/__explorer/icon/nope.svg');
    expect(missing.statusCode, 404);
    await missing.drain<void>();
  });
}
