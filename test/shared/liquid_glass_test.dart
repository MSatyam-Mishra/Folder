import 'package:folder/core/theme/theme_cubit.dart';
import 'package:folder/shared/ui/app_glass.dart';
import 'package:folder/shared/ui/app_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Liquid glass, an option on phones.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ThemeCubit> open(WidgetTester tester, TargetPlatform platform) async {
    debugDefaultTargetPlatformOverride = platform;
    late BuildContext page;
    await tester.pumpWidget(themedApp(
      AppTopBarScaffold(
        topBarBuilder: (_) => const Text('The bar'),
        floatingActionButton: AppFab(tooltip: 'New', icon: Icons.add, onPressed: () {}),
        drawer: const AppSidebar(child: Text('The drawer')),
        body: Builder(builder: (context) {
          page = context;
          return ElevatedButton(
            onPressed: () => AppSheet.show<void>(context, child: const Text('The sheet')),
            child: const Text('Open'),
          );
        }),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    return page.read<ThemeCubit>();
  }

  Finder glassAround(String text) =>
      find.ancestor(of: find.text(text), matching: find.byType(LiquidGlass));

  testWidgets('on a phone the bar, the button and sheets are glass, until switched off', (tester) async {
    final cubit = await open(tester, TargetPlatform.android);
    expect(glassAround('The bar'), findsOneWidget);
    expect(find.ancestor(of: find.byType(FloatingActionButton), matching: find.byType(LiquidGlass)), findsOneWidget);

    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(glassAround('The sheet'), findsOneWidget);
    Navigator.of(tester.element(find.text('The sheet'))).pop();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.runAsync(() => cubit.setLiquidGlass(false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LiquidGlass), findsNothing, reason: 'off: solid bars and buttons');
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(glassAround('The sheet'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("a bottom sheet has one edge at its top corners: the glass's, not the theme's too", (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, TargetPlatform.android);
    await tester.tap(find.text('Open'));
    await tester.pump(const Duration(milliseconds: 500));
    final sheet = find.ancestor(of: find.text('The sheet'), matching: find.byType(BottomSheet));
    final shape = tester.widget<BottomSheet>(sheet).shape! as RoundedRectangleBorder;
    expect(shape.side, BorderSide.none);
    expect(shape.borderRadius, tester.widget<LiquidGlass>(glassAround('The sheet')).borderRadius);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the choice is remembered', (tester) async {
    final cubit = await open(tester, TargetPlatform.android);
    expect(cubit.state.liquidGlass, isTrue);
    await tester.runAsync(() => cubit.setLiquidGlass(false));
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getBool('liquid_glass'), isFalse);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("computers keep their window effect's look", (tester) async {
    await open(tester, TargetPlatform.windows);
    expect(find.byType(LiquidGlass), findsNothing);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
