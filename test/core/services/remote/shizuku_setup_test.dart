import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/shizuku/shizuku.dart';
import 'package:folders/core/services/remote/shizuku/shizuku_setup.dart';
import 'package:folders/shared/ui/app_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/themed_app.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> show(WidgetTester tester, ShizukuStatus status) async {
    await tester.pumpWidget(themedApp(Scaffold(body: ShizukuSetupView(key: UniqueKey(), initial: status, check: () async => status))));
    await tester.pump();
  }

  testWidgets('each step says what to do next', (tester) async {
    await show(tester, const ShizukuStatus());
    expect(find.text('First, install Shizuku'), findsOneWidget);
    expect(find.text('Get Shizuku'), findsOneWidget);
    expect(find.text('Download it from its site'), findsOneWidget);

    await show(tester, const ShizukuStatus(installed: true, appInstalled: true));
    expect(find.text('Start Shizuku'), findsOneWidget);
    expect(find.textContaining('Wireless debugging'), findsOneWidget);
    expect(find.text('Open Shizuku'), findsOneWidget);
    expect(find.text('How to start it'), findsOneWidget);

    await show(tester, const ShizukuStatus(installed: true, running: true, version: 13));
    expect(find.text('Let Folders use Shizuku'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);

    await show(tester, const ShizukuStatus(installed: true, running: true, version: 13, denied: true));
    expect(find.text('Folders was refused'), findsOneWidget);

    await show(tester, const ShizukuStatus(installed: true, running: true, version: 10));
    expect(find.text('Update Shizuku'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
  });

  testWidgets('closes with true once Shizuku is ready', (tester) async {
    var status = const ShizukuStatus(installed: true, running: true, version: 13);
    bool? result;
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await AppSheet.show<bool>(
            context,
            child: ShizukuSetupView(initial: status, check: () async => status),
          ),
          child: const Text('go'),
        ),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Let Folders use Shizuku'), findsOneWidget);
    status = const ShizukuStatus(installed: true, running: true, version: 13, granted: true);
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  test('App folders are offered on Android only, with no host or password', () {
    final info = shizukuProtocolInfo();
    expect(info.protocol, RemoteProtocol.shizuku);
    expect(info.needsHost, isFalse);
    expect(info.usesPassword, isFalse);
    expect(info.signIn, isNotNull);
    expect(info.available, isFalse, reason: 'tests run on a computer');
  });
}
