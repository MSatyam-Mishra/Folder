import 'dart:io';

import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/explorer_tabs/explorer_tabs.dart';
import 'package:folder/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/widgets/inline_rename.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// New folder makes the folder at once and renames it where it's shown.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_new_folder');
    await File(p.join(root.path, 'notes.txt')).writeAsString('notes');
    ExplorerTabs.instance.reset();
  });

  tearDown(() async {
    ExplorerTabs.instance.reset();
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    for (var i = 0; i < 60 && find.text('notes.txt').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    return BlocProvider.of<FileExplorerBloc>(tester.element(find.text('notes.txt')));
  }

  /// Settles until [done]: real file work takes a while on the fake clock.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await settle(tester);
    }
    await settle(tester);
  }

  Future<void> waitForEditor(WidgetTester tester) =>
      until(tester, () => find.byType(InlineRename).evaluate().isNotEmpty);

  Future<void> waitForNoEditor(WidgetTester tester) =>
      until(tester, () => find.byType(InlineRename).evaluate().isEmpty);

  Future<void> newFolder(WidgetTester tester) async {
    await tester.tap(find.byIcon(LucideIcons.folderPlus).first, kind: PointerDeviceKind.mouse);
    await waitForEditor(tester);
  }

  /// Types [name] in the name being edited.
  Future<void> type(WidgetTester tester, String name) async {
    await tester.enterText(find.descendant(of: find.byType(InlineRename), matching: find.byType(TextField)), name);
    await tester.pump();
  }

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitForNoEditor(tester);
  }

  bool exists(String name) => Directory(p.join(root.path, name)).existsSync();

  Set<String> selected(FileExplorerBloc bloc) =>
      {for (final e in (bloc.state as FileExplorerLoaded).selectedItems) p.basename(e.path)};

  testWidgets('no dialog: the folder is there with its name being edited', (tester) async {
    final bloc = await open(tester);
    await newFolder(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(exists('New folder'), isTrue, reason: 'made at once');
    expect(find.byType(InlineRename), findsOneWidget);
    expect(selected(bloc), {'New folder'});

    final field = tester.widget<TextField>(find.descendant(of: find.byType(InlineRename), matching: find.byType(TextField)));
    expect(field.focusNode!.hasFocus, isTrue, reason: 'ready to type');
    expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 10), reason: 'typing replaces it');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Enter gives it the name typed, and it stays selected', (tester) async {
    final bloc = await open(tester);
    await newFolder(tester);
    await type(tester, 'Holiday photos');
    await pressEnter(tester);
    await until(tester, () => find.text('Holiday photos').evaluate().isNotEmpty);

    expect(exists('Holiday photos'), isTrue);
    expect(exists('New folder'), isFalse);
    expect(find.byType(InlineRename), findsNothing);
    expect(find.text('Holiday photos'), findsOneWidget);
    expect(selected(bloc), {'Holiday photos'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Esc keeps the name it had', (tester) async {
    await open(tester);
    await newFolder(tester);
    await type(tester, 'Something else');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitForNoEditor(tester);

    expect(find.byType(InlineRename), findsNothing);
    expect(exists('New folder'), isTrue);
    expect(exists('Something else'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a click elsewhere keeps what was typed', (tester) async {
    await open(tester);
    await newFolder(tester);
    await type(tester, 'Clicked away');
    await settle(tester);
    await tester.tapAt(const Offset(900, 700), kind: PointerDeviceKind.mouse);
    await waitForNoEditor(tester);
    await until(tester, () => exists('Clicked away'));

    expect(find.byType(InlineRename), findsNothing);
    expect(exists('Clicked away'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a second one gets a number', (tester) async {
    await open(tester);
    await newFolder(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitForNoEditor(tester);
    await newFolder(tester);
    expect(exists('New folder (2)'), isTrue);
    expect(find.byType(InlineRename), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a taken or impossible name keeps the old one and says so", (tester) async {
    await open(tester);
    await tester.runAsync(() => Directory(p.join(root.path, 'Taken')).create());
    await newFolder(tester);
    await type(tester, 'Taken');
    await pressEnter(tester);
    expect(exists('New folder'), isTrue);
    expect(find.textContaining('already exists'), findsOneWidget);

    await newFolder(tester);
    await type(tester, 'a/b');
    await pressEnter(tester);
    expect(exists('New folder (2)'), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("typing in the name isn't taken by the browser's keys", (tester) async {
    final bloc = await open(tester);
    final folder = (bloc.state as FileExplorerLoaded).path;
    await newFolder(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(tester);
    expect((bloc.state as FileExplorerLoaded).path, folder);
    expect(find.byType(InlineRename), findsOneWidget);
    expect(selected(bloc), {'New folder'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the keyboard goes back to the list afterwards', (tester) async {
    final bloc = await open(tester);
    await newFolder(tester);
    await pressEnter(tester);
    await until(tester, () => (bloc.state as FileExplorerLoaded).displayEntities.length == 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(selected(bloc), {'New folder', 'notes.txt'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('works in a grid and in an empty folder', (tester) async {
    final bloc = await open(tester);
    bloc.add(ChangeViewMode(ViewMode.grid));
    await settle(tester);
    await newFolder(tester);
    expect(find.byType(InlineRename), findsOneWidget);
    await type(tester, 'In a grid');
    await pressEnter(tester);
    await until(tester, () => exists('In a grid'));
    expect(exists('In a grid'), isTrue);

    final empty = await tester.runAsync(() => Directory(p.join(root.path, 'Empty')).create());
    bloc.add(LoadDirectory(empty!.path));
    await settle(tester);
    await newFolder(tester);
    expect(find.byType(InlineRename), findsOneWidget);
    expect(Directory(p.join(empty.path, 'New folder')).existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Ctrl+Shift+N does the same', (tester) async {
    await open(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await waitForEditor(tester);
    expect(exists('New folder'), isTrue);
    expect(find.byType(InlineRename), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
