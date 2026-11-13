import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart' show fileActionsService;

/// Deletes what the user chose in a tool (the Storage analyzer, Folder sync)
/// the way the browser does, through its repository, so a change there (a
/// Trash, say) reaches the tools too.
abstract final class AppDelete {
  /// In place of the browser's delete, for tests.
  @visibleForTesting
  static Future<void> Function(String path)? override;

  /// Deletes [path], a folder with all it holds.
  static Future<void> delete(String path) {
    final override = AppDelete.override;
    if (override != null) return override(path);
    return fileActionsService.repository.delete(path, recursive: true);
  }
}
