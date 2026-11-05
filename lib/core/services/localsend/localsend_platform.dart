// Flutter-side glue for LocalSend: persisted settings, default folders,
// device model and the Android platform channel (multicast lock, network
// change callbacks). Not imported by the pure-Dart protocol code.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/services/localsend/localsend.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android: holds a Wi-Fi multicast lock while LocalSend runs (Android drops
/// multicast packets without one) and reports network changes.
class LsAndroidHooks implements LsPlatformHooks {
  LsAndroidHooks() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'networkChanged') onNetworkChanged?.call();
      return null;
    });
  }

  static const _channel = MethodChannel('explorer/localsend');

  VoidCallback? onNetworkChanged;

  @override
  Future<void> acquireMulticastLock() async {
    await _invoke('acquireMulticastLock');
    await _invoke('startNetworkMonitor');
  }

  @override
  Future<void> releaseMulticastLock() async {
    await _invoke('stopNetworkMonitor');
    await _invoke('releaseMulticastLock');
  }

  /// `{ "wifi": bool, "ssid": String?, "addresses": [String] }`, or null.
  Future<Map<String, dynamic>?> networkInfo() async {
    final result = await _invoke('getNetworkInfo');
    return result is Map ? Map<String, dynamic>.from(result) : null;
  }

  Future<Object?> _invoke(String method) async {
    try {
      return await _channel.invokeMethod<Object?>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      LsLog.d('$method: ${e.message}');
      return null;
    }
  }

  void dispose() => _channel.setMethodCallHandler(null);
}

/// Settings and trusted devices persisted with shared_preferences.
abstract final class LsSettingsStore {
  static const _alias = 'localsend.alias';
  static const _port = 'localsend.port';
  static const _https = 'localsend.https';
  static const _pin = 'localsend.pin';
  static const _autoAccept = 'localsend.autoAcceptTrusted';
  static const _destination = 'localsend.destination';
  static const _httpFingerprint = 'localsend.httpFingerprint';
  static const _checksums = 'localsend.sendChecksums';
  static const _trusted = 'localsend.trustedDevices';

  /// Loads the settings. [usedFallback] is set when the saved (or default)
  /// destination is not writable and an app folder is used instead.
  static Future<(LsSettings, bool usedFallback)> load() async {
    final prefs = await SharedPreferences.getInstance();
    var alias = prefs.getString(_alias);
    if (alias == null || alias.trim().isEmpty) {
      alias = lsRandomAlias();
      await prefs.setString(_alias, alias);
    }
    var httpFingerprint = prefs.getString(_httpFingerprint);
    if (httpFingerprint == null) {
      httpFingerprint = lsRandomId();
      await prefs.setString(_httpFingerprint, httpFingerprint);
    }
    var destination = prefs.getString(_destination);
    var fallback = false;
    if (destination == null || !await isWritable(destination)) {
      final (dir, usedFallback) = await defaultDestination();
      fallback = usedFallback || destination != null;
      destination = dir;
    }
    final settings = LsSettings(
      alias: alias,
      port: prefs.getInt(_port) ?? LsConst.defaultPort,
      https: prefs.getBool(_https) ?? true,
      pin: prefs.getString(_pin),
      autoAcceptTrusted: prefs.getBool(_autoAccept) ?? false,
      destination: destination,
      httpFingerprint: httpFingerprint,
      sendChecksums: prefs.getBool(_checksums) ?? false,
      deviceModel: await deviceModel(),
      deviceType: Platform.isAndroid || Platform.isIOS
          ? LsDeviceType.mobile
          : LsDeviceType.desktop,
    );
    return (settings, fallback);
  }

  static Future<void> save(LsSettings s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_alias, s.alias);
    await prefs.setInt(_port, s.port);
    await prefs.setBool(_https, s.https);
    final pin = s.pin;
    if (pin == null || pin.isEmpty) {
      await prefs.remove(_pin);
    } else {
      await prefs.setString(_pin, pin);
    }
    await prefs.setBool(_autoAccept, s.autoAcceptTrusted);
    await prefs.setString(_destination, s.destination);
    await prefs.setBool(_checksums, s.sendChecksums);
  }

  /// Trusted devices (upper-case fingerprint -> alias) for auto-accept.
  static Future<Map<String, String>> loadTrusted() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_trusted);
      if (raw == null) return {};
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> saveTrusted(Map<String, String> trusted) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_trusted, jsonEncode(trusted));
  }

  static Future<Directory> identityDirectory() async => Directory(
    p.join((await getApplicationSupportDirectory()).path, 'localsend'),
  );

  /// Public Download/LocalSend on Android, Downloads/LocalSend on desktop.
  /// Falls back to an app folder when that is not writable.
  static Future<(String, bool usedFallback)> defaultDestination() async {
    String? preferred;
    if (Platform.isAndroid) {
      preferred = p.join(
        ExplorerPaths.androidInternalStorage,
        'Download',
        'LocalSend',
      );
    } else if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) preferred = p.join(downloads.path, 'LocalSend');
      } catch (_) {}
    }
    if (preferred != null && await isWritable(preferred)) {
      return (preferred, false);
    }

    // macOS asks before an app uses ~/Documents, and a declined prompt
    // would stop LocalSend from starting, so it uses Application Support,
    // which needs no permission.
    Directory? base;
    if (!Platform.isMacOS) {
      try {
        base = Platform.isAndroid
            ? await getExternalStorageDirectory()
            : await getApplicationDocumentsDirectory();
      } catch (_) {}
    }
    base ??= await getApplicationSupportDirectory();
    final fallback = p.join(base.path, 'LocalSend');
    await Directory(fallback).create(recursive: true);
    return (fallback, Platform.isAndroid || preferred != null);
  }

  static Future<bool> isWritable(String dir) async {
    try {
      await Directory(dir).create(recursive: true);
      final probe = File(p.join(dir, '.localsend_write_test'));
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// What other devices show under our alias.
  static Future<String?> deviceModel() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        final maker = a.manufacturer.isEmpty
            ? a.brand
            : '${a.manufacturer[0].toUpperCase()}${a.manufacturer.substring(1)}';
        if (a.model.toLowerCase().startsWith(maker.toLowerCase())) {
          return a.model;
        }
        return '$maker ${a.model}'.trim();
      }
      if (Platform.isIOS) return (await info.iosInfo).model;
      if (Platform.isWindows) return 'Windows';
      if (Platform.isMacOS) return 'macOS';
      if (Platform.isLinux) return 'Linux';
    } catch (_) {}
    return null;
  }
}
