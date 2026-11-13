import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/file_explorere/widgets/batch_rename_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// F2 with several items selected: the batch rename, its preview and its
/// checks, then Undo.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('batch_rename_screen_test');
    for (final name in ['alpha.txt', 'beta.txt', 'gamma.txt', 'Trip 03.txt']) {
      await File(p.join(root.path, name)).writeAsString(name);
    }
    ExplorerPaths.startFolder = root.path;
  });

  tearDown(() async {
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await settle(tester);
    }
    await settle(tester);
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester);
    }
    await settle(tester);
    return bloc;
  }

  Future<void> click(WidgetTester tester, String name, {int buttons = kPrimaryButton}) async {
    await tester.tap(find.text(name).last, kind: PointerDeviceKind.mouse, buttons: buttons);
    await tester.pump();
  }

  Future<void> selectThree(WidgetTester tester) async {
    await click(tester, 'alpha.txt');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(tester, 'gamma.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  Set<String> names() => {for (final e in root.listSync()) p.basename(e.path)};

  testWidgets('F2 on several: a pattern, a preview, Rename, then Undo', (tester) async {
    await open(tester);
    await selectThree(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(tester, () => find.byType(BatchRenameDialog).evaluate().isNotEmpty);
    expect(find.text('Rename 3 items'), findsOneWidget);
    expect(find.text('0 will change'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('batch-pattern')), 'Trip {n}');
    await tester.pump();
    // Two digits at first; the numbers follow the order shown.
    expect(find.text('Trip 01.txt'), findsOneWidget);
    expect(find.text('Trip 02.txt'), findsOneWidget);
    // Trip 03.txt is already there, and isn't being renamed.
    expect(find.text('1 problem'), findsOneWidget);
    expect(find.text('Already in the folder'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Rename')).onPressed, isNull);

    // Starting at 4 clears it.
    await tester.enterText(find.widgetWithText(TextField, 'Start at'), '4');
    await tester.pump();
    expect(find.text('3 will change'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await until(tester, () => names().contains('Trip 06.txt'));
    expect(names(), {'Trip 03.txt', 'Trip 04.txt', 'Trip 05.txt', 'Trip 06.txt'});
    expect(File(p.join(root.path, 'Trip 04.txt')).readAsStringSync(), 'alpha.txt');
    await until(tester, () => find.text('Renamed 3 items').evaluate().isNotEmpty);
    expect(find.text('Trip 05.txt'), findsOneWidget, reason: 'the folder shows the new names');

    await tester.tap(find.text('Undo'));
    await until(tester, () => names().contains('alpha.txt'));
    expect(names(), {'alpha.txt', 'beta.txt', 'gamma.txt', 'Trip 03.txt'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('find and replace, case, and names given twice', (tester) async {
    await open(tester);
    await selectThree(tester);
    await click(tester, 'beta.txt', buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Rename…'), findsOneWidget);
    await tester.tap(find.text('Rename…'));
    await until(tester, () => find.byType(BatchRenameDialog).evaluate().isNotEmpty);

    await tester.enterText(find.widgetWithText(TextField, 'Find'), 'a');
    await tester.enterText(find.widgetWithText(TextField, 'Replace with'), '_');
    await tester.pump();
    expect(find.text('_lph_.txt'), findsOneWidget);
    await tester.tap(find.text('UPPER'));
    await tester.pump();
    expect(find.text('_LPH_.txt'), findsOneWidget, reason: 'the extension keeps its case');

    await tester.enterText(find.byKey(const ValueKey('batch-pattern')), 'same');
    await tester.pump();
    expect(find.text('3 problems'), findsOneWidget);
    expect(find.text('Same name as another'), findsNWidgets(3));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await settle(tester);
    expect(names(), {'alpha.txt', 'beta.txt', 'gamma.txt', 'Trip 03.txt'});
    await tester.pumpWidget(const SizedBox());
  });
}
