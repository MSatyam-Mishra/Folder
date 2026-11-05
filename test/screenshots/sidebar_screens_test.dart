import 'dart:io';

import 'package:folder/core/services/auth_service.dart';
import 'package:folder/core/services/device_files.dart';
import 'package:folder/features/category_view/file_category_screen.dart';
import 'package:folder/features/network/screens/file_server_screen.dart';
import 'package:folder/features/vault/screens/vault_screen.dart';
import 'package:folder/features/vault/vault_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';
import 'viewer_shot_helpers.dart' show settle;

class _FakeAuth extends AuthService {
  _FakeAuth(this.result);
  final UnlockResult result;

  @override
  Future<UnlockResult> unlock({required String reason}) async => result;
}

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  late Directory temp;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    temp = await Directory.systemTemp.createTemp('sidebar_shots_');
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await temp.delete(recursive: true);
  });

  final now = DateTime.now();
  final documents = [
    for (final (i, name, kb, folder) in [
      (0, 'Quarterly report 2026.pdf', 2400, 'Download'),
      (1, 'Meeting notes.docx', 31, 'Documents'),
      (2, 'Budget.xlsx', 48, 'Documents'),
      (3, 'Pitch deck.pptx', 5400, 'Download'),
      (5, 'The Hobbit.epub', 820, 'Books'),
      (8, 'Lease agreement.pdf', 640, 'Documents'),
      (12, 'Expenses.csv', 12, 'Download'),
      (20, 'README.md', 3, 'Projects'),
      (30, 'Scan 0425.pdf', 1800, 'Scans'),
    ])
      DeviceFile(
        '/storage/emulated/0/$folder/$name',
        kb * 1024,
        now.subtract(Duration(hours: 3 + i * 19)),
      ),
  ];

  Future<void> pump(WidgetTester tester, Widget screen, ThemeMode mode) async {
    SharedPreferences.setMockInitialValues({});
    setScreenSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      screenshotFrame(themedApp(screen, themeMode: mode)),
    );
    await settle(tester, rounds: 6);
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    final tag = mode.name;

    testWidgets('documents $tag', (tester) async {
      await pump(
        tester,
        FileCategoryScreen(
          group: DeviceFileGroup.documents,
          loader: () async => documents,
          onShowInFolder: (_) {},
        ),
        mode,
      );
      await saveScreenshot(tester, 'documents_$tag');
    }, skip: !screenshotsEnabled);

    testWidgets('vault $tag', (tester) async {
      final store = VaultStore(
        root: Directory(p.join(temp.path, 'vault_$tag')),
      );
      await tester.runAsync(() async {
        for (final name in [
          'Passport.pdf',
          'Bank statement.pdf',
          'IMG_2041.jpg',
          'Keys.txt',
        ]) {
          final file = File(p.join(temp.path, tag, name))
            ..createSync(recursive: true)
            ..writeAsBytesSync(List.filled(40000, 1));
          await store.add(file);
        }
      });
      await pump(
        tester,
        VaultScreen(store: store, auth: _FakeAuth(UnlockResult.unlocked)),
        mode,
      );
      await settle(tester, rounds: 20);
      await saveScreenshot(tester, 'vault_$tag');
    }, skip: !screenshotsEnabled);

    testWidgets('vault locked $tag', (tester) async {
      await pump(
        tester,
        VaultScreen(
          store: VaultStore(root: Directory(p.join(temp.path, 'empty_$tag'))),
          auth: _FakeAuth(UnlockResult.failed),
        ),
        mode,
      );
      await saveScreenshot(tester, 'vault_locked_$tag');
    }, skip: !screenshotsEnabled);

    testWidgets('vault empty no lock $tag', (tester) async {
      await pump(
        tester,
        VaultScreen(
          store: VaultStore(root: Directory(p.join(temp.path, 'none_$tag'))),
          auth: _FakeAuth(UnlockResult.noScreenLock),
        ),
        mode,
      );
      await saveScreenshot(tester, 'vault_empty_$tag');
    }, skip: !screenshotsEnabled);

    for (final protocol in ShareProtocol.values) {
      testWidgets('wifi sharing ${protocol.name} $tag', (tester) async {
        await pump(
          tester,
          FileServerScreen(
            initialFolder: '/storage/emulated/0/Download',
            protocol: protocol,
          ),
          mode,
        );
        await saveScreenshot(tester, 'wifi_${protocol.name}_$tag');
      }, skip: !screenshotsEnabled);
    }

    testWidgets('wifi sharing running $tag', (tester) async {
      await pump(
        tester,
        FileServerScreen(initialFolder: temp.path, protocol: ShareProtocol.ftp),
        mode,
      );
      await tester.tap(find.text('Start sharing'));
      await settle(tester, rounds: 10);
      await saveScreenshot(tester, 'wifi_running_$tag');
      await tester.ensureVisible(find.text('Stop sharing'));
      await tester.tap(find.text('Stop sharing'));
      await settle(tester, rounds: 4);
    }, skip: !screenshotsEnabled);
  }
}
