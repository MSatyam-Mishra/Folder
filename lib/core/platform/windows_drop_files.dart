import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;

/// A drop's files as its source gives them at the moment of the drop (Windows,
/// `windows/runner/drop_files.cpp`). The plugin reads them when the drag enters
/// the window, too early for WinRAR: that's only names inside the archive,
/// and it extracts the files when asked at the drop.
abstract final class WindowsDropFiles {
  static const _channel = MethodChannel('explorer/drop');

  /// Sets it up; the plugin's drop target must exist first.
  static Future<void> init() async {
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      await raw.DropContext.instance();
      final wrapped = await _channel.invokeMethod<bool>('wrap');
      if (wrapped != true) debugPrint('The drop target could not be wrapped');
    } catch (e) {
      debugPrint('Drop files: $e');
    }
  }

  /// The last drop's files; empty if unknown, as elsewhere than on Windows.
  static Future<List<String>> last() async {
    if (!Platform.isWindows) return const [];
    try {
      return await _channel.invokeListMethod<String>('lastFiles') ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }
}
