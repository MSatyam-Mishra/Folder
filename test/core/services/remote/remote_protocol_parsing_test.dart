import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/ftp/ftp_listing.dart';
import 'package:folders/core/services/remote/webdav/http_auth.dart';

/// What the FTP and WebDAV clients read from servers, without a server.
void main() {
  group('FTP listings', () {
    test('MLSD lines', () {
      final file = parseMlsdLine('type=file;size=1234;modify=20240105123000; notes 1.txt', '/docs')!;
      expect(file.path, '/docs/notes 1.txt');
      expect(file.isDirectory, isFalse);
      expect(file.size, 1234);
      expect(file.modified, DateTime.utc(2024, 1, 5, 12, 30).toLocal());
      final folder = parseMlsdLine('Type=dir;Modify=20240105123000.123; Photos', '/')!;
      expect(folder.path, '/Photos');
      expect(folder.isDirectory, isTrue);
      expect(parseMlsdLine('type=cdir;modify=20240105123000; .', '/'), isNull);
      expect(parseMlsdLine('type=pdir; ..', '/'), isNull);
      // MLST names the whole path.
      expect(parseMlsdLine('type=file;size=3; /a/b.txt', '/a')!.path, '/a/b.txt');
    });

    test('Unix LIST lines', () {
      final now = DateTime(2026, 11, 13);
      final file = parseListLine('-rw-r--r--   1 me    staff     5120 Mar  4 09:15 report final.pdf', '/x', now: now)!;
      expect(file.path, '/x/report final.pdf');
      expect(file.size, 5120);
      expect(file.modified, DateTime(2026, 3, 4, 9, 15));
      final old = parseListLine('drwxr-xr-x 2 1000 1000 4096 Dec 24  2019 Old', '/', now: now)!;
      expect(old.isDirectory, isTrue);
      expect(old.modified, DateTime(2019, 12, 24));
      // December with a time, seen in January: last year's.
      final lastYear = parseListLine('-rw-r--r-- 1 me me 1 Dec 30 23:00 a', '/', now: DateTime(2026, 1, 2))!;
      expect(lastYear.modified!.year, 2025);
      final link = parseListLine('lrwxrwxrwx 1 me me 11 Jan  1 10:00 latest -> releases/v2', '/', now: now)!;
      expect(link.name, 'latest');
      expect(parseListLine('total 24', '/'), isNull);
      expect(parseListLine('drwxr-xr-x 2 me me 4096 Jan  1 10:00 .', '/', now: now), isNull);
    });

    test('Windows LIST lines', () {
      final folder = parseListLine('01-05-24  12:30PM       <DIR>          Projects', '/')!;
      expect(folder.isDirectory, isTrue);
      expect(folder.modified, DateTime(2024, 1, 5, 12, 30));
      final file = parseListLine('11-13-2026  09:05AM              2048 data set.csv', '/w')!;
      expect(file.path, '/w/data set.csv');
      expect(file.size, 2048);
      expect(file.modified, DateTime(2026, 11, 13, 9, 5));
    });

    test('passive mode answers and multi-line replies', () {
      expect(parseEpsv('Entering Extended Passive Mode (|||6446|)'), 6446);
      expect(parsePasv('Entering Passive Mode (192,168,1,5,19,137)'), ('192.168.1.5', 19 * 256 + 137));
      const feat = FtpReply(211, ['211-Features:', ' MLST type*;size*;', ' UTF8', '211 End']);
      expect(feat.isOk, isTrue);
      expect(feat.message, contains('UTF8'));
      expect(const FtpReply(150, ['150 Opening']).isPreliminary, isTrue);
      expect(const FtpReply(350, ['350 Ready']).isIntermediate, isTrue);
      expect(const FtpReply(550, ['550 No such file']).message, 'No such file');
    });
  });

  group('HTTP sign-in', () {
    test('challenges, Digest first', () {
      final challenges = HttpChallenge.parseAll([
        'Basic realm="files"',
        'Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"',
      ]);
      expect(challenges.map((c) => c.scheme), ['digest', 'basic']);
      expect(challenges.first.params['nonce'], 'dcd98b7102dd2f0e8b11d0f600bfb0c093');
      expect(challenges.first.params['qop'], 'auth,auth-int');
      expect(HttpChallenge.parseAll(['Digest realm="a", nonce="b", Basic realm="c"']).map((c) => c.scheme), ['digest', 'basic']);
    });

    test("Digest answers RFC 2617's example", () {
      final auth = HttpAuthenticator('Mufasa', 'Circle Of Life', cnonce: () => '0a4f113b');
      expect(auth.authorization('GET', '/dir/index.html'), isNull);
      expect(
        auth.accept(HttpChallenge.parseAll([
          'Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41"',
        ])),
        isTrue,
      );
      final header = auth.authorization('GET', '/dir/index.html')!;
      expect(header, startsWith('Digest '));
      expect(header, contains('response="6629fae49393a05397450978507c4ef1"'));
      expect(header, contains('nc=00000001'));
      expect(header, contains('opaque="5ccc069c403ebaf9f0171e9517f40e41"'));
      // The count goes up with each request.
      expect(auth.authorization('GET', '/dir/index.html'), contains('nc=00000002'));
    });

    test('Basic', () {
      final auth = HttpAuthenticator('me', 'pässword');
      auth.accept(HttpChallenge.parseAll(['Basic realm="x"']));
      expect(auth.authorization('PROPFIND', '/'), 'Basic bWU6cMOkc3N3b3Jk');
      expect(HttpAuthenticator('a', 'b').accept(HttpChallenge.parseAll(['Bearer realm="x"'])), isFalse);
    });
  });
}
