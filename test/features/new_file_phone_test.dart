import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/file_explorere/widgets/inline_rename.dart';
import 'package:folders/features/viewer_text/screens/tabbed_text_editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Creating things on a phone: the header has no room for the buttons, so the
/// round + button opens a sheet.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_new_phone');
    await File(p.join(root.path, 'notes.txt')).writeAsString('notes');
    ExplorerPaths.startFolder = root.path;
  });

  tearDown(() async {
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await settle(tester);
    }
    await settle(tester);
  }

  /// A phone's screen, showing [folder].
  Future<void> open(WidgetTester tester, Finder ready) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await until(tester, () => ready.evaluate().isNotEmpty);
    expect(ready, findsWidgets);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byType(FloatingActionButton));
    await settle(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
  }

  testWidgets('the round button offers a folder and the chosen kinds of file', (tester) async {
    await open(tester, find.text('notes.txt'));
    expect(find.byIcon(LucideIcons.plus), findsOneWidget);
    await openSheet(tester);
    expect(find.text('New folder'), findsOneWidget);
    expect(find.text('Text file (.txt)'), findsOneWidget);
    expect(find.text('Word document (.docx)'), findsOneWidget);
    expect(find.text('Excel workbook (.xlsx)'), findsNothing);
    expect(find.byIcon(LucideIcons.settings), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a file opens in its editor, and Save asks for the name', (tester) async {
    await open(tester, find.text('notes.txt'));
    await openSheet(tester);
    await tester.tap(find.text('Text file (.txt)'));
    await until(tester, () => find.byType(TabbedTextEditorScreen).evaluate().isNotEmpty);
    expect(File(p.join(root.path, 'New Text Document.txt')).existsSync(), isFalse);

    // A phone has no Ctrl+S: the button works, even before anything's typed.
    await tester.enterText(find.byType(TextField).last, 'from a phone');
    await settle(tester);
    await tester.tap(find.byTooltip('Save'));
    await settle(tester);
    expect(find.text('Save as'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'shopping list');
    await settle(tester);
    await tester.tap(find.text('Save').last);
    final made = File(p.join(root.path, 'shopping list.txt'));
    await until(tester, made.existsSync);
    expect(await tester.runAsync(made.readAsString), 'from a phone');
    await finish(tester);
  });

  testWidgets('New folder is made at once, to rename where it shows', (tester) async {
    await open(tester, find.text('notes.txt'));
    await openSheet(tester);
    await tester.tap(find.text('New folder'));
    await until(tester, () => find.byType(InlineRename).evaluate().isNotEmpty);
    expect(find.byType(InlineRename), findsOneWidget);
    expect(Directory(p.join(root.path, 'New folder')).existsSync(), isTrue);
    expect(find.byType(FloatingActionButton), findsNothing, reason: "it'd cover the name, above the keyboard");

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await until(tester, () => find.byType(InlineRename).evaluate().isEmpty);
    expect(find.byType(FloatingActionButton), findsOneWidget, reason: 'back once the name is done');
    await finish(tester);
  });

  testWidgets('the settings icon chooses the kinds, and the list follows', (tester) async {
    await open(tester, find.text('notes.txt'));
    await openSheet(tester);
    await tester.tap(find.byTooltip('Choose file types'));
    await settle(tester);
    expect(find.text('File types'), findsOneWidget);
    await tester.tap(find.text('Excel workbook (.xlsx)'));
    await settle(tester);
    // Closes the types, back to the list.
    await tester.tapAt(const Offset(210, 10));
    await settle(tester);
    expect(find.text('File types'), findsNothing);
    expect(find.text('Excel workbook (.xlsx)'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('an empty folder has New file too', (tester) async {
    await tester.runAsync(() => File(p.join(root.path, 'notes.txt')).delete());
    await open(tester, find.text('This folder is empty'));
    expect(find.text('New folder'), findsOneWidget);
    await tester.tap(find.text('New file'));
    await settle(tester);
    expect(find.text('Text file (.txt)'), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget, reason: 'the page button, not a row of the sheet');
    await tester.tap(find.text('Text file (.txt)'));
    await until(tester, () => find.byType(TabbedTextEditorScreen).evaluate().isNotEmpty);
    expect(find.byType(TabbedTextEditorScreen), findsOneWidget);
    await finish(tester);
  });
}
