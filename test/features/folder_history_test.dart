import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/bloc/folder_history.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

void main() {
  group('FolderHistory', () {
    test('records visits, goes back and forward, drops what was ahead', () {
      final h = FolderHistory();
      expect(h.canBack, isFalse);
      expect(h.canForward, isFalse);
      h.visit('/a');
      h.visit('/a'); // A refresh.
      h.visit('/b');
      h.visit('/c');
      expect(h.entries, ['/a', '/b', '/c']);
      expect(h.backEntries, ['/b', '/a']);
      expect(h.back(), '/b');
      expect(h.back(), '/a');
      expect(h.back(), isNull);
      expect(h.current, '/a');
      expect(h.forwardEntries, ['/b', '/c']);
      expect(h.forward(), '/b');
      // A new folder from the middle: /c is gone.
      h.visit('/d');
      expect(h.entries, ['/a', '/b', '/d']);
      expect(h.canForward, isFalse);
      expect(h.go(-2), '/a');
      expect(h.go(5), isNull);
      expect(h.current, '/a');
    });

    test('keeps at most its limit, the oldest going first', () {
      final h = FolderHistory(limit: 3);
      for (final path in ['/1', '/2', '/3', '/4', '/5']) {
        h.visit(path);
      }
      expect(h.entries, ['/3', '/4', '/5']);
      expect(h.index, 2);
    });

    test('replace takes the place of the folder shown, never twice in a row', () {
      final h = FolderHistory()
        ..visit('/home/me/a')
        ..visit('/home/me/a/b');
      h.replace('/home/me/a');
      expect(h.entries, ['/home/me/a']);
      expect(h.canBack, isFalse);
      h.replace('/home/me');
      expect(h.entries, ['/home/me']);
      h.apply('/home/me/x', HistoryStep.record);
      h.apply('/home/me', HistoryStep.keep);
      expect(h.entries, ['/home/me', '/home/me/x']);
    });
  });

  group('in the browser', () {
    late Directory root;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('folder_history_test');
      await Directory(p.join(root.path, 'Docs', 'Inner')).create(recursive: true);
      await Directory(p.join(root.path, 'Music')).create();
      await File(p.join(root.path, 'note.txt')).writeAsString('hi');
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

    String? pathOf(FileExplorerBloc bloc) => switch (bloc.state) {
          FileExplorerLoaded(:final path) => path,
          _ => null,
        };

    Future<void> go(WidgetTester tester, FileExplorerBloc bloc, String path) async {
      bloc.add(LoadDirectory(path));
      await settle(tester);
      expect(pathOf(bloc), path);
    }

    Future<void> withAlt(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settle(tester);
    }

    testWidgets('Alt+Left and Alt+Right walk the history; Alt+Up goes up', (tester) async {
      final bloc = await open(tester);
      final docs = p.join(root.path, 'Docs');
      final inner = p.join(docs, 'Inner');
      final music = p.join(root.path, 'Music');
      await go(tester, bloc, inner);
      await go(tester, bloc, music);

      await withAlt(tester, LogicalKeyboardKey.arrowLeft);
      expect(pathOf(bloc), inner);
      await withAlt(tester, LogicalKeyboardKey.arrowLeft);
      expect(pathOf(bloc), root.path);
      await withAlt(tester, LogicalKeyboardKey.arrowRight);
      expect(pathOf(bloc), inner);

      // Up is a new visit: Forward to Music is gone.
      await withAlt(tester, LogicalKeyboardKey.arrowUp);
      expect(pathOf(bloc), docs);
      expect(bloc.history.canForward, isFalse);
      await withAlt(tester, LogicalKeyboardKey.arrowLeft);
      expect(pathOf(bloc), inner);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the header buttons, their lists, and the mouse side buttons', (tester) async {
      final bloc = await open(tester);
      final docs = p.join(root.path, 'Docs');
      final music = p.join(root.path, 'Music');
      await go(tester, bloc, docs);
      await go(tester, bloc, music);

      await tester.tap(find.byTooltip('Back (${Platform.isMacOS ? '⌘[' : 'Alt+Left'})'));
      await settle(tester);
      expect(pathOf(bloc), docs);
      await tester.tap(find.byTooltip('Forward (${Platform.isMacOS ? '⌘]' : 'Alt+Right'})'));
      await settle(tester);
      expect(pathOf(bloc), music);

      // A right-click on Back lists the folders behind, the nearest first.
      final back = find.byTooltip('Back (${Platform.isMacOS ? '⌘[' : 'Alt+Left'})');
      await tester.tap(back, buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('Go back to'), findsOneWidget);
      final rootName = p.basename(root.path);
      expect(find.text('Docs'), findsWidgets);
      await tester.tap(find.text(rootName).last);
      await settle(tester);
      expect(pathOf(bloc), root.path);
      expect(bloc.history.forwardEntries, [docs, music]);

      // The mouse's forward button, anywhere over the browser.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kForwardMouseButton);
      await mouse.down(const Offset(700, 500));
      await mouse.up();
      await settle(tester);
      expect(pathOf(bloc), docs);
      final backButton = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await backButton.down(const Offset(700, 500));
      await backButton.up();
      await settle(tester);
      expect(pathOf(bloc), root.path);

      // Up, from the header.
      await go(tester, bloc, p.join(docs, 'Inner'));
      await tester.tap(find.byTooltip('Up (${Platform.isMacOS ? '⌘↑' : 'Alt+Up'})'));
      await settle(tester);
      expect(pathOf(bloc), docs);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("system Back walks the history", (tester) async {
      final bloc = await open(tester);
      final docs = p.join(root.path, 'Docs');
      final inner = p.join(docs, 'Inner');
      await go(tester, bloc, inner);
      await go(tester, bloc, p.join(root.path, 'Music'));

      Future<void> systemBack() async {
        await tester.binding.handlePopRoute();
        await settle(tester);
      }

      await systemBack();
      expect(pathOf(bloc), inner);
      await systemBack();
      expect(pathOf(bloc), root.path);
      expect(bloc.history.canBack, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('past the start of the history, system Back goes up in its place', (tester) async {
      final docs = p.join(root.path, 'Docs');
      final inner = p.join(docs, 'Inner');
      ExplorerPaths.startFolder = inner;
      final bloc = await open(tester);
      expect(bloc.history.entries, [inner]);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(pathOf(bloc), docs);
      expect(bloc.history.entries, [docs], reason: "so the next Back doesn't return to Inner");
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(pathOf(bloc), root.path);
      expect(bloc.history.entries, [root.path]);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
