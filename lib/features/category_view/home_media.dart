import 'dart:io';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';

/// Photos, videos and music in the user's home folders: the media
/// categories on Windows and Linux, which have no media library, and audio
/// and loose videos on macOS, whose Photos library has neither.
abstract final class HomeMedia {
  /// Files of [type] in the usual home folders, newest first.
  static Future<List<DeviceFile>> find(RequestType type) async {
    final (folders, extensions) = switch (type) {
      RequestType.image => (
        const ['Pictures', 'Downloads', 'Desktop'],
        {...FileTypes.image, ...FileTypes.rasterImage, ...FileTypes.cameraRaw},
      ),
      RequestType.video => (
        [Platform.isMacOS ? 'Movies' : 'Videos', 'Downloads', 'Desktop'],
        FileTypes.video,
      ),
      _ => (const ['Music', 'Downloads'], FileTypes.audio),
    };
    final files = await DeviceFiles.findInHome(folders, extensions);
    if (!Platform.isMacOS) return files;
    return [
      for (final file in files)
        if (!insideMacPackage(file.path)) file,
    ];
  }

  /// Whether [path] is inside a macOS package (an iMovie or Photos library,
  /// a GarageBand project, an app...). Finder shows a package as one item,
  /// so the media inside it isn't listed on its own.
  @visibleForTesting
  static bool insideMacPackage(String path) =>
      p.split(p.dirname(path)).any(FileTypes.isMacPackage);
}
