import 'dart:io';

import 'package:folder/core/platform/desktop.dart';
import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/services/background_tasks.dart';
import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folder/features/file_explorere/widgets/file_list_item.dart';
import 'package:folder/features/network/screens/file_server_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Ctrl, or Cmd on macOS.
final commandKey =
    Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

/// Mouse and keyboard in the file list, as on a desktop (the tests run on
/// a desktop OS, so the desktop menus apply).
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_desktop_test');
    await Directory(p.join(root.path, 'Docs')).create();
    for (final name in ['alpha.txt', 'beta.txt', 'gamma.txt', '.hidden']) {
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
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Settles until [finder] finds something, for up to 100 rounds (about
  /// 10 s of real time; menus built from real file or system checks, like
  /// Convert to, take a while), then lets menu animations finish.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsWidgets, reason: 'not there after 100 rounds (~10 s real time)');
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final context = tester.element(find.byType(Scaffold).first);
    final bloc = BlocProvider.of<FileExplorerBloc>(context);
    for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester);
    }
    await settle(tester);
    return bloc;
  }

  FileListItem row(WidgetTester tester, String name) => tester.widget<FileListItem>(
        find.ancestor(of: find.text(name), matching: find.byType(FileListItem)),
      );

  Future<void> click(WidgetTester tester, String name, {int buttons = kPrimaryButton}) async {
    await tester.tap(find.text(name), kind: PointerDeviceKind.mouse, buttons: buttons);
    await tester.pump();
  }

  testWidgets('click highlights, double-click opens, hidden files are hidden', (tester) async {
    final bloc = await open(tester);
    expect(find.text('.hidden'), findsNothing, reason: 'hidden on desktop');

    await click(tester, 'alpha.txt');
    expect(row(tester, 'alpha.txt').isSelected, isTrue);
    expect((bloc.state as FileExplorerLoaded).isSelectionMode, isFalse,
        reason: 'one click only highlights');

    // Another item: the highlight moves.
    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'beta.txt');
    expect(row(tester, 'alpha.txt').isSelected, isFalse);
    expect(row(tester, 'beta.txt').isSelected, isTrue);

    // Double-click a folder opens it.
    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'Docs');
    await click(tester, 'Docs');
    await settle(tester);
    expect((bloc.state as FileExplorerLoaded).path, p.join(root.path, 'Docs'));
  });

  testWidgets('Ctrl-click and Shift-click select several; keys act on them', (tester) async {
    final bloc = await open(tester);
    FileExplorerLoaded state() => bloc.state as FileExplorerLoaded;

    await click(tester, 'alpha.txt');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(commandKey);
    await click(tester, 'gamma.txt');
    await tester.sendKeyUpEvent(commandKey);
    expect(state().selectedItems.map((e) => p.basename(e.path)), unorderedEquals(['alpha.txt', 'gamma.txt']));
    expect(state().isSelectionMode, isTrue, reason: 'several: the selection bar');

    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'alpha.txt');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await click(tester, 'gamma.txt');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(state().selectedItems.map((e) => p.basename(e.path)),
        unorderedEquals(['alpha.txt', 'beta.txt', 'gamma.txt']));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(state().selectedItems, isEmpty);

    await tester.sendKeyDownEvent(commandKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(commandKey);
    await tester.pump();
    expect(state().selectedItems, hasLength(4));
  });

  testWidgets('right-click shows a context menu', (tester) async {
    await open(tester);
    await click(tester, 'beta.txt', buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    for (final label in ['Open', 'Open with…', 'Copy', 'Rename', 'Properties', 'Delete']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(find.text(Platform.isMacOS ? '⌘C' : 'Ctrl+C'), findsOneWidget);
    expect(row(tester, 'beta.txt').isSelected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // On empty space: the folder's menu.
    await tester.tapAt(const Offset(900, 760), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Open in new window'), findsOneWidget);
  });

  testWidgets('right-click Share offers ways to share; a file is shared alone', (tester) async {
    await open(tester);
    await click(tester, 'beta.txt', buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Share file'), findsOneWidget);

    // Hovering opens the submenu beside it.
    // (The right-click above left the mouse added.)
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(find.text('Share file')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    for (final label in ['Web link on Wi-Fi (HTTP)', 'FTP server', 'LocalSend (nearby devices)']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('Web link on Wi-Fi (HTTP)'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final screen = tester.widget<FileServerScreen>(find.byType(FileServerScreen));
    expect(screen.initialFolder, root.path);
    expect(screen.only, [p.join(root.path, 'beta.txt')]);
    expect(screen.startNow, isTrue);
  });

  testWidgets('Ctrl+F searches here and in folders inside; Esc closes', (tester) async {
    // Real file work runs outside the test's fake clock.
    await tester.runAsync(
      () => File(p.join(root.path, 'Docs', 'alpha plan.md')).writeAsString('plan'),
    );
    final bloc = await open(tester);
    FileExplorerLoaded state() => bloc.state as FileExplorerLoaded;

    await tester.sendKeyDownEvent(commandKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(commandKey);
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);
    for (var i = 0; i < 20 && state().searching; i++) {
      await settle(tester);
    }
    expect(state().searchResults.map((e) => p.basename(e.path)), ['alpha.txt', 'alpha plan.md']);
    expect(find.text('alpha plan.md'), findsOneWidget);
    expect(find.text('in Docs'), findsOneWidget);
    expect(find.text('2 results'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('beta.txt'), findsOneWidget);
  });

  testWidgets('group by type puts items under headings', (tester) async {
    final bloc = await open(tester);
    bloc.add(ChangeGroupBy(GroupBy.type));
    await settle(tester);
    final groups = (bloc.state as FileExplorerLoaded).groups;
    expect(groups.first.label, 'Folder');
    expect(find.text('Folder'), findsWidgets);
    expect(groups.expand((g) => g.entities).map((e) => p.basename(e.path)),
        ['Docs', 'alpha.txt', 'beta.txt', 'gamma.txt']);

    bloc.add(ChangeGroupBy(GroupBy.none));
    await settle(tester);
    expect((bloc.state as FileExplorerLoaded).groups, isEmpty);
  });

  testWidgets('right-click a picture: Convert to and Resize', (tester) async {
    final photo = p.join(root.path, 'photo.png');
    await tester.runAsync(() => File(photo).writeAsBytes(img.encodePng(img.Image(width: 400, height: 200))));
    addTearDown(BackgroundTasks.instance.reset);
    await open(tester);

    Future<void> waitForTasks() async {
      for (var i = 0; i < 100 && (i < 2 || BackgroundTasks.instance.hasRunning); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await click(tester, 'photo.png', buttons: kSecondaryButton);
    await waitFor(tester, find.text('Convert to'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(find.text('Convert to')));
    await waitFor(tester, find.text('JPEG'));
    expect(find.text('PNG'), findsNothing, reason: "the picture's own format");
    for (final label in ['JPEG', 'WebP', 'HEIC', 'TIFF', 'ICO (icon)', 'SVG']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('JPEG'));
    await waitForTasks();
    expect(File(p.join(root.path, 'photo.jpg')).existsSync(), isTrue);

    await tester.pump(const Duration(seconds: 1));
    await click(tester, 'photo.png', buttons: kSecondaryButton);
    await waitFor(tester, find.text('Resize…'));
    await tester.tap(find.text('Resize…'));
    await waitFor(tester, find.text('Now 400 × 200 px'));
    expect(find.text('Now 400 × 200 px'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Width'), '100');
    await tester.pump();
    expect(find.widgetWithText(TextField, '50'), findsOneWidget, reason: 'height follows');
    await tester.tap(find.widgetWithText(FilledButton, 'Resize'));
    await waitForTasks();
    final resized = File(p.join(root.path, 'photo (100×50).png'));
    expect(resized.existsSync(), isTrue);
    final decoded = await tester.runAsync(() async => img.decodePng(await resized.readAsBytes()));
    expect([decoded!.width, decoded.height], [100, 50]);
  });

  testWidgets('new windows: header button, Ctrl+N, folders and files', (tester) async {
    final launched = <List<String>>[];
    final original = Desktop.launcher;
    Desktop.launcher = (executable, args) async => launched.add(args);
    addTearDown(() => Desktop.launcher = original);
    await open(tester);

    await tester.tap(find.byTooltip(Platform.isMacOS ? 'New window (⌘N)' : 'New window (Ctrl+N)'));
    await tester.pump();
    expect(launched.last, ['--folder=${root.path}']);

    await click(tester, 'alpha.txt');
    await tester.sendKeyDownEvent(commandKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(commandKey);
    await tester.pump();
    expect(launched, hasLength(2));
    expect(launched.last, ['--folder=${root.path}']);

    if (Platform.isMacOS) {
      // Control isn't the command key there: Control+N does nothing.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(launched, hasLength(2));
    }

    Future<void> openInNewWindow(String name) async {
      await tester.pump(const Duration(milliseconds: 400));
      await click(tester, name, buttons: kSecondaryButton);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Open in new window'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    // A folder opens in it; a file is viewed in it.
    await openInNewWindow('Docs');
    expect(launched.last, ['--folder=${p.join(root.path, 'Docs')}']);
    await openInNewWindow('beta.txt');
    expect(launched.last, [p.join(root.path, 'beta.txt')]);
    expect(Desktop.parseArgs(launched.last),
        (folder: root.path, file: p.join(root.path, 'beta.txt')));
  });
}
