import 'dart:io';

import 'package:folders/features/category_view/bloc/bloc/screens/category_viewer_screen.dart';
import 'package:folders/features/tools/screens/app_manager_screen.dart';
import 'package:folders/features/tools/screens/usb_boot_screen.dart';
import 'package:folders/features/vault/screens/vault_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  late Directory sample;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    sample = await Directory.systemTemp.createTemp('category_shots_');
    var i = 0;
    for (final name in [
      'Invoice 0425.pdf', 'Trip itinerary.docx', 'Expenses.xlsx',
      'Notes.md', 'Scan 12.pdf', 'Slides.pptx', 'Contract draft.docx',
    ]) {
      final file = File(p.join(sample.path, name));
      await file.writeAsBytes(List.filled(1024 * (12 + i * 37), 65));
      await file.setLastModified(
        DateTime.now().subtract(Duration(hours: 2 + i * 20)),
      );
      i++;
    }
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await sample.delete(recursive: true);
  });

  const apps = [
    ('Calendar', 'com.example.calendar', '3.2.1', false),
    ('Camera', 'com.example.camera', '12.0', true),
    ('Chess', 'org.example.chess', '1.4.0', false),
    ('Maps', 'com.example.maps', '11.104.0', false),
    ('Music', 'com.example.music', '8.21', false),
    ('Notes', 'com.example.notes', '2.0.3', false),
    ('Settings', 'com.android.settings', '14', true),
    ('Weather', 'com.example.weather', '5.1', false),
  ];

  void mockInstalledApps() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('installed_apps'),
            (call) async {
      if (call.method != 'getInstalledApps') return null;
      return [
        for (final (name, package, version, system) in apps)
          {
            'name': name,
            'package_name': package,
            'version_name': version,
            'version_code': 1,
            'is_system_app': system,
            'is_launchable_app': true,
          },
      ];
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('installed_apps'), null),
    );
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final (device, size) in [
      ('phone', const Size(390, 844)),
      ('tablet', const Size(1280, 800)),
    ]) {
      final tag = '${mode.name}_$device';

      Future<void> shoot(
        WidgetTester tester,
        Widget screen,
        String name, {
        int frames = 8,
      }) async {
        SharedPreferences.setMockInitialValues({});
        setScreenSize(tester, size);
        // Pushed like in the app, so the header shows a back button.
        await tester.pumpWidget(
          screenshotFrame(themedApp(_Pusher(screen), themeMode: mode)),
        );
        await settle(tester, frames: frames);
        await saveScreenshot(tester, '${name}_$tag');
      }

      testWidgets('vault $tag', (tester) async {
        await shoot(tester, const VaultScreen(), 'vault');
      }, skip: !screenshotsEnabled);

      testWidgets('usb boot $tag', (tester) async {
        await shoot(tester, const UsbBootScreen(), 'usb_boot');
      }, skip: !screenshotsEnabled);

      testWidgets('app manager $tag', (tester) async {
        mockInstalledApps();
        await shoot(tester, const AppManagerScreen(), 'app_manager');
      }, skip: !screenshotsEnabled);

      testWidgets('category files $tag', (tester) async {
        await shoot(
          tester,
          CategoryViewerScreen(
            categoryType: RequestType.common,
            title: 'Documents',
            path: sample.path,
          ),
          'category_files',
          frames: 24,
        );
      }, skip: !screenshotsEnabled);

      testWidgets('category error $tag', (tester) async {
        await shoot(
          tester,
          const CategoryViewerScreen(
            categoryType: RequestType.image,
            title: 'Photos',
          ),
          'category_error',
        );
      }, skip: !screenshotsEnabled);
    }
  }
}

/// Lets real I/O finish and animations run.
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pushes [screen] over an empty page after the first frame.
class _Pusher extends StatefulWidget {
  const _Pusher(this.screen);

  final Widget screen;

  @override
  State<_Pusher> createState() => _PusherState();
}

class _PusherState extends State<_Pusher> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => widget.screen,
          transitionDuration: Duration.zero,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
