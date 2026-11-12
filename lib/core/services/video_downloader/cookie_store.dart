import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'netscape_cookies.dart';

/// A site the user can sign in to for the downloader.
class CookieSite {
  const CookieSite({
    required this.id,
    required this.name,
    required this.domain,
    required this.loginUrl,
    this.loginCookies = const [],
    this.builtIn = false,
  });

  final String id;
  final String name;

  /// E.g. "youtube.com"; its cookies and its subdomains' are the site's.
  final String domain;

  /// Where signing in starts.
  final String loginUrl;

  /// Cookies only a signed-in session has; empty when unknown.
  final List<String> loginCookies;

  /// Always listed (YouTube, Bilibili); others are added by the user.
  final bool builtIn;

  static const youtube = CookieSite(
    id: 'youtube',
    name: 'YouTube',
    domain: 'youtube.com',
    loginUrl: 'https://accounts.google.com/ServiceLogin?service=youtube'
        '&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2F'
        'signin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F',
    loginCookies: ['SAPISID', '__Secure-3PAPISID', '__Secure-1PSID', 'LOGIN_INFO'],
    builtIn: true,
  );

  static const bilibili = CookieSite(
    id: 'bilibili',
    name: 'Bilibili',
    domain: 'bilibili.com',
    loginUrl: 'https://passport.bilibili.com/login',
    loginCookies: ['SESSDATA'],
    builtIn: true,
  );

  static const instagram = CookieSite(
    id: 'instagram',
    name: 'Instagram',
    domain: 'instagram.com',
    loginUrl: 'https://www.instagram.com/accounts/login/',
    loginCookies: ['sessionid'],
  );

  static const x = CookieSite(
    id: 'x',
    name: 'X (Twitter)',
    domain: 'x.com',
    loginUrl: 'https://x.com/i/flow/login',
    loginCookies: ['auth_token'],
  );

  static const facebook = CookieSite(
    id: 'facebook',
    name: 'Facebook',
    domain: 'facebook.com',
    loginUrl: 'https://www.facebook.com/login/',
    loginCookies: ['c_user'],
  );

  static const tiktok = CookieSite(
    id: 'tiktok',
    name: 'TikTok',
    domain: 'tiktok.com',
    loginUrl: 'https://www.tiktok.com/login',
    loginCookies: ['sessionid'],
  );

  static const builtInSites = [youtube, bilibili];

  /// Offered when adding a site.
  static const presets = [instagram, x, facebook, tiktok];

  /// The site of a link the user typed, e.g. "vimeo.com/log_in"; a preset
  /// or built-in site when it's one of those. Null when it isn't a link.
  static CookieSite? forUrl(String input) {
    final domain = NetscapeCookies.siteOf(input);
    if (domain == null) return null;
    for (final site in [...builtInSites, ...presets]) {
      if (site.domain == domain) return site;
    }
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    final hasPage = uri != null && (uri.path.length > 1 || uri.hasQuery);
    return CookieSite(
      id: 'site:$domain',
      name: domain,
      domain: domain,
      loginUrl: hasPage && (uri.scheme == 'https' || uri.scheme == 'http')
          ? uri.toString()
          : 'https://$domain/',
    );
  }

  /// Pages whose cookies are read after signing in.
  List<String> get cookieUrls => [
        'https://www.$domain/',
        'https://$domain/',
        if (id == youtube.id) 'https://m.youtube.com/',
      ];

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'domain': domain,
        'loginUrl': loginUrl,
        'loginCookies': loginCookies,
      };

  static CookieSite? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final domain = json['domain'];
    final loginUrl = json['loginUrl'];
    if (id is! String || name is! String || domain is! String || loginUrl is! String) {
      return null;
    }
    return CookieSite(
      id: id,
      name: name,
      domain: domain,
      loginUrl: loginUrl,
      loginCookies: [
        for (final c in (json['loginCookies'] as List?) ?? const []) if (c is String) c,
      ],
    );
  }
}

/// How the user's cookies for a site came.
enum CookieSource { login, pasted }

/// The cookies kept for one site.
class SiteCookies {
  const SiteCookies(this.cookies, {required this.source, required this.updatedAt});

  final List<NetscapeCookie> cookies;
  final CookieSource source;
  final DateTime updatedAt;
}

/// A cookies.txt file the user imported.
class ImportedCookies {
  const ImportedCookies(this.cookies, {required this.fileName, required this.importedAt});

  final List<NetscapeCookie> cookies;
  final String fileName;
  final DateTime importedAt;

  String get summary => NetscapeCookies.summary(cookies);
}

enum SiteState {
  /// A sign-in cookie was found among the site's own cookies.
  signedIn,

  /// Cookies saved, but none that shows a sign-in (or it's not known which
  /// would).
  cookies,

  /// Only the imported file has cookies for it.
  fromFile,

  /// Saved cookies, all expired.
  expired,
  none,
}

class SiteStatus {
  const SiteStatus(this.state, this.label, {this.count = 0});

  final SiteState state;
  final String label;

  /// The site's own cookies (not the imported file's).
  final int count;

  bool get hasOwnCookies => count > 0;
}

/// What an import found.
class ImportResult {
  const ImportResult(this.cookies, {this.invalidLines = 0, this.expired = 0});

  final List<NetscapeCookie> cookies;
  final int invalidLines;
  final int expired;

  String get summary => NetscapeCookies.summary(cookies);
}

/// The downloader's cookies: an imported cookies.txt file and each site's
/// sign-in, kept in app-private storage and merged into one cookies.txt
/// file for yt-dlp (`--cookies`). Cookie values are never logged: use
/// [redact] on anything written to the log.
class CookieStore extends ChangeNotifier {
  CookieStore();

  static const _storeName = 'cookie_store.json';
  static const mergedName = 'cookies.txt';
  static const _runFolder = 'run';

  Directory? _dir;
  final _custom = <CookieSite>[];
  final _sites = <String, SiteCookies>{};
  ImportedCookies? _imported;
  RegExp? _redactor;
  Future<void> _writing = Future.value();
  DateTime Function() now = DateTime.now;

  /// Where the cookies are kept; null in memory only (tests).
  Directory? get directory => _dir;

  ImportedCookies? get imported => _imported;

  /// YouTube, Bilibili and the sites the user added.
  List<CookieSite> get sites => [...CookieSite.builtInSites, ..._custom];

  /// Presets not added yet.
  List<CookieSite> get addableSites => [
        for (final site in CookieSite.presets)
          if (!_custom.any((c) => c.id == site.id)) site,
      ];

  SiteCookies? cookiesFor(CookieSite site) => _sites[site.id];

  /// The merged file to hand to yt-dlp. It exists only while there are
  /// cookies; null when they aren't kept on disk.
  String? get cookieFilePath => _dir == null ? null : p.join(_dir!.path, mergedName);

  /// Every cookie yt-dlp gets: the imported file's, replaced by a site's
  /// own where both have one; expired ones are left out.
  List<NetscapeCookie> get merged {
    final time = now();
    return NetscapeCookies.merge([
      _imported?.cookies ?? const [],
      for (final site in _sites.values) site.cookies,
    ]).where((c) => !c.isExpired(time)).toList();
  }

  bool get hasCookies => merged.isNotEmpty;

  /// Loads what was saved in [dir] (null: memory only).
  Future<void> open(Directory? dir) async {
    _dir = dir;
    if (dir == null) return;
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        await _restrict(dir);
      }
      final file = File(p.join(dir.path, _storeName));
      if (await file.exists()) _fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('Video downloader: the saved cookies could not be read ($e)');
    }
    _rebuildRedactor();
    unawaited(_sweepRunCopies(dir));
    notifyListeners();
    try {
      await _writeMerged();
    } catch (_) {}
  }

  /// Only the user may read the folder (Linux and macOS; Android's app
  /// storage and Windows' profile are private already).
  static Future<void> _restrict(Directory dir) async {
    if (Platform.isWindows || Platform.isAndroid) return;
    try {
      await Process.run('chmod', ['700', dir.path]);
    } catch (_) {}
  }

  /// Copies left by runs that never ended (the app was killed).
  static Future<void> _sweepRunCopies(Directory dir) async {
    try {
      final run = Directory(p.join(dir.path, _runFolder));
      if (!await run.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final entity in run.list()) {
        if (entity is File && (await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  /// A copy of [cookieFile] for one yt-dlp run, which writes the file back
  /// when it ends, so runs mustn't share one. Null when there are no
  /// cookies. Delete it with [deleteRunCopy] once the run is over.
  static Future<String?> runCopy(String? cookieFile, String runId) async {
    if (cookieFile == null) return null;
    final source = File(cookieFile);
    if (!await source.exists()) return null;
    final dir = Directory(p.join(p.dirname(cookieFile), _runFolder));
    await dir.create(recursive: true);
    final name = runId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return (await source.copy(p.join(dir.path, '$name.txt'))).path;
  }

  static Future<void> deleteRunCopy(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Imports a cookies.txt file's [text]. Throws [CookieFormatException]
  /// when it holds no cookies.
  Future<ImportResult> importText(String text, {required String fileName}) async {
    final parsed = NetscapeCookies.parseFile(text);
    final time = now();
    _imported = ImportedCookies(parsed.cookies, fileName: fileName, importedAt: time);
    await _save();
    return ImportResult(
      parsed.cookies,
      invalidLines: parsed.invalidLines,
      expired: parsed.cookies.where((c) => c.isExpired(time)).length,
    );
  }

  /// Reads and imports a cookies.txt file (at most 10 MB).
  Future<ImportResult> importFile(File file) async {
    if (await file.length() > 10 * 1024 * 1024) {
      throw const CookieFormatException('This file is too big to be a cookie file.');
    }
    final bytes = await file.readAsBytes();
    return importText(utf8.decode(bytes, allowMalformed: true), fileName: p.basename(file.path));
  }

  Future<void> removeImported() async {
    _imported = null;
    await _save();
  }

  /// Keeps [cookies] (those for [site]) as the site's own. Returns how many
  /// were kept; none replaces nothing.
  Future<int> setSiteCookies(
    CookieSite site,
    Iterable<NetscapeCookie> cookies, {
    required CookieSource source,
  }) async {
    final mine = NetscapeCookies.merge([cookies.where((c) => c.isFor(site.domain))]);
    if (mine.isEmpty) return 0;
    if (!site.builtIn && !_custom.any((c) => c.id == site.id)) _custom.add(site);
    _sites[site.id] = SiteCookies(mine, source: source, updatedAt: now());
    await _save();
    return mine.length;
  }

  /// Keeps what the user pasted for [site]: a Cookie header or cookies.txt
  /// text. Throws [CookieFormatException] when it isn't cookies.
  Future<int> paste(CookieSite site, String text) async {
    final cookies = NetscapeCookies.parsePasted(text, site: site.domain);
    return setSiteCookies(site, cookies, source: CookieSource.pasted);
  }

  /// Forgets the site's own cookies (the imported file's stay).
  Future<void> signOut(CookieSite site) async {
    if (_sites.remove(site.id) == null) return;
    await _save();
  }

  Future<void> addSite(CookieSite site) async {
    if (site.builtIn || _custom.any((c) => c.id == site.id)) return;
    _custom.add(site);
    await _save();
  }

  /// Removes an added site and its cookies.
  Future<void> removeSite(CookieSite site) async {
    if (site.builtIn) return signOut(site);
    _custom.removeWhere((c) => c.id == site.id);
    _sites.remove(site.id);
    await _save();
  }

  SiteStatus status(CookieSite site) {
    final time = now();
    final own = _sites[site.id]?.cookies ?? const <NetscapeCookie>[];
    final live = own.where((c) => !c.isExpired(time)).toList();
    bool signedIn(Iterable<NetscapeCookie> cookies) =>
        site.loginCookies.isNotEmpty && cookies.any((c) => site.loginCookies.contains(c.name));
    String count(int n) => n == 1 ? '1 cookie' : '$n cookies';
    if (own.isNotEmpty && live.isEmpty) {
      return SiteStatus(SiteState.expired, 'Cookies expired, sign in again', count: own.length);
    }
    if (live.isNotEmpty) {
      if (signedIn(live)) {
        return SiteStatus(SiteState.signedIn, 'Signed in · ${count(live.length)}', count: live.length);
      }
      return SiteStatus(
        SiteState.cookies,
        site.loginCookies.isEmpty
            ? '${count(live.length)} saved'
            : '${count(live.length)}, but no sign-in found',
        count: live.length,
      );
    }
    final fromFile = (_imported?.cookies ?? const <NetscapeCookie>[])
        .where((c) => c.isFor(site.domain) && !c.isExpired(time))
        .toList();
    if (fromFile.isNotEmpty) {
      return SiteStatus(
        SiteState.fromFile,
        signedIn(fromFile)
            ? 'Signed in with the imported file'
            : '${count(fromFile.length)} from the imported file',
      );
    }
    return const SiteStatus(SiteState.none, 'Login required');
  }

  /// [text] with every saved cookie value and any Cookie header hidden.
  String redact(String text) {
    var out = text.replaceAllMapped(
      RegExp(r'(\bcookies?\s*[:=]\s*)[^\r\n]+', caseSensitive: false),
      (m) => '${m[1]}[hidden]',
    );
    final redactor = _redactor;
    if (redactor != null) out = out.replaceAll(redactor, '[cookie]');
    return out;
  }

  void _rebuildRedactor() {
    final values = <String>{
      for (final c in [...?_imported?.cookies, for (final s in _sites.values) ...s.cookies])
        if (c.value.length >= 6) c.value,
    }.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    _redactor = values.isEmpty ? null : RegExp(values.map(RegExp.escape).join('|'));
  }

  Future<void> _save() {
    _rebuildRedactor();
    notifyListeners();
    final dir = _dir;
    if (dir == null) return Future.value();
    final json = jsonEncode(_toJson());
    final write = _writing.catchError((Object _) {}).then((_) async {
      await dir.create(recursive: true);
      await _writeAtomically(File(p.join(dir.path, _storeName)), json);
      await _writeMerged();
    });
    _writing = write;
    return write;
  }

  Future<void> _writeMerged() async {
    final path = cookieFilePath;
    if (path == null) return;
    final cookies = merged;
    final file = File(path);
    if (cookies.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await _writeAtomically(
      file,
      NetscapeCookies.write(
        cookies,
        comment: 'Made by Folders for its video downloader. Changes here are '
            'replaced;\nuse the downloader settings instead.',
      ),
    );
  }

  static Future<void> _writeAtomically(File file, String text) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
  }

  Map<String, Object?> _toJson() => {
        'version': 1,
        'sites': [for (final site in _custom) site.toJson()],
        'cookies': {
          for (final e in _sites.entries)
            e.key: {
              'source': e.value.source.name,
              'updatedAt': e.value.updatedAt.millisecondsSinceEpoch,
              'cookies': [for (final c in e.value.cookies) c.toJson()],
            },
        },
        if (_imported != null)
          'imported': {
            'fileName': _imported!.fileName,
            'importedAt': _imported!.importedAt.millisecondsSinceEpoch,
            'cookies': [for (final c in _imported!.cookies) c.toJson()],
          },
      };

  void _fromJson(Object? json) {
    if (json is! Map) return;
    List<NetscapeCookie> cookies(Object? list) => [
          for (final c in (list is List ? list : const [])) ?NetscapeCookie.fromJson(c),
        ];
    DateTime time(Object? ms) =>
        ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : DateTime.fromMillisecondsSinceEpoch(0);
    _custom
      ..clear()
      ..addAll([
        for (final s in (json['sites'] as List?) ?? const [])
          if (CookieSite.fromJson(s) case final site?)
            if (!CookieSite.builtInSites.any((b) => b.id == site.id)) site,
      ]);
    _sites.clear();
    final saved = json['cookies'];
    if (saved is Map) {
      for (final e in saved.entries) {
        final value = e.value;
        if (e.key is! String || value is! Map) continue;
        final list = cookies(value['cookies']);
        if (list.isEmpty) continue;
        _sites[e.key as String] = SiteCookies(
          list,
          source: value['source'] == 'login' ? CookieSource.login : CookieSource.pasted,
          updatedAt: time(value['updatedAt']),
        );
      }
    }
    final imported = json['imported'];
    if (imported is Map) {
      final list = cookies(imported['cookies']);
      if (list.isNotEmpty) {
        _imported = ImportedCookies(
          list,
          fileName: imported['fileName'] is String ? imported['fileName'] as String : 'cookies.txt',
          importedAt: time(imported['importedAt']),
        );
      }
    }
  }
}
