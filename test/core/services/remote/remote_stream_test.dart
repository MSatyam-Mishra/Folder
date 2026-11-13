import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:folders/features/remote/remote_open.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fake_remote.dart';

/// Videos on a place stream to the player through the local content
/// server, which reads the ranges it asks for from the place. (No widget
/// tests here: their binding stubs out HttpClient.)
void main() {
  late FakeRemoteServer server;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RemoteProtocols.clear();
    server = FakeRemoteServer();
    registerFakeProtocol({'': server});
    RemotePlaces.instance.reset(secretStore: MemoryRemoteSecretStore());
    RemotePool.instance = RemotePool(closeIdle: false);
    await RemotePlaces.instance.save(
      const RemoteConnection(id: 'nas', protocol: RemoteProtocol.sftp, name: 'NAS', host: 'nas.local'),
      secrets: {'password': 'secret'},
    );
  });

  tearDown(() => RemotePool.instance.closeAll());

  test('videos stream with ranges through the local server', () async {
    server.addFile('/Movies/clip.mp4', '0123456789abcdef');
    final file = RemoteFile('nas', await RemotePool.instance.run('nas', (fs) => fs.stat('/Movies/clip.mp4')));
    final base = await RemoteOpener.mount(file);
    final url = RemoteOpener.streamUrl(base, file);
    expect(url.pathSegments.last, 'clip.mp4');
    final client = HttpClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=4-9');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 4-9/16');
      expect(await response.transform(const SystemEncoding().decoder).join(), '456789');
      final whole = await (await client.getUrl(url)).close();
      expect(whole.statusCode, 200);
      expect(await whole.transform(const SystemEncoding().decoder).join(), '0123456789abcdef');
    } finally {
      client.close(force: true);
    }
  });
}
