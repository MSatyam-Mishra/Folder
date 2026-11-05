import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// This app used to be called Explorer, and computers keep an app's data in a
/// folder named after it: its settings, its vault, what it downloaded. So that
/// nothing seems to be lost, that folder moves across at the first start under
/// the new name. Phones and sandboxes (Android, MSIX, Flatpak, snap) keep each
/// app's data apart, so there's nothing there to reach.
abstract final class OldAppData {
  static Future<void> moveAcross() async {
    final String oldName;
    if (Platform.isWindows) {
      oldName = 'Explorer';
    } else if (Platform.isLinux || Platform.isMacOS) {
      oldName = 'com.synqixlabs.explory';
    } else {
      return;
    }
    try {
      final now = await getApplicationSupportDirectory();
      await moveFolder(Directory(p.join(now.parent.path, oldName)), now);
    } catch (e) {
      debugPrint('Moving the old app data: $e');
    }
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
