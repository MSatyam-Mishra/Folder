import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// This app used to be called Explorer (up to 1.0.9), then Folder (1.0.10 and
/// 1.0.11), and computers keep an app's data in a folder named after it: its
/// settings, its vault, what it downloaded. So that nothing seems to be lost,
/// the newest old folder there is moves across at the first start under the
/// new name. Phones and sandboxes (Android, MSIX, Flatpak, snap) keep each
/// app's data apart, so there's nothing there to reach.
abstract final class OldAppData {
  /// The data folder's old names, newest first.
  @visibleForTesting
  static List<String> get oldNames {
    if (Platform.isWindows) return const ['Folder', 'Explorer'];
    if (Platform.isLinux || Platform.isMacOS) return const ['com.synqixlabs.folder', 'com.synqixlabs.explory'];
    return const [];
  }

  static Future<void> moveAcross() async {
    final names = oldNames;
    if (names.isEmpty) return;
    try {
      final now = await getApplicationSupportDirectory();
      await moveNewestFolder([for (final name in names) Directory(p.join(now.parent.path, name))], now);
    } catch (e) {
      debugPrint('Moving the old app data: $e');
    }
  }

  /// Moves the first of [olds] that exists to [now] (see [moveFolder]); the
  /// older ones stay, as moving two into one could mix them.
  @visibleForTesting
  static Future<bool> moveNewestFolder(List<Directory> olds, Directory now) async {
    for (final old in olds) {
      if (await old.exists()) return moveFolder(old, now);
    }
    return false;
  }

  /// Moves [old] to [now] unless [now] already holds something. False if it
  /// didn't; it throws if the system refuses, as when the old app is still open,
  /// and leaves things to try again at the next start.
  @visibleForTesting
  static Future<bool> moveFolder(Directory old, Directory now) async {
    if (!await old.exists()) return false;
    if (await now.exists()) {
      if (!await now.list().isEmpty) return false;
      await now.delete();
    }
    try {
      await old.rename(now.path);
      return true;
    } catch (_) {
      await now.create(recursive: true);
      rethrow;
    }
  }
}
