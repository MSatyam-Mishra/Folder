import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The top bar's menu icon: never one that does nothing. A screen opened by
/// itself (a link shared from another app) used to show it with no menu.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a first screen with no menu has no menu icon', (tester) async {
    await tester.pumpWidget(themedApp(const ExplorerScaffold(title: 'Alone', body: SizedBox())));
    await tester.pump();
    expect(find.text('Alone'), findsOneWidget);
    expect(find.byTooltip('Open menu'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with a menu, the icon opens it', (tester) async {
    await tester.pumpWidget(themedApp(
      const ExplorerScaffold(title: 'With one', drawer: Drawer(child: Text('The menu')), body: SizedBox()),
    ));
    await tester.pump();
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('The menu'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a screen opened from another has Back instead', (tester) async {
    await tester.pumpWidget(themedApp(Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ExplorerScaffold(title: 'On top', body: SizedBox())),
        ),
        child: const Text('Open'),
      ),
    )));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Open menu'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the bar on its own can still be given what the icon does', (tester) async {
    var opened = false;
    await tester.pumpWidget(themedApp(Scaffold(body: DockedGlossyTopBar(title: 'Bar', onMenuPressed: () => opened = true))));
    await tester.pump();
    await tester.tap(find.byTooltip('Open menu'));
    expect(opened, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
