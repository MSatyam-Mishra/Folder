import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/shizuku/shizuku.dart';

/// Android/data and Android/obb (and the rest of the Android folder) through
/// Shizuku, as a remote place. Its paths start at the connection's `base`
/// option, by default [ShizukuPlaces.androidFolder]: `/data/com.app/files`
/// is `/storage/emulated/0/Android/data/com.app/files`.
///
/// The files are opened by a helper running in Shizuku's process (see
/// `ShizukuFileService.kt`), which hands each open file to this app, so reads
/// and writes go straight to the file.
class ShizukuFileSystem implements RemoteFileSystem {
  ShizukuFileSystem(this.connection, {@visibleForTesting MethodChannel? channel})
      : _channel = channel ?? Shizuku.channel;

  @override
  final RemoteConnection connection;
  final MethodChannel _channel;

  /// Bytes per call through the channel.
  static const chunkSize = 512 * 1024;

  /// Open instances: the helper is shared, and stops when the last one closes.
  static int _open = 0;
  bool _connected = false;

  String get base => connection.options['base'] ?? ShizukuPlaces.androidFolder;

  /// The path on the phone of [path] in this place.
  String devicePath(String path) {
    final normalized = RemotePaths.normalize(path);
    return normalized == '/' ? base : '$base$normalized';
  }

  @override
  Future<void> connect() async {
    await _call<Object?>('connect', const {}, '');
    if (!_connected) {
      _connected = true;
      _open++;
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final folder = RemotePaths.normalize(path);
    final entries = await _call<List<Object?>>('list', {'path': devicePath(folder)}, folder) ?? const [];
    return [
      for (final e in entries.cast<Map<Object?, Object?>>())
        RemoteEntry(
          path: RemotePaths.join(folder, e['name']! as String),
          isDirectory: e['dir'] == true,
          size: (e['size'] as num?)?.toInt() ?? 0,
          modified: _time(e['modified']),
        ),
    ];
  }

  @override
  Future<RemoteEntry> stat(String path) async {
    final normalized = RemotePaths.normalize(path);
    final text = await _call<String>('stat', {'path': devicePath(normalized)}, normalized) ?? '';
    final parts = text.split('\t');
    if (parts.length < 3) throw RemoteException(RemoteErrorKind.other, "Couldn't read the details of ${_name(normalized)}");
    return RemoteEntry(
      path: normalized,
      isDirectory: parts[0] == 'd',
      size: int.tryParse(parts[1]) ?? 0,
      modified: _time(int.tryParse(parts[2])),
    );
  }

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    final normalized = RemotePaths.normalize(path);
    if (end != null && end <= start) return;
    final handle = await _call<int>('openRead', {'path': devicePath(normalized), 'start': start}, normalized);
    var left = end == null ? null : end - start;
    try {
      while (left == null || left > 0) {
        final max = left == null || left > chunkSize ? chunkSize : left;
        final chunk = await _call<Uint8List>('read', {'handle': handle, 'max': max}, normalized);
        if (chunk == null || chunk.isEmpty) break;
        if (left != null) left -= chunk.length;
        yield chunk;
        if (chunk.length < max) break;
      }
    } finally {
      await _close(handle);
    }
  }

  @override
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  }) async {
    final normalized = RemotePaths.normalize(path);
    final target = devicePath(normalized);
    final handle = await _call<int>('openWrite', {'path': target, 'overwrite': overwrite}, normalized);
    var sent = 0;
    final buffer = BytesBuilder(copy: false);
    Future<void> flush() async {
      if (buffer.isEmpty) return;
      final bytes = buffer.takeBytes();
      await _call<Object?>('write', {'handle': handle, 'bytes': bytes}, normalized);
      sent += bytes.length;
      onProgress?.call(sent);
    }

    try {
      await for (final chunk in data) {
        buffer.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
        if (buffer.length >= chunkSize) await flush();
      }
      await flush();
    } catch (_) {
      // Half a file is worse than none.
      await _close(handle);
      try {
        await _call<Object?>('delete', {'path': target}, normalized);
      } on RemoteException {
        // Gone already, or Shizuku with it.
      }
      rethrow;
    }
    await _call<Object?>('close', {'handle': handle}, normalized);
  }

  @override
  Future<void> createDirectory(String path) async {
    final normalized = RemotePaths.normalize(path);
    await _call<Object?>('mkdir', {'path': devicePath(normalized)}, normalized);
  }

  @override
  Future<void> delete(String path) async {
    final normalized = RemotePaths.normalize(path);
    if (normalized == '/') {
      throw const RemoteException(RemoteErrorKind.permission, "The Android folder itself can't be deleted");
    }
    await _call<Object?>('delete', {'path': devicePath(normalized)}, normalized);
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = RemotePaths.normalize(from);
    final target = RemotePaths.normalize(to);
    await _call<Object?>('rename', {'from': devicePath(source), 'to': devicePath(target)}, target);
  }

  @override
  Future<void> close() async {
    if (!_connected) return;
    _connected = false;
    if (--_open > 0) return;
    try {
      await _channel.invokeMethod<void>('disconnect');
    } on Object {
      // Nothing left to stop.
    }
  }

  Future<void> _close(int? handle) async {
    if (handle == null) return;
    try {
      await _channel.invokeMethod<void>('close', {'handle': handle});
    } on Object {
      // Shizuku stopped meanwhile.
    }
  }

  Future<T?> _call<T>(String method, Map<String, Object?> args, String path) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw errorFor(e, path);
    } on MissingPluginException {
      throw const RemoteException(RemoteErrorKind.unsupported, 'App folders open only on Android');
    }
  }

  /// Plain words for what the native side reported about [path].
  @visibleForTesting
  static RemoteException errorFor(PlatformException e, String path) {
    final name = _name(path);
    return switch (e.code) {
      'notFound' => RemoteException(RemoteErrorKind.notFound, '"$name" isn\'t there'),
      'alreadyExists' => RemoteException(RemoteErrorKind.alreadyExists, '"$name" is already there'),
      'permission' => RemoteException(RemoteErrorKind.permission, "Android didn't allow this for \"$name\", even through Shizuku"),
      'unsupported' => const RemoteException(RemoteErrorKind.unsupported, "This can't be done between these folders"),
      'notRunning' => const RemoteException(RemoteErrorKind.auth, "Shizuku isn't running. Start it in the Shizuku app, then try again."),
      'notAllowed' => const RemoteException(RemoteErrorKind.auth, "Folders isn't allowed to use Shizuku yet."),
      _ => RemoteException(RemoteErrorKind.other, 'Something went wrong with "$name": ${e.message ?? e.code}'),
    };
  }

  static String _name(String path) {
    final name = RemotePaths.nameOf(path);
    return name.isEmpty ? 'Android' : name;
  }

  static DateTime? _time(Object? ms) {
    final value = (ms as num?)?.toInt() ?? 0;
    return value > 0 ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  }
}

/// The Shizuku place and the paths it stands in for.
abstract final class ShizukuPlaces {
  /// The id of the one Shizuku place, as in `explorer://remote/shizuku/...`.
  static const connectionId = 'shizuku';
  static const name = 'App folders';
  static const androidFolder = '/storage/emulated/0/Android';

  /// Android 11 (API 30) locked Android/data and Android/obb.
  static const lockedSince = 30;

  static RemoteConnection get connection => const RemoteConnection(
        id: connectionId,
        protocol: RemoteProtocol.shizuku,
        name: name,
      );

  /// Android's API level, once known; null on other systems or before then.
  static int? sdk;

  /// Learns Android's version, for [redirect]. Cheap; called at startup.
  static Future<void> init() async {
    if (!Platform.isAndroid || sdk != null) return;
    try {
      final status = await Shizuku.status();
      if (status.sdk > 0) sdk = status.sdk;
    } on Object {
      // Left unknown: Android 11 or newer is assumed.
    }
  }

  /// [path] with `/sdcard` and `/storage/self/primary` spelled out, or null
  /// if it isn't in internal storage's Android folder.
  static String? _inAndroidFolder(String path) {
    var p = path.replaceAll('\\', '/');
    for (final alias in const ['/sdcard', '/storage/self/primary', '/mnt/sdcard']) {
      if (p == alias || p.startsWith('$alias/')) {
        p = '/storage/emulated/0${p.substring(alias.length)}';
        break;
      }
    }
    p = RemotePaths.normalize(p);
    if (p == androidFolder) return '/';
    if (!p.startsWith('$androidFolder/')) return null;
    return p.substring(androidFolder.length);
  }

  /// Whether Android keeps apps out of [path] on Android [sdkInt] (by
  /// default this phone's): Android/data and Android/obb, and what's in
  /// them, from Android 11.
  static bool isLocked(String path, {int? sdkInt}) {
    final level = sdkInt ?? sdk ?? lockedSince;
    if (level < lockedSince) return false;
    final rest = _inAndroidFolder(path);
    if (rest == null) return false;
    return rest == '/data' || rest.startsWith('/data/') || rest == '/obb' || rest.startsWith('/obb/');
  }

  /// The Shizuku place's browser path for [path] when Android keeps apps out
  /// of it ([isLocked]), else null. `/storage/emulated/0/Android/data/x`
  /// becomes `explorer://remote/shizuku/data/x`.
  static String? redirect(String path, {int? sdkInt, String id = connectionId}) {
    if (!isLocked(path, sdkInt: sdkInt)) return null;
    return RemotePaths.build(id, _inAndroidFolder(path)!);
  }

  /// The other way: the folder on the phone a browser path of the Shizuku
  /// place stands for, or null if it isn't one.
  static String? localPathOf(String browserPath, {String id = connectionId}) {
    final parsed = RemotePaths.parse(browserPath);
    if (parsed == null || parsed.$1 != id) return null;
    return parsed.$2 == '/' ? androidFolder : '$androidFolder${parsed.$2}';
  }
}
