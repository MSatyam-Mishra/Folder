import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The phone's menu, at the top of the app, where Android would take Back for
/// itself and leave the app.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('while the menu is open Back is the app\'s, and closes it', (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(themedApp(Scaffold(
      key: scaffold,
      drawer: const AppSidebar(child: Text('The menu')),
      body: const Text('The page'),
    )));
    await tester.pumpAndSettle();
    final route = ModalRoute.of(scaffold.currentContext!)!;
    expect(route.popDisposition, RoutePopDisposition.bubble, reason: 'closed: Android may leave the app');

    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(find.text('The menu'), findsOneWidget);
    expect(route.popDisposition, RoutePopDisposition.doNotPop, reason: 'open: Android must ask the app');

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('The menu'), findsNothing);
    expect(find.text('The page'), findsOneWidget);
    expect(route.popDisposition, RoutePopDisposition.bubble);
  });
}
