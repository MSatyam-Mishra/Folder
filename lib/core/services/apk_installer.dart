import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:folders/shared/ui/app_sheet.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Installs APKs with Android's installer (`ApkInstallNative.kt`, channel
/// `explorer/apk_install`). Since Android 8 the user allows each app that
/// installs others ("Install unknown apps"); until then this explains, opens
/// that switch for Folders, and carries on once the user is back.
abstract final class ApkInstaller {
  @visibleForTesting
  static const channel = MethodChannel('explorer/apk_install');

  /// Whether [path] is an APK that Android's installer takes (not split
  /// bundles like .apks or .xapk).
  static bool isApk(String path) => p.extension(path).toLowerCase() == '.apk';

  /// Where this applies: Android.
  static bool get applies => Platform.isAndroid;

  static Future<bool> canInstall() async => await channel.invokeMethod<bool>('canInstall') ?? false;

  /// Opens "Install unknown apps" for Folders; whether it's on when the user
  /// comes back.
  static Future<bool> openSettings() async => await channel.invokeMethod<bool>('openSettings') ?? false;

  /// Opens Android's installer on [file], asking for "Install unknown apps"
  /// first when it's off. Says in a snack bar what went wrong, if anything.
  static Future<void> install(BuildContext context, File file) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String text) => messenger?.showSnackBar(SnackBar(content: Text(text)));
    try {
      if (!await canInstall()) {
        if (!context.mounted) return;
        final go = await AppSheet.show<bool>(context, child: const AllowInstallsView());
        if (go != true) return;
        if (!await openSettings()) {
          say("Folders still can't install apps. Turn on Allow from this source to install ${p.basename(file.path)}.");
          return;
        }
      }
      final opened = await channel.invokeMethod<bool>('install', {'path': file.path}) ?? false;
      if (!opened) say('No installer took ${p.basename(file.path)}');
    } on PlatformException catch (e) {
      say("Couldn't install ${p.basename(file.path)}: ${e.message ?? e.code}");
    }
  }
}

/// Why Android asks, and the way to its switch. Closes with true for "Open
/// settings".
class AllowInstallsView extends StatelessWidget {
  const AllowInstallsView({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(LucideIcons.package, size: 20, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(child: Text('Allow Folders to install apps', style: text.titleMedium)),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Android asks you to allow each app that installs others. Turn on Allow from this source for Folders, '
          'then come back: the installation goes on from there.',
          style: text.bodyMedium,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(LucideIcons.settings, size: 18),
          label: const Text('Open settings'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => Navigator.pop(context, false),
          icon: const Icon(LucideIcons.x, size: 18),
          label: const Text('Not now'),
        ),
      ],
    );
  }
}
