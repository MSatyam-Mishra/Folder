@TestOn('mac-os')
library;

import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/shared/widgets/tasks_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// The Tasks view on macOS: while work goes on, Quit anyway asks first and
/// then quits (Close would only show the view again).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    BackgroundTasks.instance.reset();
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  /// The Tasks view as main.dart shows it: in the app's builder, over the
  /// app's own navigator.
  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(460, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = AppThemeSettings.defaults();
    await tester.pumpWidget(
      ShadApp.custom(
        themeMode: ThemeMode.light,
        theme: AppTheme.shad(settings, Brightness.light),
        darkTheme: AppTheme.shad(settings, Brightness.dark),
        appBuilder: (context) => MaterialApp(
          theme: AppTheme.material(Theme.of(context), ShadTheme.of(context)),
          localizationsDelegates: const [
            GlobalShadLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) => ShadAppBuilder(
            child: Stack(
              fit: StackFit.expand,
              children: [Offstage(child: child!), const TasksView()],
            ),
          ),
          home: const SizedBox.shrink(),
        ),
      ),
    );
  }

  // Running tasks spin, so pumpAndSettle would never settle.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  // OutlinedButton.icon builds a subtype of OutlinedButton.
  Finder quitAnyway() =>
      find.ancestor(of: find.text('Quit anyway'), matching: find.bySubtype<OutlinedButton>());

  testWidgets('Quit anyway asks, and Cancel keeps the app running', (tester) async {
    BackgroundTasks.instance.start('Copying');
    BackgroundTasks.instance.start('Converting');
    await show(tester);
    expect(find.text('2 running'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Close'), findsNothing);
    expect(
      find.descendant(of: quitAnyway(), matching: find.byIcon(LucideIcons.power)),
      findsOneWidget,
    );

    await tester.tap(quitAnyway());
    await settle(tester);
    expect(find.text('Quit and stop 2 tasks?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await settle(tester);
    expect(find.text('Quit and stop 2 tasks?'), findsNothing);
    expect(calls, isNot(contains('destroy')));
  });

  testWidgets('confirming quits while work goes on', (tester) async {
    BackgroundTasks.instance.start('Copying');
    await show(tester);
    await tester.tap(quitAnyway());
    await settle(tester);
    expect(find.text('Quit and stop 1 task?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Quit'));
    await settle(tester);
    expect(calls, containsAllInOrder(['setPreventClose', 'destroy']));
  });

  testWidgets('with nothing running, the button is Quit as before', (tester) async {
    final task = BackgroundTasks.instance.start('Copying');
    BackgroundTasks.instance.finish(task);
    await show(tester);
    expect(find.text('All done'), findsOneWidget);
    expect(quitAnyway(), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Quit'), findsOneWidget);
  });
}
