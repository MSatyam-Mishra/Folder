import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A `WWW-Authenticate` challenge: its scheme (`basic`, `digest`) and
/// parameters (`realm`, `nonce`, `qop`...).
class HttpChallenge {
  const HttpChallenge(this.scheme, this.params);

  final String scheme;
  final Map<String, String> params;

  /// The challenges in [headers] (one header may hold several), Digest
  /// first: it doesn't send the password itself.
  static List<HttpChallenge> parseAll(List<String> headers) {
    final found = <HttpChallenge>[];
    for (final header in headers) {
      found.addAll(_parse(header));
    }
    found.sort((a, b) => (a.scheme == 'digest' ? 0 : 1) - (b.scheme == 'digest' ? 0 : 1));
    return found;
  }

  static List<HttpChallenge> _parse(String header) {
    final out = <HttpChallenge>[];
    var i = 0;
    String? scheme;
    var params = <String, String>{};
    final text = header;
    void flush() {
      if (scheme != null) out.add(HttpChallenge(scheme!.toLowerCase(), params));
      scheme = null;
      params = {};
    }

    while (i < text.length) {
      // Skips spaces and commas.
      while (i < text.length && (text[i] == ' ' || text[i] == ',')) {
        i++;
      }
      if (i >= text.length) break;
      final start = i;
      while (i < text.length && text[i] != ' ' && text[i] != '=' && text[i] != ',') {
        i++;
      }
      final token = text.substring(start, i);
      if (i < text.length && text[i] == '=') {
        // A parameter.
        i++;
        String value;
        if (i < text.length && text[i] == '"') {
          i++;
          final buffer = StringBuffer();
          while (i < text.length && text[i] != '"') {
            if (text[i] == '\\' && i + 1 < text.length) i++;
            buffer.write(text[i]);
            i++;
          }
          i++;
          value = buffer.toString();
        } else {
          final valueStart = i;
          while (i < text.length && text[i] != ',' && text[i] != ' ') {
            i++;
          }
          value = text.substring(valueStart, i);
        }
        params[token.toLowerCase()] = value;
      } else {
        // A new scheme.
        flush();
        scheme = token;
      }
    }
    flush();
    return out;
  }
}

/// Answers HTTP Basic and Digest (MD5, MD5-sess, SHA-256; qop auth)
/// challenges for one user.
class HttpAuthenticator {
  HttpAuthenticator(this.username, this.password, {Random? random, String Function()? cnonce})
      : _random = random ?? Random.secure(),
        _cnonce = cnonce;

  final String username;
  final String password;
  final Random _random;
  final String Function()? _cnonce;
  HttpChallenge? _challenge;
  int _count = 0;

  /// Whether a challenge was taken, so requests carry an answer.
  bool get ready => _challenge != null;

  /// Takes the best of [challenges]; false if none can be answered.
  bool accept(List<HttpChallenge> challenges) {
    for (final c in challenges) {
      if (c.scheme == 'digest' || c.scheme == 'basic') {
        _challenge = c;
        _count = 0;
        return true;
      }
    }
    return false;
  }

  /// The `Authorization` header for [method] on [uri] (path and query as
  /// sent), or null before any challenge.
  String? authorization(String method, String uri) {
    final challenge = _challenge;
    if (challenge == null) return null;
    if (challenge.scheme == 'basic') {
      return 'Basic ${base64.encode(utf8.encode('$username:$password'))}';
    }
    final p = challenge.params;
    final realm = p['realm'] ?? '';
    final nonce = p['nonce'] ?? '';
    final algorithm = (p['algorithm'] ?? 'MD5').toUpperCase();
    final qops = (p['qop'] ?? '').split(',').map((q) => q.trim().toLowerCase()).toList();
    final qop = qops.contains('auth') ? 'auth' : null;
    String hash(String s) =>
        (algorithm.startsWith('SHA-256') ? sha256 : md5).convert(utf8.encode(s)).toString();
    _count++;
    final nc = _count.toRadixString(16).padLeft(8, '0');
    final cnonce = _cnonce?.call() ?? List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    var ha1 = hash('$username:$realm:$password');
    if (algorithm.endsWith('-SESS')) ha1 = hash('$ha1:$nonce:$cnonce');
    final ha2 = hash('$method:$uri');
    final response = qop == null ? hash('$ha1:$nonce:$ha2') : hash('$ha1:$nonce:$nc:$cnonce:$qop:$ha2');
    final parts = [
      'username="${_quote(username)}"',
      'realm="${_quote(realm)}"',
      'nonce="${_quote(nonce)}"',
      'uri="${_quote(uri)}"',
      'algorithm=$algorithm',
      'response="$response"',
      if (qop != null) ...['qop=$qop', 'nc=$nc', 'cnonce="$cnonce"'],
      if (p['opaque'] != null) 'opaque="${_quote(p['opaque']!)}"',
    ];
    return 'Digest ${parts.join(', ')}';
  }

  static String _quote(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
}
