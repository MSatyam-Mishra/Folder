import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

/// Windows, Linux and macOS support that phones don't need.
abstract final class Desktop {
  static bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Windows, Linux and macOS play video and audio with media_kit (libmpv,
  /// with FFmpeg's decoders): video in VideoPlayerPage, audio through
  /// just_audio. just_audio has no implementation of its own on Windows and
  /// Linux, and on macOS AVFoundation can't open MKV, WebM, AVI, Ogg, Opus
  /// or WMA.
  static void initMedia() {
    if (!isDesktop) {
      // Android's videos too, for their subtitles, tracks and formats; its
      // audio stays with just_audio's own player.
      MediaKit.ensureInitialized();
      return;
    }
    if (Platform.isMacOS) {
      // Mpv.framework ships inside the app (media_kit_libs_macos_video).
      // Should it be missing, keep the AVFoundation players.
      try {
        MediaKit.ensureInitialized();
      } catch (_) {
        return;
      }
      _macMediaKit = true;
    }
    String? libmpv;
    if (Platform.isLinux) {
      // The AppImage, the Flatpak and the archives carry their own libmpv
      // next to the app's libraries; the .deb, .rpm and snap use the
      // system's.
      final bundled = p.join(
        p.dirname(Platform.resolvedExecutable),
        'lib',
        'libmpv.so.2',
      );
      if (File(bundled).existsSync()) libmpv = bundled;
    }
    // Throws when libmpv can't be found (the packages ship it, or depend on
    // the system's). On macOS it's already loaded, so this does nothing.
    MediaKit.ensureInitialized(libmpv: libmpv);
    JustAudioMediaKit.ensureInitialized(
      windows: true,
      linux: true,
      macOS: true,
      libmpv: libmpv,
    );
  }

  /// Whether libmpv has loaded on a Mac, where it's the one thing that can fail.
  static bool get macMediaKit => _macMediaKit;
  static bool _macMediaKit = false;

  /// Whether files can be shared with other apps (share_plus shares only
  /// text on Linux).
  static bool get canShareFiles => !Platform.isLinux;

  /// Whether flutter_inappwebview works here (it has no Linux version).
  static bool get webViewsSupported => !Platform.isLinux;

  static const _folderFlag = '--folder=';

  /// Opens another Folder window showing [folder], or viewing [file]
  /// (over its folder). Each window is its own process, so it keeps working
  /// if another one closes.
  static Future<void> openWindow({String? folder, String? file}) {
    final (executable, args) = windowCommand(
      Platform.resolvedExecutable,
      [
        if (file != null)
          file
        else if (folder != null)
          '$_folderFlag$folder',
      ],
      macOS: Platform.isMacOS,
    );
    return launcher(executable, args);
  }

  /// How [openWindow] starts [executable] with [args]. On macOS a new
  /// window goes through LaunchServices (`open -n`, a new instance of the
  /// app), so it comes to the front: the bare binary inside Folder.app
  /// would open behind the current window.
  @visibleForTesting
  static (String, List<String>) windowCommand(
    String executable,
    List<String> args, {
    required bool macOS,
  }) {
    if (macOS) {
      // <bundle>.app/Contents/MacOS/<name>
      final macosDir = p.posix.dirname(executable);
      final contents = p.posix.dirname(macosDir);
      final bundle = p.posix.dirname(contents);
      if (p.posix.basename(macosDir) == 'MacOS' &&
          p.posix.basename(contents) == 'Contents' &&
          p.posix.extension(bundle) == '.app') {
        return (
          '/usr/bin/open',
          ['-n', bundle, if (args.isNotEmpty) ...['--args', ...args]],
        );
      }
    }
    return (executable, args);
  }

  /// Starts a window; tests replace it.
  @visibleForTesting
  static Future<void> Function(String executable, List<String> args) launcher =
      (executable, args) =>
          Process.start(executable, args, mode: ProcessStartMode.detached);

  /// What the command line asks to open: a folder (from [openWindow], or a
  /// folder passed by the system) or a file to view.
  static ({String? folder, String? file}) parseArgs(List<String> args) {
    for (final arg in args) {
      if (arg.startsWith(_folderFlag)) {
        return (folder: arg.substring(_folderFlag.length), file: null);
      }
      if (arg.startsWith('-')) continue;
      if (FileSystemEntity.isDirectorySync(arg)) {
        return (folder: p.absolute(arg), file: null);
      }
      if (FileSystemEntity.isFileSync(arg)) {
        return (folder: p.dirname(p.absolute(arg)), file: p.absolute(arg));
      }
    }
    return (folder: null, file: null);
  }
}
