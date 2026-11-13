import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/trash/spec_trash.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/trash/trash_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Delete moves to the Trash (here a Trash in a temporary folder, never the
/// system's), with Undo; Shift+Delete deletes for good; the Trash place
/// restores, deletes for good and empties.
void main() {
  late Directory root;
  late Directory trashDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('trash_place_test');
    trashDir = await Directory.systemTemp.createTemp('trash_place_test_bin');
    await Directory(p.join(root.path, 'Docs')).create();
    await File(p.join(root.path, 'Docs', 'inside.txt')).writeAsString('in');
    for (final name in ['alpha.txt', 'beta.txt', 'gamma.txt']) {
      await File(p.join(root.path, name)).writeAsString(name);
    }
    ExplorerPaths.startFolder = root.path;
    Trash.instance = SpecTrash.inFolder(trashDir.path);
  });

  tearDown(() async {
    Trash.instance = const NoTrash();
    TrashListing.clear();
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
    await trashDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Settles until [done], for up to 60 rounds: each step of a move to the
  /// Trash is real file I/O.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await settle(tester);
    }
    await settle(tester);
  }

  Future<void> seen(WidgetTester tester, Finder finder) =>
      until(tester, () => finder.evaluate().isNotEmpty);

  Future<void> menuOpens(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
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

  bool exists(String name) => FileSystemEntity.typeSync(p.join(root.path, name)) != FileSystemEntityType.notFound;

  testWidgets('Delete moves to the Trash, and Undo brings it back', (tester) async {
    await open(tester);
    await click(tester, 'alpha.txt');
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await seen(tester, find.text('Moved "alpha.txt" to the Trash'));
    expect(exists('alpha.txt'), isFalse);
    expect(find.text('Delete "alpha.txt"?'), findsNothing, reason: "the Trash doesn't ask");
    expect(find.text('Moved "alpha.txt" to the Trash'), findsOneWidget);
    expect(find.text('alpha.txt'), findsNothing);

    await tester.tap(find.text('Undo'));
    await until(tester, () => exists('alpha.txt') && find.text('alpha.txt').evaluate().isNotEmpty);
    expect(exists('alpha.txt'), isTrue);
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(await tester.runAsync(() => Trash.instance.list()), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Shift+Delete asks, then deletes for good', (tester) async {
    await open(tester);
    await click(tester, 'beta.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await seen(tester, find.text('Delete "beta.txt"?'));
    expect(find.text('Delete "beta.txt"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await until(tester, () => !exists('beta.txt'));
    expect(exists('beta.txt'), isFalse);
    expect(await tester.runAsync(() => Trash.instance.list()), isEmpty, reason: 'not in the Trash');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the menus have Delete for good beside Delete', (tester) async {
    await open(tester);
    await click(tester, 'gamma.txt', buttons: kSecondaryButton);
    await seen(tester, find.text('Delete for good'));
    await menuOpens(tester);
    expect(find.text('Delete'), findsWidgets, reason: 'and its shortcut, the Delete key');
    expect(find.text('Delete for good'), findsOneWidget);
    await tester.tap(find.text('Delete for good'));
    await seen(tester, find.text('Delete "gamma.txt"?'));
    expect(find.text('Delete "gamma.txt"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await settle(tester);
    expect(exists('gamma.txt'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the Trash place lists, restores, deletes for good and empties', (tester) async {
    final bloc = await open(tester);
    final trashTitle = ExplorerPaths.titleForPath(ExplorerPaths.trash);

    // Docs and beta.txt go to the Trash together.
    await click(tester, 'beta.txt');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await click(tester, 'Docs');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await seen(tester, find.text('Moved 2 items to the Trash'));
    expect(find.text('Moved 2 items to the Trash'), findsOneWidget);
    expect(exists('Docs'), isFalse);

    // The sidebar's entry opens it.
    await tester.tap(find.text(trashTitle).first);
    await until(tester, () => find.text('beta.txt').evaluate().isNotEmpty);
    expect((bloc.state as FileExplorerLoaded).path, ExplorerPaths.trash);
    expect(find.byType(TrashBar), findsOneWidget);
    expect(find.text('beta.txt'), findsOneWidget, reason: 'under the name it had');
    expect(find.text('Docs'), findsOneWidget);

    // A right-click: Restore.
    await click(tester, 'beta.txt', buttons: kSecondaryButton);
    await menuOpens(tester);
    await tester.tap(find.text('Restore'));
    await seen(tester, find.text('Restored "beta.txt"'));
    expect(exists('beta.txt'), isTrue);
    expect(find.text('Restored "beta.txt"'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);

    // A double-click shows its details: delete it for good from there.
    await tester.pump(const Duration(milliseconds: 500));
    await click(tester, 'Docs');
    await click(tester, 'Docs');
    await seen(tester, find.text('From'));
    expect(find.text('From'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete for good'));
    await seen(tester, find.text('Delete "Docs" for good?'));
    expect(find.text('Delete "Docs" for good?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete for good'));
    await seen(tester, find.textContaining('is empty'));
    expect(await tester.runAsync(() => Trash.instance.list()), isEmpty);
    expect(find.textContaining('is empty'), findsOneWidget);

    // Empty: everything goes, after asking.
    await tester.runAsync(() => Trash.instance.moveToTrash([p.join(root.path, 'gamma.txt')]));
    bloc.add(LoadDirectory(ExplorerPaths.trash));
    await seen(tester, find.text('gamma.txt'));
    expect(find.text('gamma.txt'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Empty'));
    await seen(tester, find.text('Empty Trash?'));
    expect(find.text('Empty Trash?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Empty'));
    await seen(tester, find.textContaining('is empty'));
    expect(await tester.runAsync(() => Trash.instance.list()), isEmpty);
    expect(exists('gamma.txt'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with no Trash, Delete asks and deletes for good, as before', (tester) async {
    Trash.instance = const NoTrash();
    await open(tester);
    await click(tester, 'alpha.txt', buttons: kSecondaryButton);
    await seen(tester, find.text('Properties'));
    await menuOpens(tester);
    expect(find.text('Delete for good'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await menuOpens(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await seen(tester, find.text('Delete "alpha.txt"?'));
    expect(find.text('Delete "alpha.txt"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await settle(tester);
    expect(exists('alpha.txt'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
