import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DirectoryService {
  /// The user's Downloads folder (on Android the shared `Download` folder,
  /// not the app's private one).
  static Future<Directory?> findDownloadsDirectory() async {
    if (Platform.isAndroid) {
      for (final name in const ['Download', 'Downloads']) {
        final dir = Directory(p.join(ExplorerPaths.androidInternalStorage, name));
        if (await dir.exists()) return dir;
      }
      return null;
    }
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null) {
        final downloads = Directory(p.join(profile, 'Downloads'));
        if (await downloads.exists()) return downloads;
      }
    }
    try {
      return await getDownloadsDirectory();
    } catch (e) {
      debugPrint('No downloads directory: $e');
      return null;
    }
  }
}
