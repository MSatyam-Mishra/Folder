import 'package:folder/core/services/toolbox/app_closer.dart';
import 'package:folder/core/services/toolbox/ram_cleaner.dart';
import 'package:folder/features/toolbox/ram_extreme_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The RAM cleaner's Extreme mode: what Play closes, what it says afterwards,
/// and the screen against a stand-in for the Android side.
void main() {
  const apps = [
    ClosableApp(package: 'a.user', label: 'Notes', running: true),
    ClosableApp(package: 'b.system', label: 'Camera', system: true, running: true),
    ClosableApp(package: 'c.stopped', label: 'Stopped'),
    ClosableApp(package: 'd.user', label: 'Game', running: true),
  ];

  List<String> closes(ExtremeSettings settings) =>
      [for (final app in AppCloser.appsToClose(apps, settings)) app.package];

  group('what Play closes', () {
    test('all apps: the launched ones of the kinds switched on, less the exceptions', () {
      expect(closes(const ExtremeSettings()), ['a.user', 'd.user'], reason: 'system apps are off at first');
      expect(closes(const ExtremeSettings(systemApps: true)), ['a.user', 'b.system', 'd.user']);
      expect(closes(const ExtremeSettings(userApps: false, systemApps: true)), ['b.system']);
      expect(closes(const ExtremeSettings(exceptions: {'d.user'})), ['a.user']);
      expect(closes(const ExtremeSettings(userApps: false)), isEmpty);
    });

    test('a custom list: those alone, of any kind, if they are launched', () {
      expect(
        closes(const ExtremeSettings(scope: CloseScope.custom, custom: {'b.system', 'c.stopped'})),
        ['b.system'],
      );
      expect(closes(const ExtremeSettings(scope: CloseScope.custom)), isEmpty);
    });
  });

  test('the choices are kept', () async {
    SharedPreferences.setMockInitialValues({});
    await const ExtremeSettings(
      systemApps: true,
      scope: CloseScope.custom,
      exceptions: {'a'},
      custom: {'b', 'c'},
    ).save();
    final loaded = await ExtremeSettings.load();
    expect(loaded.userApps, isTrue);
    expect(loaded.systemApps, isTrue);
    expect(loaded.scope, CloseScope.custom);
    expect(loaded.exceptions, {'a'});
    expect(loaded.custom, {'b', 'c'});
  });

  test('what it says afterwards is what was measured', () {
    const mb = 1024 * 1024;
    expect(
      describeClosing(asked: 3, stopped: 3, cancelled: false, freed: 300 * mb),
      'Closed 3 apps. Free memory went up by 300 MB.',
    );
    expect(
      describeClosing(asked: 3, stopped: 2, cancelled: false, freed: 0),
      "Closed 2 apps. 1 app didn't close, or started again. Free memory is about the same.",
    );
    expect(
      describeClosing(asked: 5, stopped: 1, cancelled: true, freed: 0),
      'Cancelled after closing 1 app. Free memory is about the same.',
    );
  });

  group('the screen', () {
    const channel = MethodChannel('explorer/app_closer');
    late bool serviceOn;
    late List<Map<String, Object?>> installed;
    late List<String> closed;
    late List<String> opened;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      serviceOn = true;
      closed = [];
      opened = [];
      installed = [
        for (final app in apps)
          {'package': app.package, 'label': app.label, 'system': app.system, 'running': app.running},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'status':
            return serviceOn;
          case 'apps':
            return installed;
          case 'close':
            final asked = (call.arguments as Map)['apps'] as List;
            closed = [for (final app in asked) (app as Map)['package'] as String];
            installed = [
              for (final app in installed)
                closed.contains(app['package']) ? {...app, 'running': false} : app,
            ];
            return {'closed': closed.length, 'skipped': 0, 'cancelled': false};
          case 'openAccessibility':
          case 'openAppInfo':
            opened.add(call.method);
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 600));
      }
    }

    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(const Scaffold(
        body: ExtremeRamView(header: SizedBox(), stats: MemoryStats(1000 * 1024 * 1024, 460 * 1024 * 1024)),
      )));
      await settle(tester);
    }

    testWidgets('shows the gauge and how many it would close', (tester) async {
      await show(tester);
      expect(find.text('54%'), findsOneWidget);
      expect(find.text('Launched apps'), findsOneWidget);
      expect(find.text('2'), findsOneWidget, reason: 'two user apps are launched');
      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      expect(find.text('3'), findsOneWidget, reason: 'with the system apps');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('until the service is on, it says what it is and where to turn it on', (tester) async {
      serviceOn = false;
      await show(tester);
      expect(find.text('Turn on the Accessibility service'), findsOneWidget);
      expect(find.byTooltip('Close apps'), findsNothing);
      await tester.tap(find.text('Open Accessibility settings'));
      await tester.ensureVisible(find.text('Open App info'));
      await tester.pump();
      await tester.tap(find.text('Open App info'));
      await tester.pump();
      expect(opened, ['openAccessibility', 'openAppInfo']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Play closes them and reports what stopped, leaving exceptions alone', (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('Add exceptions'));
      await settle(tester);
      await tester.tap(find.text('Game'));
      await settle(tester);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      expect(find.text('Exception list (1)'), findsOneWidget);
      expect(find.text('Game'), findsOneWidget);

      await tester.tap(find.byTooltip('Close apps'));
      await settle(tester);
      await settle(tester);
      expect(closed, ['a.user']);
      expect(find.textContaining('Closed 1 app.'), findsOneWidget);
      expect(find.text('Launched apps'), findsOneWidget);
      expect(find.text('0'), findsOneWidget, reason: 'nothing left to close');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with nothing to close it says so, and asks nothing of Android', (tester) async {
      installed = [];
      await show(tester);
      await tester.tap(find.byTooltip('Close apps'));
      await settle(tester);
      expect(find.text('No launched apps to close.'), findsOneWidget);
      expect(closed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
