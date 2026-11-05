import 'dart:async';
import 'dart:io';

import 'package:folder/core/platform/desktop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A folder to show, or a file to view over its folder, as
/// [Desktop.parseArgs] gives it.
typedef OpenTarget = ({String? folder, String? file});

/// What Finder asks Folder to open on macOS ("Open With", or items
/// dropped on the Dock icon). macOS sends these as events rather than on
/// the command line; macos/Runner/AppDelegate.swift keeps the ones that
/// arrive before Dart has taken the launch items.
abstract final class MacosOpenFiles {
  static const _channel = MethodChannel('explorer/open_files');

  /// macOS only; widget tests have no app delegate.
  static final bool supported =
      !kIsWeb && Platform.isMacOS && !Platform.environment.containsKey('FLUTTER_TEST');

  /// Opens a window of its own for an item; tests replace it.
  @visibleForTesting
  static Future<void> Function({String? folder, String? file}) openWindow =
      Desktop.openWindow;

  /// What this window starts with: [launch] (from the command line), or
  /// else the first item Finder sent at launch. Finder's other items open
  /// in windows of their own, and so do items sent while the app runs.
  static Future<OpenTarget> launchTarget(OpenTarget launch) async {
    if (!supported) return launch;
    // Listen first, so nothing sent right after the launch items is lost.
    _channel.setMethodCallHandler(handleCall);
    final sent = sort(launch, await takeInitial());
    sent.others.forEach(_open);
    return sent.launch;
  }

  /// The items Finder sent at launch (once). The app delegate answers when
  /// launching has finished, as macOS hands them over at its very end.
  /// Empty off macOS.
  static Future<List<String>> takeInitial() async {
    if (!supported) return const [];
    try {
      final paths = await _channel
          .invokeListMethod<String>('takeInitial')
          .timeout(const Duration(seconds: 3));
      return paths ?? const [];
    } on PlatformException catch (e) {
      debugPrint('Finder open: $e');
      return const [];
    } on MissingPluginException {
      return const [];
    } on TimeoutException {
      return const [];
    }
  }

  /// `open` {paths} from the app delegate: items Finder sent while the app
  /// runs, each opened in a new window.
  @visibleForTesting
  static Future<void> handleCall(MethodCall call) async {
    if (call.method != 'open') return;
    final args = call.arguments;
    final paths = args is Map ? args['paths'] : null;
    if (paths is! List) return;
    targets(paths.whereType<String>()).forEach(_open);
  }

  /// Splits what Finder sent at launch ([paths]) into what this window
  /// shows and what opens in windows of its own. An item from the command
  /// line ([launch], e.g. a window opened by [Desktop.openWindow]) wins, and
  /// Finder's are then dropped.
  static ({OpenTarget launch, List<OpenTarget> others}) sort(
    OpenTarget launch,
    List<String> paths,
  ) {
    if (launch.folder != null || launch.file != null) {
      return (launch: launch, others: const []);
    }
    final found = targets(paths);
    if (found.isEmpty) return (launch: launch, others: const []);
    return (launch: found.first, others: found.sublist(1));
  }

  /// The folders and files among [paths] that exist, without repeats.
  static List<OpenTarget> targets(Iterable<String> paths) {
    final found = <OpenTarget>[];
    for (final path in paths.toSet()) {
      // Finder gives absolute paths; anything else could read as a flag.
      if (!p.isAbsolute(path)) continue;
      final target = Desktop.parseArgs([path]);
      if (target.folder != null) found.add(target);
    }
    return found;
  }

  static void _open(OpenTarget target) {
    openWindow(folder: target.folder, file: target.file).catchError(
      (Object e) => debugPrint('Finder open: $e'),
    );
  }
}
