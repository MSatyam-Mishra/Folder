import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/apk_installer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/themed_app.dart';

void main() {
  late List<MethodCall> calls;
  late bool allowed;
  late bool allowInSettings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    allowed = false;
    allowInSettings = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ApkInstaller.channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'canInstall':
          return allowed;
        case 'openSettings':
          allowed = allowInSettings;
          return allowed;
        case 'install':
          return true;
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ApkInstaller.channel, null));

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => ApkInstaller.install(context, File('/storage/emulated/0/Download/app.apk')),
          child: const Text('go'),
        ),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  test('only real APKs', () {
    expect(ApkInstaller.isApk('/a/b/App.APK'), isTrue);
    expect(ApkInstaller.isApk('/a/b/app.apks'), isFalse);
    expect(ApkInstaller.isApk('/a/b/app.xapk'), isFalse);
  });

  testWidgets('installs at once when allowed', (tester) async {
    allowed = true;
    await start(tester);
    expect(find.text('Allow Folders to install apps'), findsNothing);
    expect(calls.map((c) => c.method), ['canInstall', 'install']);
    expect(calls.last.arguments, {'path': '/storage/emulated/0/Download/app.apk'});
  });

  testWidgets('explains, opens the switch, then installs', (tester) async {
    await start(tester);
    expect(find.text('Allow Folders to install apps'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method), ['canInstall', 'openSettings', 'install']);
  });

  testWidgets('stops when the switch stays off, or the user says not now', (tester) async {
    allowInSettings = false;
    await start(tester);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method), ['canInstall', 'openSettings']);
    expect(find.textContaining("Folders still can't install apps"), findsOneWidget);

    calls.clear();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method), ['canInstall']);
  });
}
