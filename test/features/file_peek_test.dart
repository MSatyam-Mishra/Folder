import 'dart:io';

import 'package:folder/features/explorer_tabs/explorer_tabs.dart';
import 'package:folder/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folder/features/file_explorere/widgets/file_list_item.dart';
import 'package:folder/features/file_explorere/widgets/file_peek.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// A quick look at a file: a double tap on its picture, or Space on a computer.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_peek');
    ExplorerTabs.instance.reset();
  });

  tearDown(() async {
    ExplorerTabs.instance.reset();
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<File> write(WidgetTester tester, String name, String text) async =>
      (await tester.runAsync(() => File(p.join(root.path, name)).writeAsString(text)))!;

  testWidgets('a text file shows its first lines, its name and size', (tester) async {
    final file = await write(tester, 'notes.txt', 'first line of it');
    var opened = false;
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showFilePeek(context, file, onOpen: () => opened = true),
          child: const Text('Peek'),
        ),
      ),
    )));
    await tester.tap(find.text('Peek'));
    await settle(tester);
    expect(find.text('first line of it'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('Open'));
    await settle(tester);
    expect(opened, isTrue);
    expect(find.byType(FilePeek), findsNothing, reason: 'closes to open it');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tap outside closes it', (tester) async {
    final file = await write(tester, 'notes.txt', 'text');
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showFilePeek(context, file, onOpen: () {}),
          child: const Text('Peek'),
        ),
      ),
    )));
    await tester.tap(find.text('Peek'));
    await settle(tester);
    expect(find.byType(FilePeek), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    expect(find.byType(FilePeek), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a row: a double tap on the picture peeks, one tap still opens', (tester) async {
    final file = await write(tester, 'notes.txt', 'text');
    var opens = 0;
    var peeks = 0;
    await tester.pumpWidget(themedApp(Scaffold(
      body: FileListItem(
        entity: file,
        displayName: 'notes.txt',
        isSelectionMode: false,
        isSelected: false,
        onTap: () => opens++,
        onLongPress: () {},
        onPeek: () => peeks++,
      ),
    )));
    await settle(tester);
    final picture = tester.getTopLeft(find.byType(FileListItem)) + const Offset(40, 24);

    await tester.tapAt(picture);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(picture);
    await tester.pump(const Duration(milliseconds: 400));
    expect((peeks, opens), (1, 0));

    await tester.tapAt(picture);
    await tester.pump(const Duration(milliseconds: 400));
    expect((peeks, opens), (1, 1), reason: 'a single tap opens, once the double tap has been ruled out');

    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(opens, 2, reason: 'the name opens as ever');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a computer Space peeks at the selected file', (tester) async {
    await write(tester, 'notes.txt', 'first line of it');
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    for (var i = 0; i < 40 && find.text('notes.txt').evaluate().isEmpty; i++) {
      await settle(tester);
    }
    await tester.tap(find.text('notes.txt'), kind: PointerDeviceKind.mouse);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 320)));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await settle(tester);
    expect(find.byType(FilePeek), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
