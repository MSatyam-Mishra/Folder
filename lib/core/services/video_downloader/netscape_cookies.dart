/// One cookie in the Netscape format yt-dlp reads with `--cookies` (the
/// `cookies.txt` that browser extensions export).
class NetscapeCookie {
  const NetscapeCookie({
    required this.domain,
    required this.name,
    required this.value,
    this.path = '/',
    this.secure = true,
    this.expires = 0,
    this.httpOnly = false,
  });

  /// E.g. ".youtube.com": a leading dot means its subdomains too.
  final String domain;
  final String name;
  final String value;
  final String path;
  final bool secure;

  /// Seconds since 1970; 0 for a session cookie.
  final int expires;
  final bool httpOnly;

  bool get includeSubdomains => domain.startsWith('.');

  /// [domain] without the leading dot, in lower case.
  String get host => (includeSubdomains ? domain.substring(1) : domain).toLowerCase();

  /// Two cookies with the same key are the same cookie; the newer replaces
  /// the older.
  String get key => '${domain.toLowerCase()}\t$path\t$name';

  bool isExpired(DateTime now) =>
      expires > 0 && expires < now.millisecondsSinceEpoch ~/ 1000;

  /// Whether it's sent to [site] (e.g. "youtube.com") or one of its
  /// subdomains.
  bool isFor(String site) {
    final d = site.toLowerCase();
    return host == d || host.endsWith('.$d');
  }

  /// The line in a cookies.txt file. The subdomain flag must match the
  /// leading dot, or Python's cookie jar (yt-dlp's) refuses the whole file.
  String toLine() => [
        '${httpOnly ? NetscapeCookies.httpOnlyPrefix : ''}$domain',
        includeSubdomains ? 'TRUE' : 'FALSE',
        path,
        secure ? 'TRUE' : 'FALSE',
        '$expires',
        name,
        value,
      ].join('\t');

  Map<String, Object?> toJson() => {
        'domain': domain,
        'name': name,
        'value': value,
        'path': path,
        'secure': secure,
        'expires': expires,
        'httpOnly': httpOnly,
      };

  static NetscapeCookie? fromJson(Object? json) {
    if (json is! Map) return null;
    final domain = json['domain'];
    final name = json['name'];
    final value = json['value'];
    if (domain is! String || name is! String || value is! String) return null;
    return NetscapeCookies.make(
      domain: domain,
      name: name,
      value: value,
      path: json['path'] is String ? json['path'] as String : '/',
      secure: json['secure'] != false,
      expires: json['expires'] is num ? (json['expires'] as num).toInt() : 0,
      httpOnly: json['httpOnly'] == true,
    );
  }

  @override
  String toString() => 'NetscapeCookie($domain $name)'; // never the value
}

/// What [NetscapeCookies.parse] found.
class CookieParseResult {
  const CookieParseResult(this.cookies, {this.invalidLines = 0, this.hasHeader = false});

  final List<NetscapeCookie> cookies;

  /// Lines that were neither comments nor cookies.
  final int invalidLines;

  /// The file starts with "# Netscape HTTP Cookie File".
  final bool hasHeader;
}

/// Text that can't be read as cookies; [message] is fit to show and never
/// holds a cookie's value.
class CookieFormatException implements Exception {
  const CookieFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads and writes cookies.txt (Netscape) files and Cookie headers.
abstract final class NetscapeCookies {
  static const header = '# Netscape HTTP Cookie File';
  static const httpOnlyPrefix = '#HttpOnly_';

  /// A cookie with its fields tidied: no tabs or line breaks (they would
  /// break the file), a path that starts with "/", and the subdomain flag
  /// carried by the leading dot. Null when it can't be a cookie.
  static NetscapeCookie? make({
    required String domain,
    required String name,
    required String value,
    String path = '/',
    bool secure = true,
    int expires = 0,
    bool httpOnly = false,
    bool? includeSubdomains,
  }) {
    var d = domain.trim().toLowerCase();
    final n = name.trim();
    if (d.isEmpty || d == '.' || n.isEmpty) return null;
    if (_bad.hasMatch(d) || _bad.hasMatch(n) || n.contains('=') || n.contains(';')) {
      return null;
    }
    if (includeSubdomains == true && !d.startsWith('.')) d = '.$d';
    final v = value.replaceAll(_control, '');
    var pth = path.trim().replaceAll(_control, '');
    if (!pth.startsWith('/')) pth = '/$pth';
    return NetscapeCookie(
      domain: d,
      name: n,
      value: v,
      path: pth,
      secure: secure,
      expires: expires < 0 ? 0 : expires,
      httpOnly: httpOnly,
    );
  }

  static final _bad = RegExp(r'[\s\x00-\x1F\x7F]');
  static final _control = RegExp(r'[\x00-\x1F\x7F]');

  /// Reads a cookies.txt file. Lenient about what browser extensions and
  /// copy and paste do to it: a missing header, spaces instead of tabs, an
  /// empty value without its tab, decimals in the expiry.
  static CookieParseResult parse(String text) {
    final cookies = <NetscapeCookie>[];
    var invalid = 0;
    final lines = text.replaceFirst('﻿', '').split(RegExp(r'\r?\n|\r'));
    final hasHeader = lines.isNotEmpty &&
        RegExp(r'^#( Netscape)? HTTP Cookie File', caseSensitive: false)
            .hasMatch(lines.first.trim());
    for (final raw in lines) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      var httpOnly = false;
      if (line.startsWith(httpOnlyPrefix)) {
        httpOnly = true;
        line = line.substring(httpOnlyPrefix.length);
      } else if (line.startsWith('#') || line.startsWith(r'$')) {
        continue;
      }
      final cookie = _line(raw.trimLeft().substring(httpOnly ? httpOnlyPrefix.length : 0), httpOnly);
      if (cookie == null) {
        invalid++;
      } else {
        cookies.add(cookie);
      }
    }
    return CookieParseResult(cookies, invalidLines: invalid, hasHeader: hasHeader);
  }

  static NetscapeCookie? _line(String line, bool httpOnly) {
    line = line.replaceAll(RegExp(r'[\r\n]'), '');
    var fields = line.split('\t');
    if (fields.length < 6) {
      // Tabs turned into spaces: the value is whatever comes after the name.
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 6) return null;
      fields = [...parts.take(6), parts.skip(6).join(' ')];
    }
    if (fields.length == 6) fields = [...fields, ''];
    if (fields.length > 7) {
      // A value with tabs in it.
      fields = [...fields.take(6), fields.skip(6).join('\t')];
    }
    final flag = fields[1].trim().toUpperCase();
    final secure = fields[3].trim().toUpperCase();
    if (!_bools.contains(flag) || !_bools.contains(secure)) return null;
    final expiresText = fields[4].trim();
    int expires;
    if (expiresText.isEmpty) {
      expires = 0;
    } else {
      final number = num.tryParse(expiresText);
      if (number == null) return null;
      expires = number.floor();
    }
    return make(
      domain: fields[0],
      includeSubdomains: flag == 'TRUE',
      path: fields[2],
      secure: secure == 'TRUE',
      expires: expires,
      name: fields[5],
      value: fields[6].trim(),
      httpOnly: httpOnly,
    );
  }

  static const _bools = {'TRUE', 'FALSE'};

  /// A web view's expiry as seconds since 1970 (0: a session cookie). Most
  /// platforms give milliseconds, Windows' WebView2 seconds, and a session
  /// cookie null, 0 or -1.
  static int expiryFrom(num? value) {
    if (value == null || value <= 0) return 0;
    return (value > 100000000000 ? value / 1000 : value).floor();
  }

  /// Whether [text] holds at least one cookies.txt line.
  static bool looksLikeFile(String text) => parse(text).cookies.isNotEmpty;

  /// Reads a Cookie header as a browser sends it ("name=value; name2=value2",
  /// with or without "Cookie:"), for [site] and its subdomains.
  static List<NetscapeCookie> parseHeader(String text, {required String site}) {
    final body = text.trim();
    final prefix = RegExp(r'^cookie\s*:\s*', caseSensitive: false);
    final cookies = <String, NetscapeCookie>{};
    for (final rawLine in body.split(RegExp(r'\r?\n|\r'))) {
      final line = rawLine.trim().replaceFirst(prefix, '');
      for (final part in line.split(';')) {
        final pair = part.trim();
        final eq = pair.indexOf('=');
        if (eq <= 0) continue;
        final cookie = make(
          domain: '.${site.toLowerCase()}',
          name: pair.substring(0, eq),
          value: pair.substring(eq + 1).trim(),
        );
        if (cookie != null) cookies[cookie.name] = cookie;
      }
    }
    return cookies.values.toList();
  }

  /// Reads what a user pasted for [site]: a cookies.txt text (only the
  /// cookies for [site] are kept) or a Cookie header.
  static List<NetscapeCookie> parsePasted(String text, {required String site}) {
    if (text.trim().isEmpty) {
      throw const CookieFormatException('Paste the cookies first.');
    }
    final file = parse(text);
    if (file.cookies.isNotEmpty) {
      final mine = file.cookies.where((c) => c.isFor(site)).toList();
      if (mine.isEmpty) {
        throw CookieFormatException(
          'None of these ${file.cookies.length} cookies are for $site.',
        );
      }
      return mine;
    }
    final header = parseHeader(text, site: site);
    if (header.isEmpty) {
      throw const CookieFormatException(
        'These aren\'t cookies. Paste a Cookie header (name=value; '
        'name2=value2) or the text of a cookies.txt file.',
      );
    }
    return header;
  }

  /// Checks the text of a cookie file chosen to import.
  static CookieParseResult parseFile(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      throw const CookieFormatException(
        'This file is in JSON. Export the cookies in Netscape format '
        '(cookies.txt) instead.',
      );
    }
    final result = parse(text);
    if (result.cookies.isEmpty) {
      throw const CookieFormatException(
        'No cookies found. Choose a cookies.txt file in Netscape format.',
      );
    }
    return result;
  }

  /// All of [sources] in one list; a cookie in a later source replaces the
  /// same cookie in an earlier one.
  static List<NetscapeCookie> merge(Iterable<Iterable<NetscapeCookie>> sources) {
    final merged = <String, NetscapeCookie>{};
    for (final source in sources) {
      for (final cookie in source) {
        merged.remove(cookie.key);
        merged[cookie.key] = cookie;
      }
    }
    return merged.values.toList();
  }

  /// A cookies.txt file, header first (yt-dlp refuses a file without it).
  static String write(Iterable<NetscapeCookie> cookies, {String? comment}) {
    final out = StringBuffer('$header\n');
    if (comment != null) {
      for (final line in comment.split('\n')) {
        out.writeln('# $line');
      }
    }
    out.writeln();
    for (final cookie in cookies) {
      out.writeln(cookie.toLine());
    }
    return out.toString();
  }

  /// The site part of a link or host name, e.g. "youtube.com" for
  /// "https://www.youtube.com/watch?v=…". Null when it isn't one.
  static String? siteOf(String input) {
    var text = input.trim().toLowerCase();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final host = Uri.tryParse(text)?.host ?? '';
    if (!RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
        .hasMatch(host)) {
      return null;
    }
    for (final prefix in const ['www.', 'm.', 'mobile.']) {
      if (host.startsWith(prefix) && host.split('.').length > 2) {
        return host.substring(prefix.length);
      }
    }
    return host;
  }

  /// The site a cookie's host belongs to, for counting: "google.com" for
  /// "accounts.google.com", "bbc.co.uk" for "www.bbc.co.uk".
  static String siteGroup(String host) {
    final labels = host.split('.').where((l) => l.isNotEmpty).toList();
    if (labels.length <= 2) return labels.join('.');
    final last = labels.last;
    final second = labels[labels.length - 2];
    final keep = last.length == 2 && second.length <= 3 ? 3 : 2;
    return labels.sublist(labels.length - keep).join('.');
  }

  /// Cookies per site, most first.
  static List<MapEntry<String, int>> countBySite(Iterable<NetscapeCookie> cookies) {
    final counts = <String, int>{};
    for (final c in cookies) {
      final site = siteGroup(c.host);
      counts[site] = (counts[site] ?? 0) + 1;
    }
    return counts.entries.toList()
      ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  }

  /// "42 cookies for youtube.com, google.com and 3 more sites".
  static String summary(List<NetscapeCookie> cookies) {
    if (cookies.isEmpty) return 'No cookies';
    final sites = countBySite(cookies).map((e) => e.key).toList();
    final count = cookies.length == 1 ? '1 cookie' : '${cookies.length} cookies';
    final shown = sites.take(sites.length > 3 ? 2 : 3).toList();
    final more = sites.length - shown.length;
    final String list;
    if (more > 0) {
      list = '${shown.join(', ')} and $more more site${more == 1 ? '' : 's'}';
    } else if (shown.length == 1) {
      list = shown.single;
    } else {
      list = '${shown.sublist(0, shown.length - 1).join(', ')} and ${shown.last}';
    }
    return '$count for $list';
  }
}
