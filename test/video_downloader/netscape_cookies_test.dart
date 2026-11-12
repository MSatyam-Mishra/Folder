import 'package:folders/core/services/video_downloader/netscape_cookies.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = '# Netscape HTTP Cookie File\n'
    '# This is a generated file! Do not edit.\n'
    '\n'
    '.youtube.com\tTRUE\t/\tTRUE\t1893456000\tSAPISID\tabcdef123456\n'
    '#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1893456000\t__Secure-3PSID\tsecret-value-1\n'
    'www.youtube.com\tFALSE\t/feed\tFALSE\t0\tPREF\tf6=40000000\n'
    '.google.com\tTRUE\t/\tTRUE\t1893456000.5\tNID\tgoogle-value\n'
    'not a cookie line\n'
    'accounts.google.com\tFALSE\t/\tTRUE\t\tEMPTY\t\n';

void main() {
  group('parse', () {
    test('reads cookies, HttpOnly lines and odd expiries; skips the rest', () {
      final r = NetscapeCookies.parse(_file);
      expect(r.hasHeader, isTrue);
      expect(r.invalidLines, 1);
      expect(r.cookies.map((c) => c.name),
          ['SAPISID', '__Secure-3PSID', 'PREF', 'NID', 'EMPTY']);
      final secure = r.cookies[1];
      expect(secure.httpOnly, isTrue);
      expect(secure.domain, '.youtube.com');
      expect(secure.includeSubdomains, isTrue);
      final pref = r.cookies[2];
      expect(pref.includeSubdomains, isFalse);
      expect(pref.path, '/feed');
      expect(pref.secure, isFalse);
      expect(pref.expires, 0);
      expect(r.cookies[3].expires, 1893456000, reason: 'decimals dropped');
      expect(r.cookies[4].value, isEmpty);
      expect(r.cookies[4].expires, 0, reason: 'an empty expiry is a session cookie');
    });

    test('tabs turned into spaces still read', () {
      final r = NetscapeCookies.parse('.example.com TRUE / FALSE 0 name some value');
      expect(r.cookies.single.name, 'name');
      expect(r.cookies.single.value, 'some value');
      expect(r.hasHeader, isFalse);
    });

    test('the subdomain flag follows the leading dot', () {
      // TRUE without a dot: yt-dlp (Python) refuses the whole file unless
      // they agree, so the dot is added.
      final c = NetscapeCookies.parse('example.com\tTRUE\t/\tTRUE\t0\ta\tb').cookies.single;
      expect(c.domain, '.example.com');
      expect(c.toLine().split('\t')[1], 'TRUE');
      final host = NetscapeCookies.parse('.example.com\tFALSE\t/\tTRUE\t0\ta\tb').cookies.single;
      expect(host.toLine().split('\t').take(2), ['.example.com', 'TRUE']);
    });

    test('a file of something else is refused, JSON with a hint', () {
      expect(() => NetscapeCookies.parseFile('hello\nworld'),
          throwsA(isA<CookieFormatException>()));
      expect(
        () => NetscapeCookies.parseFile('[{"name": "a", "value": "b"}]'),
        throwsA(isA<CookieFormatException>()
            .having((e) => e.message, 'message', contains('Netscape'))),
      );
    });
  });

  group('write', () {
    test('header first, one line per cookie, and it reads back the same', () {
      final cookies = NetscapeCookies.parse(_file).cookies;
      final text = NetscapeCookies.write(cookies, comment: 'Made by a test');
      final lines = text.split('\n');
      expect(lines.first, NetscapeCookies.header);
      expect(lines[1], '# Made by a test');
      expect(lines, contains('#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1893456000\t__Secure-3PSID\tsecret-value-1'));
      final back = NetscapeCookies.parse(text);
      expect(back.invalidLines, 0);
      expect([for (final c in back.cookies) c.toLine()], [for (final c in cookies) c.toLine()]);
    });

    test('tabs and line breaks never get into a value', () {
      final c = NetscapeCookies.make(domain: '.a.com', name: 'n', value: 'x\ty\nz')!;
      expect(c.toLine().split('\t'), hasLength(7));
      expect(c.value, 'xyz');
      expect(NetscapeCookies.make(domain: '.a.com', name: 'bad name', value: 'v'), isNull);
      expect(NetscapeCookies.make(domain: '', name: 'n', value: 'v'), isNull);
    });

    test('toString never shows the value', () {
      final c = NetscapeCookies.make(domain: '.a.com', name: 'n', value: 'topsecret')!;
      expect('$c', isNot(contains('topsecret')));
    });
  });

  group('Cookie header and pasted text', () {
    test('a header becomes cookies for the site and its subdomains', () {
      final cookies = NetscapeCookies.parseHeader(
        'Cookie: SID=abc; HSID=def==;  empty=; =nameless; bad name=x',
        site: 'youtube.com',
      );
      expect({for (final c in cookies) c.name: c.value}, {'SID': 'abc', 'HSID': 'def==', 'empty': ''});
      expect(cookies.every((c) => c.domain == '.youtube.com' && c.secure), isTrue);
    });

    test('pasted cookies.txt keeps only the site\'s cookies', () {
      final mine = NetscapeCookies.parsePasted(_file, site: 'google.com');
      expect(mine.map((c) => c.name), ['NID', 'EMPTY']);
      expect(
        () => NetscapeCookies.parsePasted(_file, site: 'bilibili.com'),
        throwsA(isA<CookieFormatException>()),
      );
      expect(() => NetscapeCookies.parsePasted('just words', site: 'a.com'),
          throwsA(isA<CookieFormatException>()));
      expect(() => NetscapeCookies.parsePasted('  ', site: 'a.com'),
          throwsA(isA<CookieFormatException>()));
    });
  });

  test('merge: a later source replaces the same cookie', () {
    final a = NetscapeCookies.make(domain: '.a.com', name: 'x', value: 'old')!;
    final b = NetscapeCookies.make(domain: '.a.com', name: 'y', value: 'kept')!;
    final a2 = NetscapeCookies.make(domain: '.A.com', name: 'x', value: 'new')!;
    final otherPath = NetscapeCookies.make(domain: '.a.com', name: 'x', value: 'p', path: '/p')!;
    final merged = NetscapeCookies.merge([
      [a, b],
      [a2, otherPath],
    ]);
    expect({for (final c in merged) '${c.path}${c.name}': c.value}, {'/x': 'new', '/y': 'kept', '/px': 'p'});
  });

  test('sites: domains, groups and the summary', () {
    expect(NetscapeCookies.siteOf('https://www.youtube.com/watch?v=1'), 'youtube.com');
    expect(NetscapeCookies.siteOf('m.facebook.com'), 'facebook.com');
    expect(NetscapeCookies.siteOf('x.com'), 'x.com');
    expect(NetscapeCookies.siteOf('not a site'), isNull);
    expect(NetscapeCookies.siteGroup('accounts.google.com'), 'google.com');
    expect(NetscapeCookies.siteGroup('www.bbc.co.uk'), 'bbc.co.uk');

    final cookies = NetscapeCookies.parse(_file).cookies;
    expect(NetscapeCookies.summary(cookies), '5 cookies for youtube.com and google.com');
    expect(NetscapeCookies.summary(const []), 'No cookies');
    final many = [
      for (final d in ['a.com', 'b.com', 'c.com', 'd.com', 'a.com'])
        NetscapeCookies.make(domain: '.$d', name: 'n${d.hashCode}', value: 'v')!,
    ];
    expect(NetscapeCookies.summary(many), '5 cookies for a.com, b.com and 2 more sites');
  });

  test('isFor and expiry', () {
    final c = NetscapeCookies.make(domain: '.accounts.youtube.com', name: 'n', value: 'v', expires: 100)!;
    expect(c.isFor('youtube.com'), isTrue);
    expect(c.isFor('tube.com'), isFalse);
    expect(c.isExpired(DateTime.now()), isTrue);
    expect(NetscapeCookies.expiryFrom(null), 0);
    expect(NetscapeCookies.expiryFrom(-1), 0);
    expect(NetscapeCookies.expiryFrom(1893456000), 1893456000, reason: 'WebView2: seconds');
    expect(NetscapeCookies.expiryFrom(1893456000123), 1893456000, reason: 'others: milliseconds');
  });
}
