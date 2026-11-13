import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where Folders stands with Shizuku, from the user's side.
enum ShizukuState {
  /// Not Android.
  unsupported,
  notInstalled,

  /// Installed, but not started since the phone last started.
  notRunning,

  /// Older than Shizuku 11, which Folders can't talk to.
  tooOld,

  /// Running; Folders may ask to use it.
  notAllowed,

  /// The user said no and "don't ask again": only Shizuku's app can undo it.
  denied,
  ready,
}

@immutable
class ShizukuStatus {
  const ShizukuStatus({
    this.installed = false,
    this.appInstalled = false,
    this.running = false,
    this.version = 0,
    this.granted = false,
    this.denied = false,
    this.uid = -1,
    this.sdk = 0,
    this.supported = true,
  });

  factory ShizukuStatus.fromMap(Map<Object?, Object?> map) => ShizukuStatus(
        installed: map['installed'] == true,
        appInstalled: map['app'] == true,
        running: map['running'] == true,
        version: (map['version'] as num?)?.toInt() ?? 0,
        granted: map['granted'] == true,
        denied: map['denied'] == true,
        uid: (map['uid'] as num?)?.toInt() ?? -1,
        sdk: (map['sdk'] as num?)?.toInt() ?? 0,
      );

  static const unsupported = ShizukuStatus(supported: false);

  final bool supported;

  /// Shizuku's app, or Sui (a Magisk module) running without it.
  final bool installed;

  /// Shizuku's app itself. Its helper keeps running after the app is
  /// uninstalled, until the phone restarts.
  final bool appInstalled;
  final bool running;

  /// Shizuku's API version (13 for Shizuku 13.x).
  final int version;
  final bool granted;
  final bool denied;

  /// Who Shizuku runs as: 2000 (shell) when started with adb or wireless
  /// debugging, 0 with root.
  final int uid;

  /// Android's API level.
  final int sdk;

  ShizukuState get state {
    if (!supported) return ShizukuState.unsupported;
    if (!running) return installed ? ShizukuState.notRunning : ShizukuState.notInstalled;
    if (version < 11) return ShizukuState.tooOld;
    if (granted) return ShizukuState.ready;
    return denied ? ShizukuState.denied : ShizukuState.notAllowed;
  }
}

/// Shizuku (https://shizuku.rikka.app), a free app that runs a helper as the
/// shell user, which may still open Android/data and Android/obb. The native
/// side is `ShizukuNative.kt`, channel `explorer/shizuku`.
abstract final class Shizuku {
  static const packageName = 'moe.shizuku.privileged.api';

  static const playStoreUrl = 'https://play.google.com/store/apps/details?id=$packageName';
  static const releasesUrl = 'https://github.com/RikkaApps/Shizuku/releases';
  static const setupGuideUrl = 'https://shizuku.rikka.app/guide/setup/';

  static const channel = MethodChannel('explorer/shizuku');

  static Future<ShizukuStatus> status() async {
    if (!Platform.isAndroid) return ShizukuStatus.unsupported;
    try {
      final map = await channel.invokeMapMethod<Object?, Object?>('status');
      return map == null ? ShizukuStatus.unsupported : ShizukuStatus.fromMap(map);
    } on MissingPluginException {
      return ShizukuStatus.unsupported;
    }
  }

  /// Shizuku asks the user; true if Folders may use it.
  static Future<bool> requestPermission() async {
    try {
      return await channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// False if Shizuku's app isn't there to open.
  static Future<bool> openApp() async {
    try {
      return await channel.invokeMethod<bool>('openShizuku') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
