import 'dart:io';

import 'package:folders/core/services/video_downloader/cookie_store.dart';
import 'package:folders/core/services/video_downloader/netscape_cookies.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _imported = '# Netscape HTTP Cookie File\n'
    '.youtube.com\tTRUE\t/\tTRUE\t1893456000\tPREF\tfrom-file-pref\n'
    '.youtube.com\tTRUE\t/\tTRUE\t1893456000\tSAPISID\tfile-sapisid-value\n'
    '.vimeo.com\tTRUE\t/\tTRUE\t1893456000\tvuid\tvimeo-visitor-id\n'
    '.old.com\tTRUE\t/\tTRUE\t1000\texpired\tlong-gone-value\n';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('folders_cookie_store_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<CookieStore> open() async {
    final store = CookieStore();
    await store.open(Directory(p.join(dir.path, 'cookies')));
    return store;
  }

  String merged(CookieStore store) => File(store.cookieFilePath!).readAsStringSync();

  test('import, sign-ins and pasting merge into one cookies.txt for yt-dlp', () async {
    final store = await open();
    expect(store.hasCookies, isFalse);
    expect(File(store.cookieFilePath!).existsSync(), isFalse, reason: 'no file without cookies');
    expect(store.status(CookieSite.youtube).label, 'Login required');

    final result = await store.importText(_imported, fileName: 'cookies.txt');
    expect(result.cookies, hasLength(4));
    expect(result.expired, 1);
    expect(store.imported!.summary, '4 cookies for youtube.com, old.com and vimeo.com');
    expect(store.status(CookieSite.youtube).state, SiteState.fromFile);
    expect(store.status(CookieSite.youtube).label, 'Signed in with the imported file');

    // A sign-in replaces the file's cookie of the same name and adds its own.
    final count = await store.setSiteCookies(
      CookieSite.youtube,
      [
        NetscapeCookies.make(domain: '.youtube.com', name: 'SAPISID', value: 'login-sapisid-value')!,
        NetscapeCookies.make(domain: '.youtube.com', name: 'LOGIN_INFO', value: 'login-info-value')!,
        NetscapeCookies.make(domain: '.google.com', name: 'NID', value: 'not-for-youtube')!,
      ],
      source: CookieSource.login,
    );
    expect(count, 2, reason: "google.com's cookie isn't YouTube's");
    expect(store.status(CookieSite.youtube).state, SiteState.signedIn);
    expect(store.status(CookieSite.youtube).label, 'Signed in · 2 cookies');

    await store.paste(CookieSite.bilibili, 'SESSDATA=bili-session-data; bili_jct=csrf-token-1');
    expect(store.status(CookieSite.bilibili).state, SiteState.signedIn);

    final text = merged(store);
    expect(text.split('\n').first, NetscapeCookies.header);
    final file = NetscapeCookies.parse(text);
    expect(file.invalidLines, 0);
    final values = {for (final c in file.cookies) '${c.host} ${c.name}': c.value};
    expect(values, {
      'youtube.com PREF': 'from-file-pref',
      'youtube.com SAPISID': 'login-sapisid-value',
      'youtube.com LOGIN_INFO': 'login-info-value',
      'vimeo.com vuid': 'vimeo-visitor-id',
      'bilibili.com SESSDATA': 'bili-session-data',
      'bilibili.com bili_jct': 'csrf-token-1',
    }, reason: 'expired cookies left out, the sign-in wins');

    // Kept for the next start.
    final again = await open();
    expect(again.imported!.fileName, 'cookies.txt');
    expect(again.status(CookieSite.youtube).label, 'Signed in · 2 cookies');
    expect(again.cookiesFor(CookieSite.youtube)!.source, CookieSource.login);
    expect(again.merged.length, store.merged.length);

    // Signing out leaves the file's cookies.
    await again.signOut(CookieSite.youtube);
    expect(again.status(CookieSite.youtube).state, SiteState.fromFile);
    expect(merged(again), contains('file-sapisid-value'));
    await again.removeImported();
    await again.signOut(CookieSite.bilibili);
    expect(again.hasCookies, isFalse);
    expect(File(again.cookieFilePath!).existsSync(), isFalse);
  });

  test('added sites are kept, and removing one drops its cookies', () async {
    final store = await open();
    expect(store.addableSites, CookieSite.presets);
    await store.addSite(CookieSite.instagram);
    final vimeo = CookieSite.forUrl('https://vimeo.com/log_in')!;
    expect(vimeo.domain, 'vimeo.com');
    expect(vimeo.loginUrl, 'https://vimeo.com/log_in');
    expect(CookieSite.forUrl('www.youtube.com')!.id, CookieSite.youtube.id);
    expect(CookieSite.forUrl('nonsense'), isNull);
    await store.paste(vimeo, 'vuid=abcdef');
    expect(store.sites.map((s) => s.id), ['youtube', 'bilibili', 'instagram', 'site:vimeo.com']);
    expect(store.addableSites, isNot(contains(CookieSite.instagram)));
    expect(store.status(vimeo).label, '1 cookie saved');

    final again = await open();
    expect(again.sites.map((s) => s.id), ['youtube', 'bilibili', 'instagram', 'site:vimeo.com']);
    await again.removeSite(vimeo);
    expect(again.sites.map((s) => s.id), isNot(contains('site:vimeo.com')));
    expect(again.hasCookies, isFalse);
  });

  test('statuses: no sign-in found, expired', () async {
    final store = await open();
    await store.paste(CookieSite.youtube, 'PREF=f6=4; YSC=visitor');
    expect(store.status(CookieSite.youtube).label, '2 cookies, but no sign-in found');
    await store.setSiteCookies(
      CookieSite.bilibili,
      [NetscapeCookies.make(domain: '.bilibili.com', name: 'SESSDATA', value: 'x', expires: 1000)!],
      source: CookieSource.login,
    );
    expect(store.status(CookieSite.bilibili).state, SiteState.expired);
  });

  test('redact hides every saved value and Cookie headers', () async {
    final store = await open();
    await store.importText(_imported, fileName: 'c.txt');
    final hidden = store.redact(
      'value file-sapisid-value leaked\n'
      'Cookie: a=b; c=d\n'
      'short PREF stays',
    );
    expect(hidden, isNot(contains('file-sapisid-value')));
    expect(hidden, contains('[cookie]'));
    expect(hidden, contains('Cookie: [hidden]'));
    expect(hidden, contains('short PREF stays'));
  });

  test('each run gets its own copy, deleted afterwards', () async {
    final store = await open();
    expect(await CookieStore.runCopy(store.cookieFilePath, 'job-1'), isNull, reason: 'no cookies yet');
    await store.paste(CookieSite.youtube, 'SID=abcdef');
    final copy = await CookieStore.runCopy(store.cookieFilePath, 'job:1/2');
    expect(copy, isNotNull);
    expect(p.basename(copy!), 'job_1_2.txt');
    expect(File(copy).readAsStringSync(), merged(store));
    await CookieStore.deleteRunCopy(copy);
    expect(File(copy).existsSync(), isFalse);
  });

  test('in memory (no folder) it works without a file', () async {
    final store = CookieStore();
    await store.open(null);
    await store.paste(CookieSite.youtube, 'SID=abcdef');
    expect(store.cookieFilePath, isNull);
    expect(store.hasCookies, isTrue);
  });

  test('a file of something else is refused and nothing changes', () async {
    final store = await open();
    await expectLater(
      store.importText('{"cookies": []}', fileName: 'c.json'),
      throwsA(isA<CookieFormatException>()),
    );
    expect(store.imported, isNull);
  });
}
