import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/cloud/cloud_http.dart';
import 'package:folders/core/services/remote/cloud/cloud_oauth.dart';
import 'package:folders/core/services/remote/cloud/cloud_service.dart';
import 'package:folders/core/services/remote/cloud/dropbox_fs.dart';
import 'package:folders/core/services/remote/cloud/google_drive_fs.dart';
import 'package:folders/core/services/remote/cloud/onedrive_fs.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_registry.dart';

import 'fake_cloud.dart';

void main() {
  late FakeCloud cloud;
  final slept = <Duration>[];
  Future<void> sleep(Duration d) async => slept.add(d);

  // What the fake "service" answers: /ok counts calls; /authorize signs in.
  var deny = false;
  var codeCount = 0;
  Future<void> handler(Seen s, HttpResponse response) async {
    switch (s.path) {
      case '/authorize':
        final q = s.uri.queryParameters;
        final back = Uri.parse(q['redirect_uri']!);
        if (deny) {
          response.statusCode = 302;
          response.headers.set('location', back.replace(queryParameters: {'error': 'access_denied', 'state': q['state']}).toString());
          return response.close();
        }
        final code = 'code${codeCount++}';
        cloud.codes[code] = (q['code_challenge']!, q['redirect_uri']!);
        response.statusCode = 302;
        response.headers.set('location', back.replace(queryParameters: {'code': code, 'state': q['state']}).toString());
        return response.close();
      case '/drive/v3/about':
        if (!await cloud.authorized(s, response)) return;
        return json(response, {
          'user': {'emailAddress': 'me@example.com', 'displayName': 'Me'},
        });
      case '/v1.0/me':
        if (!await cloud.authorized(s, response)) return;
        return json(response, {'displayName': 'Work Me', 'mail': null, 'userPrincipalName': 'me@work.example'});
      case '/2/users/get_current_account':
        if (!await cloud.authorized(s, response)) return;
        return json(response, {
          'email': 'box@example.com',
          'name': {'display_name': 'Box Me'},
        });
      case '/ok':
        if (!await cloud.authorized(s, response)) return;
        return json(response, {'ok': true});
    }
    response.statusCode = 404;
    await response.close();
  }

  setUp(() async {
    slept.clear();
    deny = false;
    cloud = await FakeCloud(handler).start();
  });
  tearDown(() => cloud.close());

  CloudHttp client({CloudAuth? auth}) => CloudHttp(
        service: 'Fake',
        auth: auth,
        sleep: sleep,
        errorOf: (status, body) => RemoteException(RemoteErrorKind.other, 'error $status'),
      );

  group('CloudHttp', () {
    test('waits as long as Retry-After says, then tries again', () async {
      cloud.validToken = null;
      cloud.faults.add(Fault((s) => s.path == '/ok', status: 429, headers: {'retry-after': '2'}, times: 2));
      final http = client();
      final response = await http.send('GET', Uri.parse('${cloud.base}/ok'), authorized: false);
      expect(response.json['ok'], isTrue);
      expect(slept, [const Duration(seconds: 2), const Duration(seconds: 2)]);
      expect(cloud.requests('GET', '/ok'), hasLength(3));
      http.close();
    });

    test('backs off on 503, gives up after five tries, and asks to come back for long waits', () async {
      cloud.validToken = null;
      cloud.faults.add(Fault((s) => s.path == '/ok', status: 503, times: 99));
      final http = client();
      await expectLater(http.send('GET', Uri.parse('${cloud.base}/ok'), authorized: false),
          throwsA(isA<RemoteException>().having((e) => e.message, 'message', 'error 503')));
      expect(cloud.requests('GET', '/ok'), hasLength(6));
      expect(slept.first, greaterThanOrEqualTo(const Duration(seconds: 1)));
      expect(slept.last, greaterThanOrEqualTo(const Duration(seconds: 16)));

      cloud.faults
        ..clear()
        ..add(Fault((s) => s.path == '/ok', status: 429, headers: {'retry-after': '600'}));
      await expectLater(
          http.send('GET', Uri.parse('${cloud.base}/ok'), authorized: false),
          throwsA(isA<RemoteException>()
              .having((e) => e.message, 'message', contains('Try again in 10 minutes'))));
      http.close();
    });

    test('only tries a server error again when the request is safe to repeat', () async {
      cloud.validToken = null;
      cloud.faults.add(Fault((s) => s.path == '/ok', status: 500));
      final http = client();
      await expectLater(
          http.send('POST', Uri.parse('${cloud.base}/ok'), authorized: false, idempotent: false),
          throwsA(isA<RemoteException>().having((e) => e.message, 'message', 'error 500')));
      cloud.faults.add(Fault((s) => s.path == '/ok', status: 500));
      final response = await http.send('GET', Uri.parse('${cloud.base}/ok'), authorized: false);
      expect(response.statusCode, 200);
      http.close();
    });

    test('a dropped connection or a host that is not there is a network error', () async {
      cloud.validToken = null;
      cloud.faults.add(Fault((s) => s.path == '/ok', drop: true, times: 99));
      final http = client();
      await expectLater(
          http.send('GET', Uri.parse('${cloud.base}/ok'), authorized: false),
          throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.network)));
      expect(cloud.requests('GET', '/ok'), hasLength(6));

      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      await expectLater(
          http.send('POST', Uri.parse('http://127.0.0.1:$port/x'), authorized: false, idempotent: false),
          throwsA(isA<RemoteException>()
              .having((e) => e.kind, 'kind', RemoteErrorKind.network)
              .having((e) => e.message, 'message', contains("Couldn't reach Fake"))));
      http.close();
    });
  });

  group('CloudTokenStore', () {
    CloudTokenStore store(Map<String, String> secrets) =>
        CloudTokenStore(MemoryRemoteSecrets(secrets), CloudOAuth(cloud.oauth(), sleep: sleep));

    test('renews an expired token first and writes the new one back', () async {
      final secrets = MemoryRemoteSecrets({
        'accessToken': 'old',
        'refreshToken': 'refresh0',
        'tokenExpiry': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String(),
      });
      final tokens = CloudTokenStore(secrets, CloudOAuth(cloud.oauth(), sleep: sleep));
      final http = client(auth: tokens);
      // Three at once: one renewal.
      await Future.wait([for (var i = 0; i < 3; i++) http.send('GET', Uri.parse('${cloud.base}/ok'))]);
      expect(cloud.requests('POST', '/token'), hasLength(1));
      expect(secrets.values['accessToken'], 'token1');
      expect(secrets.values['refreshToken'], 'refresh0');
      expect(DateTime.parse(secrets.values['tokenExpiry']!).isAfter(DateTime.now().add(const Duration(minutes: 50))),
          isTrue);
      http.close();
    });

    test('renews once when the token is refused, keeping a rotated refresh token', () async {
      cloud.rotateRefresh = true;
      final secrets = MemoryRemoteSecrets({'accessToken': 'revoked', 'refreshToken': 'refresh0'});
      final http = client(auth: CloudTokenStore(secrets, CloudOAuth(cloud.oauth(), sleep: sleep)));
      final response = await http.send('GET', Uri.parse('${cloud.base}/ok'));
      expect(response.statusCode, 200);
      expect(cloud.requests('GET', '/ok').map((s) => s.headers['authorization']), ['Bearer revoked', 'Bearer token1']);
      expect(secrets.values['refreshToken'], 'refresh1');
      http.close();
    });

    test('a refused refresh token, or a token refused twice, asks to sign in again', () async {
      final http = client(auth: store({'accessToken': 'revoked', 'refreshToken': 'withdrawn'}));
      await expectLater(
          http.send('GET', Uri.parse('${cloud.base}/ok')),
          throwsA(isA<RemoteException>()
              .having((e) => e.kind, 'kind', RemoteErrorKind.auth)
              .having((e) => e.message, 'message', contains('expired or was withdrawn'))));

      cloud.seen.clear();
      cloud.faults.add(Fault((s) => s.path == '/ok', status: 401, times: 2));
      final again = client(auth: store({'accessToken': 'token0', 'refreshToken': 'refresh0'}));
      await expectLater(again.send('GET', Uri.parse('${cloud.base}/ok')),
          throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.auth)));
      expect(cloud.requests('POST', '/token'), hasLength(1));

      expect(() => store({}).load(), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.auth)));
      http.close();
      again.close();
    });
  });

  group('signing in', () {
    test('Google Drive: PKCE through the browser and back, then who signed in', () async {
      final service = GoogleDriveService(api: '${cloud.base}/drive/v3', oauth: cloud.oauth(clientSecret: 'secret'));
      final flow = CloudSignInFlow(service, sleep: sleep);
      Uri? opened;
      final result = await flow.run(openBrowser: (url) {
        opened = url;
        return fakeBrowser(url);
      });
      expect(result, isNotNull);
      expect(result!.name, 'Google Drive (me@example.com)');
      expect(result.username, 'me@example.com');
      expect(result.options, {'accountEmail': 'me@example.com', 'accountName': 'Me'});
      expect(result.secrets['accessToken'], 'token1');
      expect(result.secrets['refreshToken'], 'refresh1');
      expect(DateTime.tryParse(result.secrets['tokenExpiry']!), isNotNull);

      final q = opened!.queryParameters;
      expect(q['client_id'], 'client');
      expect(q['code_challenge_method'], 'S256');
      expect(q['redirect_uri'], startsWith('http://127.0.0.1:'));
      expect(q['scope'], 'files');
      final token = Uri.splitQueryString(String.fromCharCodes(cloud.requests('POST', '/token').single.body));
      expect(token['client_secret'], 'secret');
      expect(token['grant_type'], 'authorization_code');
    });

    test('OneDrive comes back to localhost and names the place by the account', () async {
      final service = OneDriveService(graph: '${cloud.base}/v1.0', oauth: cloud.oauth(redirectHost: 'localhost'));
      final result = await CloudSignInFlow(service, sleep: sleep).run(openBrowser: fakeBrowser);
      expect(result!.name, 'OneDrive (me@work.example)');
      expect(result.options['accountName'], 'Work Me');
    });

    test('Dropbox needs its exact port: busy means an error, free means signed in', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final taken = DropboxService(
          api: '${cloud.base}/2', oauth: cloud.oauth(redirectHost: 'localhost', exactPort: true, redirectPort: busy.port));
      await expectLater(
          CloudSignInFlow(taken).run(openBrowser: fakeBrowser),
          throwsA(isA<RemoteException>().having((e) => e.message, 'message', contains('port ${busy.port}'))));

      // Without the exact port rule another one is picked.
      final google = GoogleDriveService(
          api: '${cloud.base}/drive/v3', oauth: cloud.oauth(clientSecret: 's', redirectPort: busy.port));
      expect((await CloudSignInFlow(google, sleep: sleep).run(openBrowser: fakeBrowser))!.username, 'me@example.com');

      final port = busy.port;
      await busy.close();
      final free = DropboxService(
          api: '${cloud.base}/2', oauth: cloud.oauth(redirectHost: 'localhost', exactPort: true, redirectPort: port));
      final result = await CloudSignInFlow(free, sleep: sleep).run(openBrowser: (url) {
        expect(url.queryParameters['redirect_uri'], 'http://localhost:$port/');
        return fakeBrowser(url);
      });
      expect(result!.name, 'Dropbox (box@example.com)');
    });

    test('declining in the browser, cancelling and taking too long', () async {
      final service = GoogleDriveService(api: '${cloud.base}/drive/v3', oauth: cloud.oauth(clientSecret: 's'));
      deny = true;
      expect(await CloudSignInFlow(service).run(openBrowser: fakeBrowser), isNull);
      deny = false;

      final flow = CloudSignInFlow(service);
      final waiting = flow.run(openBrowser: (url) async => true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      flow.cancel();
      expect(await waiting, isNull);

      await expectLater(
          CloudSignInFlow(service).run(openBrowser: (url) async => true, timeout: const Duration(milliseconds: 100)),
          throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.cancelled)));
      expect(cloud.requests('POST', '/token'), isEmpty);
    });

    test('a stale page from an earlier try is turned away and the real one still works', () async {
      final service = GoogleDriveService(api: '${cloud.base}/drive/v3', oauth: cloud.oauth(clientSecret: 's'));
      final result = await CloudSignInFlow(service, sleep: sleep).run(openBrowser: (url) async {
        final back = Uri.parse(url.queryParameters['redirect_uri']!);
        final client = HttpClient();
        final response = await (await client.getUrl(back.replace(queryParameters: {'code': 'x', 'state': 'old'}))).close();
        expect(response.statusCode, 400);
        await response.drain<void>();
        client.close();
        return fakeBrowser(url);
      });
      expect(result, isNotNull);
    });

    test('a build without the ids offers none of the services', () {
      RemoteProtocols.clear();
      registerRemoteProtocols();
      expect(RemoteProtocols.all.map((p) => p.protocol),
          containsAll([RemoteProtocol.googleDrive, RemoteProtocol.oneDrive, RemoteProtocol.dropbox]));
      for (final p in [RemoteProtocol.googleDrive, RemoteProtocol.oneDrive, RemoteProtocol.dropbox]) {
        final info = RemoteProtocols.of(p)!;
        expect(info.available, isFalse, reason: p.name);
        expect(info.needsHost, isFalse);
        expect(info.usesPassword, isFalse);
        expect(info.signIn, isNotNull);
        expect(info.deleteNote, isNotEmpty);
      }
      RemoteProtocols.clear();
    });
  });

  test('tokens from JSON, and back to secrets', () {
    final now = DateTime.utc(2026, 11, 13, 12);
    final t = CloudTokens.fromJson({'access_token': 'a', 'refresh_token': 'r', 'expires_in': '3600'}, now: now);
    expect(t.toSecrets(), {'accessToken': 'a', 'refreshToken': 'r', 'tokenExpiry': '2026-11-13T13:00:00.000Z'});
    expect(() => CloudTokens.fromJson({}), throwsA(isA<RemoteException>()));
  });

  test('pieces of a stream, and part of one', () async {
    final data = sample(1000);
    final reader = ChunkReader(pieces(data, 77));
    expect((await reader.next(300)).length, 300);
    expect(await reader.atEnd(), isFalse);
    expect((await reader.next(800)).length, 700);
    expect(await reader.atEnd(), isTrue);
    expect(reader.position, 1000);
    final part = await sliceBytes(pieces(data, 64), 100, 250).expand((c) => c).toList();
    expect(part, data.sublist(100, 250));
  });
}
