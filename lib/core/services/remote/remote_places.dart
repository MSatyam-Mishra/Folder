import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_registry.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The saved network places: their settings as JSON in SharedPreferences
/// (`remote_places`), their secrets in [secretStore]. Listeners hear of
/// every change (the sidebar's Network section).
class RemotePlaces extends ChangeNotifier {
  RemotePlaces({RemoteSecretStore? secretStore}) : secretStore = secretStore ?? RemoteSecretStore.platform();

  static RemotePlaces instance = RemotePlaces();

  static const prefsKey = 'remote_places';

  RemoteSecretStore secretStore;
  List<RemoteConnection> _places = const [];
  bool _loaded = false;
  Future<void>? _loading;

  /// In the order added. Empty until [load] finished.
  List<RemoteConnection> get places => _places;

  bool get loaded => _loaded;

  RemoteConnection? byId(String id) {
    for (final place in _places) {
      if (place.id == id) return place;
    }
    return null;
  }

  /// Reads the saved places (once; later calls wait for the first). Also
  /// registers the protocols this build has.
  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= () async {
      registerRemoteProtocols();
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(prefsKey);
      final places = <RemoteConnection>[];
      if (text != null) {
        try {
          for (final item in jsonDecode(text) as List) {
            final place = RemoteConnection.fromJson((item as Map).cast<String, Object?>());
            if (place != null) places.add(place);
          }
        } catch (e) {
          debugPrint('Network places: unreadable, starting afresh: $e');
        }
      }
      _places = List.unmodifiable(places);
      _loaded = true;
      notifyListeners();
    }();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode([for (final p in _places) p.toJson()]));
    notifyListeners();
  }

  /// Adds [place], or replaces the one with its id. [secrets] are written
  /// over the saved ones; a null value removes that secret.
  Future<void> save(RemoteConnection place, {Map<String, String?> secrets = const {}}) async {
    await load();
    if (secrets.isNotEmpty) {
      final all = {...await secretStore.readAll(place.id)};
      secrets.forEach((key, value) => value == null ? all.remove(key) : all[key] = value);
      await secretStore.writeAll(place.id, all);
    }
    final index = _places.indexWhere((p) => p.id == place.id);
    _places = List.unmodifiable(index < 0 ? [..._places, place] : ([..._places]..[index] = place));
    await _save();
  }

  Future<void> rename(String id, String name) async {
    final place = byId(id);
    if (place == null || name.trim().isEmpty) return;
    await save(place.copyWith(name: name.trim()));
  }

  /// Forgets the place and its secrets.
  Future<void> remove(String id) async {
    await load();
    _places = List.unmodifiable(_places.where((p) => p.id != id));
    await secretStore.deleteAll(id);
    await _save();
  }

  RemoteSecrets secretsOf(String id) => secretStore.secretsOf(id);

  /// A new id: letters and digits, not used yet.
  String newId() {
    final random = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    while (true) {
      final id = 'p${List.generate(8, (_) => chars[random.nextInt(chars.length)]).join()}';
      if (byId(id) == null) return id;
    }
  }

  /// "NAS: /Photos/2026" for a browser path on a place, else null.
  String? describe(String browserPath) {
    final parsed = RemotePaths.parse(browserPath);
    if (parsed == null) return null;
    final (id, path) = parsed;
    return '${byId(id)?.name ?? id}: $path';
  }

  @visibleForTesting
  void reset({RemoteSecretStore? secretStore}) {
    _places = const [];
    _loaded = false;
    _loading = null;
    this.secretStore = secretStore ?? MemoryRemoteSecretStore();
  }
}
