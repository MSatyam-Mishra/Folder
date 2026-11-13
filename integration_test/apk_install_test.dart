import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/apk_installer.dart';
import 'package:folders/core/services/remote/shizuku/shizuku.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On an Android device without Shizuku and with "Install unknown apps" off
/// for Folders: `flutter test integration_test/apk_install_test.dart -d DEVICE`.
/// Meanwhile, put Shizuku's APK at `<app's external files>/shizuku.apk` (the
/// test waits for it), turn the switch on when Settings shows it, press
/// Back, and tap Install. The test ends once Shizuku is installed.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an APK goes to Android installer, after Install unknown apps', (tester) async {
    final apk = await tester.runAsync(() async {
      final folder = await getExternalStorageDirectory();
      final file = File('${folder!.path}/shizuku.apk');
      debugPrint('APK: waiting for ${file.path}');
      for (var i = 0; i < 240 && !file.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      return file;
    });
    expect(apk!.existsSync(), isTrue);
    expect(await tester.runAsync(ApkInstaller.canInstall), isFalse, reason: 'start with the switch off');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(onPressed: () => ApkInstaller.install(context, apk), child: const Text('Install')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(find.text('Allow Folders to install apps'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    debugPrint('APK: Settings open');

    final allowed = await tester.runAsync(() async {
      for (var i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (await ApkInstaller.canInstall()) return true;
      }
      return false;
    });
    expect(allowed, isTrue, reason: 'Install unknown apps turned on in Settings');
    debugPrint('APK: allowed');
    final installed = await tester.runAsync(() async {
      for (var i = 0; i < 180; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final status = await Shizuku.status();
        if (i % 10 == 0) debugPrint('APK: Shizuku installed: ${status.appInstalled}');
        if (status.appInstalled) return true;
      }
      return false;
    });
    expect(installed, isTrue);
    debugPrint('APK: installed');
  });
}
