import 'package:flutter/services.dart';

/// Hides and brings back the status and navigation bars for full-screen pages.
/// One page leaving and the next arriving can overlap, so these run in the
/// order they're asked for.
abstract final class SystemBars {
  static Future<void> _last = Future.value();

  static Future<void> hide() => _then(() => SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));

  /// Going straight from full screen to edgeToEdge leaves them hidden on
  /// Android, as it doesn't undo the hiding: so every overlay is shown first.
  static Future<void> show() => _then(() async {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      });

  static Future<void> _then(Future<void> Function() step) => _last = _last.then((_) async {
        try {
          await step();
        } on PlatformException {
          // Nothing to hide here, and the next one must still run.
        } on MissingPluginException {
          // Computers have no such bars.
        }
      });
}
