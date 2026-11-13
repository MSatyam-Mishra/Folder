import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Identities of servers met before, trusted on first use: SFTP host keys,
/// and certificates of FTPS and WebDAV servers that this device doesn't
/// trust by itself (a NAS's own). Kept in SharedPreferences: fingerprints
/// aren't secret.
class RemoteKnownHosts {
  static RemoteKnownHosts instance = RemoteKnownHosts();

  static const prefsKey = 'remote_known_hosts';

  Map<String, String>? _known;

  Future<Map<String, String>> _load() async {
    final known = _known;
    if (known != null) return known;
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString(prefsKey);
    final map = <String, String>{};
    if (text != null) {
      try {
        for (final e in (jsonDecode(text) as Map).entries) {
          map['${e.key}'] = '${e.value}';
        }
      } catch (_) {}
    }
    return _known = map;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(_known ?? const {}));
  }

  /// Reads them, so [knownSync] can answer.
  Future<void> load() => _load();

  Future<String?> fingerprintOf(String key) async => (await _load())[key];

  /// What [load] read for [key]; null if not loaded or not known.
  String? knownSync(String key) => _known?[key];

  Future<void> remember(String key, String fingerprint) async {
    (await _load())[key] = fingerprint;
    await _save();
  }

  Future<void> forget(String key) async {
    if ((await _load()).remove(key) != null) await _save();
  }

  /// Whether [fingerprint] is [key]'s: true the first time (and then it's
  /// kept), false if another one was seen before.
  Future<bool> check(String key, String fingerprint) async {
    final known = await _load();
    final before = known[key];
    if (before == null) {
      known[key] = fingerprint;
      await _save();
      return true;
    }
    return before == fingerprint;
  }

  /// The key a server is kept under: `sftp:host:port`, `tls:host:port`.
  static String keyFor(String kind, String host, int port) => '$kind:${host.toLowerCase()}:$port';

  /// SHA-256 of a certificate, as hex pairs.
  static String certificateFingerprint(X509Certificate certificate) =>
      sha256.convert(certificate.der).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');

  @visibleForTesting
  void reset() => _known = null;
}

/// Trust on first use for a TLS server whose certificate this device
/// doesn't accept by itself. Give [onBadCertificate] to the socket or
/// client; when the connection then fails, [failure] says why.
class TlsTrust {
  TlsTrust(this.host, this.port, {RemoteKnownHosts? known}) : known = known ?? RemoteKnownHosts.instance;

  final String host;
  final int port;
  final RemoteKnownHosts known;

  String get _key => RemoteKnownHosts.keyFor('tls', host, port);

  /// The certificate refused, if one was.
  String? refused;
  bool _firstUse = false;

  /// Call (and await) before connecting.
  Future<void> prepare() async {
    await known.load();
    _firstUse = known.knownSync(_key) == null;
  }

  /// Accepts a certificate seen and kept before. A first one is refused too:
  /// the user is asked first ([failure]).
  bool onBadCertificate(X509Certificate certificate) {
    final fingerprint = RemoteKnownHosts.certificateFingerprint(certificate);
    if (known.knownSync(_key) == fingerprint) return true;
    refused = fingerprint;
    return false;
  }

  /// Why the connection failed, if it was the certificate.
  RemoteTrustException? failure() {
    final fingerprint = refused;
    if (fingerprint == null) return null;
    return RemoteTrustException(
      _firstUse
          ? "This device doesn't know the server's certificate (a NAS often has "
              'its own). Trust it only if this is your server.\n\nSHA-256: $fingerprint'
          : "The server's certificate changed since last time. If you didn't change "
              'the server, someone may be listening in.\n\nSHA-256: $fingerprint',
      fingerprint: fingerprint,
      trust: () => known.remember(_key, fingerprint),
    );
  }
}
