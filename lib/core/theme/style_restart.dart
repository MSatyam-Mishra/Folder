import 'package:folders/core/platform/background_mode.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Starting the app again, for a style whose icons only show from the start
/// (IconStrokes). Computers can: a new window opens on the same folder, and
/// this one closes as its close button would, so work still going on carries
/// on in the tray (Windows) or a Tasks window. Phones can't do it cleanly
/// from inside the app, so they say when the icons will show instead.
abstract final class StyleRestart {
  static bool get supported => Desktop.isDesktop;

  /// Closes this window as its close button does; tests replace it.
  @visibleForTesting
  static Future<void> Function() closeWindow = () => BackgroundMode.instance.close();

  /// Opens the new window on [folder] (a folder on disk, or none for the
  /// usual start), then closes this one.
  static Future<void> restart({String? folder}) async {
    await Desktop.openWindow(folder: folder);
    await closeWindow();
  }
}
