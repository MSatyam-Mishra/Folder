import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:folders/core/services/audio/routing_audio_platform.dart';
import 'package:folders/core/services/image_convert/image_converter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:path/path.dart' as p;

/// Which player plays which sound files, and plain words for those nothing
/// here can play.
///
/// On Android just_audio plays with ExoPlayer, which can't open WMA, AIFF
/// and some others; libmpv, in the app for the video player, can. So those
/// go to libmpv (through just_audio_media_kit), and so does anything
/// ExoPlayer fails to load ([RoutingAudioPlatform]).
///
/// Computers play everything with libmpv, whose Windows build has no AMR
/// decoder and no CAF reader: when a file fails there and FFmpeg is at hand
/// (the one the app downloads for its converter, or the system's), [load]
/// plays a FLAC copy made with it.
abstract final class AudioSupport {
  /// Straight to libmpv on Android: formats ExoPlayer has no reader for,
  /// which the Android build of libmpv (media_kit's) has.
  static const androidMpvFirst = {
    'wma', 'asf', 'aif', 'aiff', 'aifc', 'ape', 'au', 'snd', 'dsf', //
    'mpc', 'ra', 'rm', 'tak', 'tta', 'wv', 'shn',
  };

  /// Neither ExoPlayer nor Android's libmpv reads these: libmpv there has no
  /// CAF reader, and nothing else on the phone does.
  static const androidUnplayable = {'caf'};

  static String _extension(String path) => p.extension(path).replaceFirst('.', '').toLowerCase();

  /// Whether a file at [uri] (a path or a file:// address) goes straight to
  /// libmpv on Android.
  static bool wantsMpvOnAndroid(String uri) {
    final path = uri.startsWith('file:') ? Uri.parse(uri).toFilePath(windows: false) : uri;
    return androidMpvFirst.contains(_extension(path));
  }

  /// Sets up Android's players (see the class). Called once at startup,
  /// after `MediaKit.ensureInitialized()`.
  static void initAndroid() {
    if (JustAudioPlatform.instance is RoutingAudioPlatform) return;
    JustAudioPlatform.instance = RoutingAudioPlatform(
      preferred: JustAudioPlatform.instance,
      fallback: JustAudioMediaKit(),
      wantsFallback: wantsMpvOnAndroid,
    );
  }

  /// On computers: libmpv as before, but a file it can't open ends the load
  /// with an error, where just_audio_media_kit would wait for ever. Called
  /// after `JustAudioMediaKit.ensureInitialized()`.
  static void initDesktop() {
    final mpv = JustAudioPlatform.instance;
    if (mpv is! JustAudioMediaKit) return;
    JustAudioPlatform.instance = RoutingAudioPlatform(preferred: mpv, fallback: mpv, wantsFallback: (_) => true);
  }

  /// Loads [path] into [player] as `setFilePath` does; on a computer, a file
  /// the player can't open is played from a copy FFmpeg converts, if it can.
  static Future<Duration?> load(AudioPlayer player, String path) async {
    try {
      return await player.setFilePath(path);
    } on PlayerInterruptedException {
      rethrow;
    } on Exception catch (e) {
      if (!_desktop) rethrow;
      final copy = await convertedCopy(path);
      if (copy == null) rethrow;
      debugPrint('Audio: playing a converted copy of $path ($e)');
      return player.setFilePath(copy);
    }
  }

  static bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// A FLAC copy of [path] in the temporary folder, made by FFmpeg; null
  /// without FFmpeg or if it can't read the file either. Made once per
  /// version of the file.
  static Future<String?> convertedCopy(String path) async {
    final ffmpeg = await ImageConverter.ffmpeg();
    if (ffmpeg == null) return null;
    final stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    final key = sha1.convert(utf8.encode('$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}')).toString();
    final folder = Directory(p.join(Directory.systemTemp.path, 'folders_audio'));
    final copy = File(p.join(folder.path, '$key.flac'));
    if (await copy.exists()) return copy.path;
    await folder.create(recursive: true);
    // Yesterday's copies go.
    await for (final old in folder.list()) {
      if (old is File && DateTime.now().difference((await old.stat()).modified).inDays >= 1) {
        await old.delete().catchError((Object _) => old);
      }
    }
    final part = File('${copy.path}.part');
    try {
      final result = await Process.run(ffmpeg, ['-v', 'error', '-y', '-i', path, '-vn', '-c:a', 'flac', '-f', 'flac', part.path]);
      if (result.exitCode != 0 || !await part.exists()) return null;
      await part.rename(copy.path);
      return copy.path;
    } on ProcessException {
      return null;
    } finally {
      if (await part.exists()) await part.delete();
    }
  }

  /// Why [path] can't play here, when it's known in advance; else null.
  static String? whyNot(String path, {bool? android}) {
    if (!(android ?? Platform.isAndroid)) return null;
    if (!androidUnplayable.contains(_extension(path))) return null;
    return "Android can't play CAF files (Apple's Core Audio format). Convert it to another format on a computer, "
        'or open it with another app.';
  }
}
