import 'dart:io';

import 'package:explorer/core/services/folder_prefs_service.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/explorer_tabs/tabbed_explorer.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/selection_band.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Selecting with the mouse and the keyboard, as on a computer.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_selection');
    for (final name in ['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']) {
      await File(p.join(root.path, name)).writeAsString(name);
    }
    ExplorerTabs.instance.reset();
  });

  tearDown(() async {
    ExplorerTabs.instance.reset();
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    for (var i = 0; i < 60 && find.text('a.txt').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));
    return BlocProvider.of<FileExplorerBloc>(tester.element(find.text('a.txt')));
  }

  Set<String> selected(FileExplorerBloc bloc) =>
      {for (final e in (bloc.state as FileExplorerLoaded).selectedItems) p.basename(e.path)};

  bool ticking(FileExplorerBloc bloc) => (bloc.state as FileExplorerLoaded).isSelectionMode;

  Future<void> click(WidgetTester tester, String name) async {
    await tester.tap(find.text(name), kind: PointerDeviceKind.mouse);
    // Not a double-click with the next one.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 320)));
    await settle(tester);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {LogicalKeyboardKey? holding}) async {
    if (holding != null) await tester.sendKeyDownEvent(holding);
    await tester.sendKeyEvent(key);
    if (holding != null) await tester.sendKeyUpEvent(holding);
    await settle(tester);
  }

  Future<void> ctrlA(WidgetTester tester) =>
      press(tester, LogicalKeyboardKey.keyA, holding: LogicalKeyboardKey.controlLeft);

  /// Drags a band with the mouse between two points of the screen.
  Future<void> band(WidgetTester tester, Offset from, Offset to) async {
    final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await mouse.moveTo(Offset.lerp(from, to, 0.5)!);
    await tester.pump();
    await mouse.moveTo(to);
    await tester.pump();
    await mouse.up();
    await settle(tester);
  }

  /// A spot on the row of [name] that's right of its name.
  Offset blankOf(WidgetTester tester, String name) {
    final text = tester.getCenter(find.text(name));
    return Offset(tester.getTopRight(find.text(name)).dx + 80, text.dy);
  }

  group('Ctrl+A', () {
    testWidgets('right after opening', (tester) async {
      final bloc = await open(tester);
      await ctrlA(tester);
      expect(selected(bloc), hasLength(5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after a click on a file', (tester) async {
      final bloc = await open(tester);
      await click(tester, 'a.txt');
      await ctrlA(tester);
      expect(selected(bloc), hasLength(5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after clicking the list while the search field has the keyboard', (tester) async {
      final bloc = await open(tester);
      bloc.add(OpenSearch());
      await settle(tester);
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull);
      // In the field Ctrl+A is the field's own.
      await ctrlA(tester);
      expect(selected(bloc), isEmpty);
      await click(tester, 'a.txt');
      await ctrlA(tester);
      expect(selected(bloc), hasLength(5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after Options opened and closed', (tester) async {
      final bloc = await open(tester);
      await tester.tap(find.byTooltip('Options'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await tester.tapAt(const Offset(20, 400), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await ctrlA(tester);
      expect(selected(bloc), hasLength(5));
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets("keys typed in the search field aren't the browser's", (tester) async {
    final bloc = await open(tester);
    final folder = (bloc.state as FileExplorerLoaded).path;
    bloc.add(OpenSearch());
    await settle(tester);
    await press(tester, LogicalKeyboardKey.backspace);
    expect((bloc.state as FileExplorerLoaded).path, folder, reason: "backspace doesn't go up a folder");
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(selected(bloc), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  group('checkboxes', () {
    testWidgets('a click ticks another file and keeps the first', (tester) async {
      final bloc = await open(tester);
      // A long press brings the checkboxes.
      await tester.longPress(find.text('a.txt'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(selected(bloc), {'a.txt'});
      expect(ticking(bloc), isTrue);

      await click(tester, 'b.txt');
      expect(selected(bloc), {'a.txt', 'b.txt'});
      await click(tester, 'c.txt');
      expect(selected(bloc), {'a.txt', 'b.txt', 'c.txt'});

      await click(tester, 'b.txt');
      expect(selected(bloc), {'a.txt', 'c.txt'}, reason: 'a second click unticks');
      expect(ticking(bloc), isTrue);

      await click(tester, 'a.txt');
      await click(tester, 'c.txt');
      expect(selected(bloc), isEmpty);
      expect(ticking(bloc), isFalse, reason: 'nothing ticked: the boxes go');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('after Ctrl+A a click unticks one', (tester) async {
      final bloc = await open(tester);
      await ctrlA(tester);
      await click(tester, 'c.txt');
      expect(selected(bloc), {'a.txt', 'b.txt', 'd.txt', 'e.txt'});
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('arrow keys', () {
    testWidgets('move the selection, and Shift stretches it', (tester) async {
      final bloc = await open(tester);
      await click(tester, 'b.txt');
      expect(selected(bloc), {'b.txt'});

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(selected(bloc), {'c.txt'});

      await press(tester, LogicalKeyboardKey.arrowDown, holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(bloc), {'c.txt', 'd.txt'});
      await press(tester, LogicalKeyboardKey.arrowDown, holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(bloc), {'c.txt', 'd.txt', 'e.txt'});

      // Back over the start, and past it the other way.
      await press(tester, LogicalKeyboardKey.arrowUp, holding: LogicalKeyboardKey.shiftLeft);
      await press(tester, LogicalKeyboardKey.arrowUp, holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(bloc), {'c.txt'});
      await press(tester, LogicalKeyboardKey.arrowUp, holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(bloc), {'b.txt', 'c.txt'});

      await press(tester, LogicalKeyboardKey.home);
      expect(selected(bloc), {'a.txt'});
      await press(tester, LogicalKeyboardKey.end, holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(bloc), hasLength(5));
      await press(tester, LogicalKeyboardKey.end);
      expect(selected(bloc), {'e.txt'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with nothing selected, start at the first or last', (tester) async {
      final bloc = await open(tester);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(selected(bloc), {'a.txt'});
      await tester.tapAt(const Offset(900, 700), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(selected(bloc), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('in a grid, up and down go by a row and left and right by one', (tester) async {
      final bloc = await open(tester);
      bloc.add(ChangeViewMode(ViewMode.grid));
      await settle(tester);
      await click(tester, 'a.txt');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(selected(bloc), {'b.txt'});
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(selected(bloc), {'a.txt'});
      // All five fit on one row here, so down stays put.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(selected(bloc), {'a.txt'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('scroll to what they reach', (tester) async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(() => File(p.join(root.path, 'z$i.txt')).writeAsString('z'));
      }
      final bloc = await open(tester);
      expect(find.text('z9.txt'), findsNothing);
      await press(tester, LogicalKeyboardKey.end);
      await settle(tester);
      expect(selected(bloc), {'z9.txt'});
      expect(find.text('z9.txt'), findsOneWidget);
      final bottom = tester.getBottomLeft(find.text('z9.txt')).dy;
      expect(bottom, lessThanOrEqualTo(800));
      await press(tester, LogicalKeyboardKey.home);
      await settle(tester);
      expect(selected(bloc), {'a.txt'});
      // Not under the header.
      expect(tester.getTopLeft(find.text('a.txt')).dy, greaterThan(80));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('dragging a band', () {
    testWidgets('from a blank part of a row selects the rows it covers', (tester) async {
      final bloc = await open(tester);
      await band(tester, blankOf(tester, 'b.txt'), blankOf(tester, 'd.txt'));
      expect(selected(bloc), {'b.txt', 'c.txt', 'd.txt'});
      expect(ticking(bloc), isTrue, reason: 'several selected: the selection bar shows');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('going back leaves rows again', (tester) async {
      final bloc = await open(tester);
      final mouse = await tester.startGesture(blankOf(tester, 'a.txt'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await mouse.moveTo(blankOf(tester, 'd.txt'));
      await tester.pump();
      expect(selected(bloc), {'a.txt', 'b.txt', 'c.txt', 'd.txt'});
      await mouse.moveTo(blankOf(tester, 'b.txt'));
      await tester.pump();
      expect(selected(bloc), {'a.txt', 'b.txt'});
      await mouse.up();
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('from the empty space under the list', (tester) async {
      final bloc = await open(tester);
      await band(tester, const Offset(900, 700), blankOf(tester, 'd.txt'));
      expect(selected(bloc), {'d.txt', 'e.txt'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('replaces the selection, or adds to it with Ctrl', (tester) async {
      final bloc = await open(tester);
      await click(tester, 'a.txt');
      await band(tester, blankOf(tester, 'd.txt'), blankOf(tester, 'e.txt'));
      expect(selected(bloc), {'d.txt', 'e.txt'});

      await press(tester, LogicalKeyboardKey.escape);
      await click(tester, 'a.txt');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await band(tester, blankOf(tester, 'd.txt'), blankOf(tester, 'e.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(selected(bloc), {'a.txt', 'd.txt', 'e.txt'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("doesn't start on a file's name or a selected row", (tester) async {
      final bloc = await open(tester);
      final name = tester.getCenter(find.text('b.txt'));
      expect(overDragPart(tester.element(find.text('b.txt')), name), isTrue);
      expect(overDragPart(tester.element(find.text('b.txt')), blankOf(tester, 'b.txt')), isFalse);

      await band(tester, name, blankOf(tester, 'd.txt'));
      expect(selected(bloc), isEmpty);

      await click(tester, 'b.txt');
      expect(overDragPart(tester.element(find.text('b.txt')), blankOf(tester, 'b.txt')), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('in a grid, starts between the tiles', (tester) async {
      final bloc = await open(tester);
      bloc.add(ChangeViewMode(ViewMode.grid));
      await settle(tester);
      final first = tester.getCenter(find.text('a.txt'));
      expect(overDragPart(tester.element(find.text('a.txt')), first), isTrue);
      await band(tester, const Offset(900, 700), tester.getCenter(find.text('c.txt')));
      expect(selected(bloc), containsAll(['c.txt', 'd.txt', 'e.txt']));
      expect(selected(bloc), isNot(contains('a.txt')));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
