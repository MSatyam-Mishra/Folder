import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

/// Where the secrets of saved places are kept (passwords, private keys,
/// tokens): each place's in one entry, as JSON.
abstract class RemoteSecretStore {
  /// The system's own keystore: the Keychain on macOS, the Keystore on
  /// Android, DPAPI-encrypted files on Windows and libsecret (GNOME Keyring,
  /// KWallet) on Linux. Tests keep them in memory.
  static RemoteSecretStore platform() =>
      Platform.environment.containsKey('FLUTTER_TEST') ? MemoryRemoteSecretStore() : SecureRemoteSecretStore();

  Future<Map<String, String>> readAll(String placeId);

  Future<void> writeAll(String placeId, Map<String, String> secrets);

  Future<void> deleteAll(String placeId);

  /// [placeId]'s secrets as [RemoteSecrets], for its connection.
  RemoteSecrets secretsOf(String placeId) => _PlaceSecrets(this, placeId);
}

class _PlaceSecrets implements RemoteSecrets {
  _PlaceSecrets(this.store, this.placeId);

  final RemoteSecretStore store;
  final String placeId;

  @override
  Future<String?> read(String key) async => (await store.readAll(placeId))[key];

  @override
  Future<void> write(String key, String? value) async {
    final all = {...await store.readAll(placeId)};
    if (value == null) {
      if (all.remove(key) == null) return;
    } else {
      if (all[key] == value) return;
      all[key] = value;
    }
    await store.writeAll(placeId, all);
  }
}

class MemoryRemoteSecretStore extends RemoteSecretStore {
  final Map<String, Map<String, String>> values = {};

  @override
  Future<Map<String, String>> readAll(String placeId) async => {...?values[placeId]};

  @override
  Future<void> writeAll(String placeId, Map<String, String> secrets) async =>
      secrets.isEmpty ? values.remove(placeId) : values[placeId] = {...secrets};

  @override
  Future<void> deleteAll(String placeId) async => values.remove(placeId);
}

/// [RemoteSecretStore] in the system's keystore. Where there's none to use
/// (a Linux desktop without a keyring), secrets live only until the app
/// closes, and [persistent] turns false so the form can say so.
class SecureRemoteSecretStore extends RemoteSecretStore {
  SecureRemoteSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // The login keychain: the data protection one wants a signed
              // app with entitlements, and Folders is signed ad hoc.
              mOptions: MacOsOptions(accountName: 'Folders network places', usesDataProtectionKeychain: false),
              lOptions: LinuxOptions(),
            );

  final FlutterSecureStorage _storage;
  final _fallback = MemoryRemoteSecretStore();

  /// False once the keystore refused: secrets are then kept in memory.
  bool persistent = true;

  static String _key(String placeId) => 'remote_place_$placeId';

  @override
  Future<Map<String, String>> readAll(String placeId) async {
    if (!persistent) return _fallback.readAll(placeId);
    try {
      final text = await _storage.read(key: _key(placeId));
      if (text == null) return {};
      return {for (final e in (jsonDecode(text) as Map).entries) '${e.key}': '${e.value}'};
    } catch (e) {
      debugPrint('Remote secrets: reading failed: $e');
      return _fallback.readAll(placeId);
    }
  }

  @override
  Future<void> writeAll(String placeId, Map<String, String> secrets) async {
    if (persistent) {
      try {
        if (secrets.isEmpty) {
          await _storage.delete(key: _key(placeId));
        } else {
          await _storage.write(key: _key(placeId), value: jsonEncode(secrets));
        }
        return;
      } catch (e) {
        debugPrint('Remote secrets: the keystore refused, keeping them in memory: $e');
        persistent = false;
      }
    }
    await _fallback.writeAll(placeId, secrets);
  }

  @override
  Future<void> deleteAll(String placeId) async {
    await _fallback.deleteAll(placeId);
    try {
      await _storage.delete(key: _key(placeId));
    } catch (_) {}
  }
}
