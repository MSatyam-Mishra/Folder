import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:folders/core/services/path_changes.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart' show fileActionsService;

/// Deletes what the user chose in a tool (the Storage analyzer, Folder sync)
/// the way the browser does: to the Trash when it can go there and the
/// setting is on, else through the browser's repository.
abstract final class AppDelete {
  /// In place of the browser's delete, for tests.
  @visibleForTesting
  static Future<void> Function(String path)? override;

  /// Deletes [path], a folder with all it holds.
  static Future<void> delete(String path) async {
    final override = AppDelete.override;
    if (override != null) return override(path);
    final trash = Trash.instance;
    if (trash.canTrash(path) && await TrashSettings.enabled()) {
      final result = await trash.moveToTrash([path]);
      for (final item in result.trashed) {
        // Tags go along, so Restore brings them back.
        PathChanges.moved(item.originalPath, item.storedPath);
      }
      if (result.failed.isEmpty) return;
      // It can't go to the Trash (too big for it, a drive without one): the
      // tool's own question already asked about deleting it.
    }
    await fileActionsService.repository.delete(path, recursive: true);
  }
}
