import 'dart:io';

import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Ctrl, or Cmd on macOS.
final commandKey =
    Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

/// Tabs in a window (desktop): each a browser of its own.
void main() {
  late Directory root;
  final tabs = ExplorerTabs.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_tabs_test');
    await Directory(p.join(root.path, 'Docs')).create();
    await Directory(p.join(root.path, 'Music')).create();
    await File(p.join(root.path, 'Docs', 'inside.txt')).writeAsString('inside');
    await File(p.join(root.path, 'notes.txt')).writeAsString('notes');
    tabs.reset();
  });

  tearDown(() async {
    tabs.reset();
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Settles until [finder] finds something (real file I/O takes a while).
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    await waitFor(tester, find.text('notes.txt'));
  }

  Future<void> command(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
    await tester.sendKeyDownEvent(commandKey);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(commandKey);
    await tester.pump();
  }

  Future<void> click(WidgetTester tester, String name, {int buttons = kPrimaryButton}) async {
    await tester.tap(find.text(name), kind: PointerDeviceKind.mouse, buttons: buttons);
    await tester.pump();
  }

  List<String> titles() => [for (final t in tabs.tabs) t.title];

  testWidgets('a tab follows its folder; new tabs open and close', (tester) async {
    await open(tester);
    expect(titles(), [p.basename(root.path)]);

    // Double-click a folder: the tab's title follows.
    await click(tester, 'Docs');
    await click(tester, 'Docs');
    await waitFor(tester, find.text('inside.txt'));
    expect(titles(), ['Docs']);

    // The + button: a second tab, at home, shown.
    await tester.tap(find.byTooltip(Platform.isMacOS ? 'New tab (⌘T)' : 'New tab (Ctrl+T)'));
    await settle(tester);
    expect(tabs.tabs, hasLength(2));
    expect(tabs.activeIndex, 1);
    expect(find.text('inside.txt'), findsNothing, reason: 'the first tab is hidden');

    // Clicking the first tab shows it as it was.
    await tester.tap(find.text('Docs').first, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(tabs.activeIndex, 0);
    expect(find.text('inside.txt'), findsOneWidget);

    // Ctrl+W closes it; the other tab is left.
    await command(tester, LogicalKeyboardKey.keyW);
    await settle(tester);
    expect(tabs.tabs, hasLength(1));
    expect(titles(), isNot(contains('Docs')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('middle-click and the menu open folders in tabs; keys switch', (tester) async {
    await open(tester);

    // Middle button: a tab behind this one.
    await click(tester, 'Music', buttons: kMiddleMouseButton);
    await settle(tester);
    expect(titles(), [p.basename(root.path), 'Music']);
    expect(tabs.activeIndex, 0, reason: 'opened behind');

    // Right-click, Open in new tab: next to this one, and shown.
    await click(tester, 'Docs', buttons: kSecondaryButton);
    await waitFor(tester, find.text('Open in new tab'));
    await tester.tap(find.text('Open in new tab'));
    await settle(tester);
    expect(titles(), [p.basename(root.path), 'Docs', 'Music']);
    expect(tabs.activeIndex, 1);
    await waitFor(tester, find.text('inside.txt'));

    // Ctrl+Tab goes round; Ctrl+Shift+Tab back; Ctrl+1 and Ctrl+9.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tabs.activeIndex, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tabs.activeIndex, 0);
    await command(tester, LogicalKeyboardKey.digit9);
    expect(tabs.activeIndex, 2);
    await command(tester, LogicalKeyboardKey.digit1);
    expect(tabs.activeIndex, 0);

    // The keyboard works in the tab shown: Ctrl+A selects its items.
    await command(tester, LogicalKeyboardKey.digit2);
    await settle(tester);
    await command(tester, LogicalKeyboardKey.keyA);
    final docs = tester.element(find.text('inside.txt'));
    final state = BlocProvider.of<FileExplorerBloc>(docs).state as FileExplorerLoaded;
    expect(state.selectedItems.map((e) => p.basename(e.path)), ['inside.txt']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tab is dragged along the bar to move it', (tester) async {
    await open(tester);
    tabs.open(p.join(root.path, 'Docs'), atEnd: true);
    tabs.open(p.join(root.path, 'Music'), atEnd: true);
    await settle(tester);
    expect(titles(), [p.basename(root.path), 'Docs', 'Music']);

    // The first tab, dragged two tabs' width to the right.
    final first = find.text(p.basename(root.path)).first;
    final gesture = await tester.startGesture(tester.getCenter(first), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
    }
    await gesture.up();
    await settle(tester);
    expect(titles().last, p.basename(root.path));
    expect(tabs.active!.title, p.basename(root.path), reason: 'still the one shown');
    expect(tester.takeException(), isNull);
  });
}
