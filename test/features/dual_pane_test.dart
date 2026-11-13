import 'dart:io';

import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/pane_settings.dart';
import 'package:folders/shared/widgets/main_drawer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Two browsers side by side in a tab, as on a computer.
void main() {
  late Directory root;
  late String left;
  late String right;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PaneSettings.instance.reset();
    ExplorerTabs.instance.reset();
    root = await Directory.systemTemp.createTemp('explorer_panes');
    left = p.join(root.path, 'Left');
    right = p.join(root.path, 'Right');
    await Directory(p.join(left, 'Inner')).create(recursive: true);
    await Directory(right).create();
    for (final name in ['a.txt', 'b.txt', 'c.txt']) {
      await File(p.join(left, name)).writeAsString(name);
    }
    for (final name in ['r1.md', 'r2.md']) {
      await File(p.join(right, name)).writeAsString(name);
    }
  });

  tearDown(() async {
    ExplorerTabs.instance.reset();
    PaneSettings.instance.reset();
    await root.delete(recursive: true);
  });

  /// Closes the window, and lets the settings' delayed save happen.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> settle(WidgetTester tester, {int times = 6}) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
  }

  Future<DualPaneController> open(WidgetTester tester, {Size size = const Size(1400, 860)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: left)));
    await waitFor(tester, () => find.text('a.txt').evaluate().isNotEmpty);
    return DualPanes.read(tester.element(find.text('a.txt')))!;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {List<LogicalKeyboardKey> holding = const []}) async {
    for (final k in holding) {
      await tester.sendKeyDownEvent(k);
    }
    await tester.sendKeyEvent(key);
    for (final k in holding.reversed) {
      await tester.sendKeyUpEvent(k);
    }
    await settle(tester);
  }

  Future<void> toggleDual(WidgetTester tester) =>
      press(tester, LogicalKeyboardKey.backslash, holding: [LogicalKeyboardKey.controlLeft]);

  Future<void> click(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, kind: PointerDeviceKind.mouse);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 320)));
    await settle(tester);
  }

  Set<String> selected(FileExplorerBloc bloc) =>
      {for (final e in (bloc.state as FileExplorerLoaded).selectedItems) p.basename(e.path)};

  String folderOf(FileExplorerBloc? bloc) => (bloc!.state as FileExplorerLoaded).path;

  /// Shows [folder] in the second pane.
  Future<void> secondTo(WidgetTester tester, DualPaneController panes, String folder) async {
    panes.second!.add(LoadDirectory(folder));
    await waitFor(tester, () => find.text('r1.md').evaluate().isNotEmpty);
  }

  testWidgets('Ctrl+\\ shows a second pane on the same folder, and hides it again', (tester) async {
    final panes = await open(tester);
    expect(find.text('a.txt'), findsOneWidget);
    await toggleDual(tester);
    await waitFor(tester, () => find.text('a.txt').evaluate().length == 2);
    expect(find.text('a.txt'), findsNWidgets(2));
    expect(panes.showing, isTrue);
    expect(folderOf(panes.second), left);
    // The first pane keeps the keyboard.
    expect(panes.active, 0);
    await toggleDual(tester);
    expect(find.text('a.txt'), findsOneWidget);
    expect(panes.showing, isFalse);
    await finish(tester);
  });

  testWidgets('the header button and the View menu switch it too', (tester) async {
    final panes = await open(tester);
    await tester.tap(find.byTooltip('Dual pane (Ctrl+\\)'), kind: PointerDeviceKind.mouse);
    await waitFor(tester, () => find.text('a.txt').evaluate().length == 2);
    expect(panes.showing, isTrue);
    // Only the right pane's header has the buttons: narrow panes put them
    // in one menu.
    expect(find.byTooltip('Dual pane (Ctrl+\\)'), findsNothing);
    expect(find.byTooltip('Panes'), findsOneWidget);
    await tester.tap(find.byTooltip('View').first, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.text('Swap panes'), findsOneWidget);
    await tester.tap(find.text('Dual pane'), kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(panes.showing, isFalse);
    await finish(tester);
  });

  testWidgets('each pane has its own folder and selection; Tab moves between them', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);
    await click(tester, find.text('a.txt'));
    expect(selected(panes.first!), {'a.txt'});
    expect(panes.active, 0);

    await press(tester, LogicalKeyboardKey.tab);
    expect(panes.active, 1);
    await press(tester, LogicalKeyboardKey.keyA, holding: [LogicalKeyboardKey.controlLeft]);
    expect(selected(panes.second!), {'r1.md', 'r2.md'});
    expect(selected(panes.first!), {'a.txt'});

    // Arrows and Escape act on the active pane only.
    await press(tester, LogicalKeyboardKey.escape);
    expect(selected(panes.second!), isEmpty);
    expect(selected(panes.first!), {'a.txt'});

    await press(tester, LogicalKeyboardKey.tab, holding: [LogicalKeyboardKey.shiftLeft]);
    expect(panes.active, 0);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selected(panes.first!), {'b.txt'});
    expect(selected(panes.second!), isEmpty);

    // A click in a pane makes it the active one.
    await click(tester, find.text('r2.md'));
    expect(panes.active, 1);
    expect(selected(panes.second!), {'r2.md'});
    await finish(tester);
  });

  testWidgets('Shift+F5 copies the selection to the other pane, Shift+F6 moves it', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);

    await click(tester, find.text('a.txt'));
    await press(tester, LogicalKeyboardKey.f5, holding: [LogicalKeyboardKey.shiftLeft]);
    await waitFor(tester, () => File(p.join(right, 'a.txt')).existsSync());
    expect(File(p.join(right, 'a.txt')).existsSync(), isTrue);
    expect(File(p.join(left, 'a.txt')).existsSync(), isTrue);
    // Shift+F5 isn't a refresh as well: the selection stays.
    expect(selected(panes.first!), {'a.txt'});

    await click(tester, find.text('b.txt'));
    await press(tester, LogicalKeyboardKey.f6, holding: [LogicalKeyboardKey.shiftLeft]);
    await waitFor(tester, () => !File(p.join(left, 'b.txt')).existsSync());
    expect(File(p.join(right, 'b.txt')).existsSync(), isTrue);
    expect(File(p.join(left, 'b.txt')).existsSync(), isFalse);
    // The second pane shows what came.
    await waitFor(tester, () => find.text('b.txt').evaluate().isNotEmpty);
    expect(find.text('b.txt'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the right-click menu copies to the other pane', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);
    await tester.tap(find.text('c.txt'), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.text('Move to other pane'), findsOneWidget);
    await tester.tap(find.text('Copy to other pane'), kind: PointerDeviceKind.mouse);
    await waitFor(tester, () => File(p.join(right, 'c.txt')).existsSync());
    expect(File(p.join(right, 'c.txt')).existsSync(), isTrue);
    expect(File(p.join(left, 'c.txt')).existsSync(), isTrue);
    await finish(tester);
  });

  testWidgets('copying where both panes show the same folder is refused', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => find.text('a.txt').evaluate().length == 2);
    await click(tester, find.text('a.txt').first);
    await press(tester, LogicalKeyboardKey.f5, holding: [LogicalKeyboardKey.shiftLeft]);
    expect(find.text('Both panes show this folder'), findsOneWidget);
    expect(panes.showing, isTrue);
    await finish(tester);
  });

  testWidgets('Ctrl+U swaps the panes\' folders', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);
    await press(tester, LogicalKeyboardKey.keyU, holding: [LogicalKeyboardKey.controlLeft]);
    await waitFor(tester, () => folderOf(panes.first) == right);
    expect(folderOf(panes.first), right);
    expect(folderOf(panes.second), left);
    await finish(tester);
  });

  testWidgets('closing two panes from the second one keeps its folder', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);
    await click(tester, find.text('r1.md'));
    expect(panes.active, 1);
    await toggleDual(tester);
    await waitFor(tester, () => folderOf(panes.first) == right);
    expect(panes.showing, isFalse);
    expect(folderOf(panes.first), right);
    await finish(tester);
  });

  testWidgets('the sidebar works on the active pane', (tester) async {
    final panes = await open(tester);
    FileExplorerBloc sidebarBloc() => BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(MainDrawerContent)));
    expect(sidebarBloc(), same(panes.first));
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);
    await click(tester, find.text('r1.md'));
    expect(sidebarBloc(), same(panes.second));
    await click(tester, find.text('a.txt'));
    expect(sidebarBloc(), same(panes.first));
    await finish(tester);
  });

  testWidgets('each tab keeps its own panes', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    ExplorerTabs.instance.open(right);
    await waitFor(tester, () => find.text('r1.md').hitTestable().evaluate().isNotEmpty);
    final second = DualPanes.read(tester.element(find.text('r1.md').hitTestable()))!;
    expect(second, isNot(same(panes)));
    // A new tab starts with one pane.
    expect(second.showing, isFalse);
    ExplorerTabs.instance.select(0);
    await settle(tester);
    expect(panes.showing, isTrue);
    expect(find.text('a.txt').hitTestable(), findsNWidgets(2));
    await finish(tester);
  });

  testWidgets('a new window starts as the last browser was left', (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    await secondTo(tester, panes, right);
    panes.setRatio(0.4);
    // Kept a moment later.
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getBool('dual_pane'), isTrue);
    expect(prefs.getString('dual_pane_folder'), right);
    await tester.pumpWidget(const SizedBox());

    ExplorerTabs.instance.reset();
    PaneSettings.instance.reset();
    await tester.runAsync(PaneSettings.instance.load);
    final restored = await open(tester);
    await waitFor(tester, () => find.text('r1.md').evaluate().isNotEmpty);
    expect(restored.enabled, isTrue);
    expect(restored.ratio.value, closeTo(0.4, 0.001));
    expect(folderOf(restored.second), right);
    await finish(tester);
  });

  testWidgets('a narrow window has room for one pane only', (tester) async {
    final panes = await open(tester, size: const Size(900, 700));
    expect(panes.roomForTwo, isFalse);
    expect(find.byTooltip('Dual pane (Ctrl+\\)'), findsNothing);
    await toggleDual(tester);
    expect(panes.showing, isFalse);
    expect(find.text('a.txt'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a phone in landscape: two panes without the sidebar, the menu in the first only', (tester) async {
    final panes = await open(tester, size: const Size(800, 420));
    expect(find.byType(MainDrawerContent), findsNothing);
    expect(panes.roomForTwo, isTrue);
    await toggleDual(tester);
    await waitFor(tester, () => find.text('a.txt').evaluate().length == 2);
    expect(panes.showing, isTrue);
    expect(find.byTooltip('Open menu'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets("a narrow pane's New button offers a folder or a file", (tester) async {
    final panes = await open(tester);
    await toggleDual(tester);
    await waitFor(tester, () => panes.second != null);
    // Both panes are under 760 px: the compact header, with one New button.
    expect(find.byTooltip('New'), findsNWidgets(2));
    expect(find.text('New folder'), findsNothing);
    await tester.tap(find.byTooltip('New').last, kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.text('New folder'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('with one pane, Tab still moves the keyboard as before', (tester) async {
    await open(tester);
    await click(tester, find.text('a.txt'));
    final before = FocusManager.instance.primaryFocus;
    await press(tester, LogicalKeyboardKey.tab);
    expect(FocusManager.instance.primaryFocus, isNot(same(before)));
    await finish(tester);
  });
}
