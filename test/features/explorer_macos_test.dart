@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/services/file_action_service.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folder/features/file_explorere/widgets/file_list_item.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The file list on a Mac: packages and installers open like files, ⌘⌫
/// deletes, ⌘[ goes up, and Control-click opens the menus.
void main() {
  late Directory root;
  late Directory docs;
  final launched = <String>[];
  final originalLauncher = FileActionsService.packageLauncher;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_macos_test');
    docs = await Directory(p.join(root.path, 'Docs')).create();
    await Directory(p.join(docs.path, 'Tool.app', 'Contents')).create(recursive: true);
    await Directory(p.join(docs.path, 'Plans')).create();
    for (final name in ['alpha.txt', 'beta.txt']) {
      await File(p.join(docs.path, name)).writeAsString(name);
    }
    ExplorerPaths.startFolder = docs.path;
    launched.clear();
    FileActionsService.packageLauncher = (path) async {
      launched.add(path);
      return true;
    };
  });

  tearDown(() async {
    FileActionsService.packageLauncher = originalLauncher;
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
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

  String pathOf(FileExplorerBloc bloc) => (bloc.state as FileExplorerLoaded).path;

  FileListItem row(WidgetTester tester, String name) => tester.widget<FileListItem>(
        find.ancestor(of: find.text(name), matching: find.byType(FileListItem)),
      );

  Future<void> click(WidgetTester tester, String name, {int buttons = kPrimaryButton}) async {
    await tester.tap(find.text(name), kind: PointerDeviceKind.mouse, buttons: buttons);
    await tester.pump();
  }

  Future<void> menuOpens(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> withKey(WidgetTester tester, LogicalKeyboardKey modifier, Future<void> Function() action) async {
    await tester.sendKeyDownEvent(modifier);
    await action();
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('a package opens with macOS; its menu shows its contents', (tester) async {
    final bloc = await open(tester);
    final app = p.join(docs.path, 'Tool.app');

    await click(tester, 'Tool.app');
    await click(tester, 'Tool.app');
    await settle(tester);
    expect(launched, [app]);
    expect(pathOf(bloc), docs.path, reason: 'not opened as a folder');
    expect(find.text('1 folder · 3 files'), findsOneWidget, reason: 'counted as a file');

    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'Tool.app', buttons: kSecondaryButton);
    await menuOpens(tester);
    expect(find.text('Open in new window'), findsNothing);
    await tester.tap(find.text('Show package contents'));
    await settle(tester);
    expect(pathOf(bloc), app);
    expect(find.text('Contents'), findsOneWidget);
    expect(launched, hasLength(1));
  });

  testWidgets('an installer file opens with macOS', (tester) async {
    final installer = p.join(docs.path, 'Setup.pkg');
    await tester.runAsync(() => File(installer).writeAsString('xar!'));
    final bloc = await open(tester);

    await click(tester, 'Setup.pkg');
    await click(tester, 'Setup.pkg');
    await settle(tester);
    expect(launched, [installer]);
    expect(pathOf(bloc), docs.path);
    expect(find.text('Hex viewer'), findsNothing, reason: 'no Open with chooser');

    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'Setup.pkg', buttons: kSecondaryButton);
    await menuOpens(tester);
    expect(find.text('Open with…'), findsOneWidget, reason: 'still choosable');
    expect(find.text('Show package contents'), findsNothing);
  });

  testWidgets('an ordinary folder still opens in the list', (tester) async {
    final bloc = await open(tester);
    await click(tester, 'Plans', buttons: kSecondaryButton);
    await menuOpens(tester);
    expect(find.text('Show package contents'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await menuOpens(tester);

    await tester.pump(const Duration(milliseconds: 400));
    await click(tester, 'Plans');
    await click(tester, 'Plans');
    await settle(tester);
    expect(pathOf(bloc), p.join(docs.path, 'Plans'));
    expect(launched, isEmpty);
  });

  testWidgets('⌘⌫ deletes, backspace stays, ⌘[ goes up', (tester) async {
    final bloc = await open(tester);
    await click(tester, 'alpha.txt');
    expect(row(tester, 'alpha.txt').isSelected, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settle(tester);
    expect(pathOf(bloc), docs.path, reason: 'backspace is the delete key on a Mac');
    expect(find.text('Delete "alpha.txt"?'), findsNothing);

    await withKey(tester, LogicalKeyboardKey.metaLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.backspace));
    await menuOpens(tester);
    expect(find.text('Delete "alpha.txt"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await menuOpens(tester);
    expect(File(p.join(docs.path, 'alpha.txt')).existsSync(), isTrue);

    await withKey(tester, LogicalKeyboardKey.metaLeft,
        () => tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft));
    await settle(tester);
    expect(pathOf(bloc), root.path);
  });

  testWidgets('menus show ⌘⌫ for delete', (tester) async {
    await open(tester);
    await click(tester, 'beta.txt', buttons: kSecondaryButton);
    await menuOpens(tester);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text(FileActionsService.deleteShortcut), findsOneWidget);
    expect(FileActionsService.deleteShortcut, '⌘⌫');
  });

  testWidgets('Control-click opens the item and folder menus', (tester) async {
    await open(tester);
    await withKey(tester, LogicalKeyboardKey.controlLeft, () => click(tester, 'beta.txt'));
    await menuOpens(tester);
    expect(find.text('Open with…'), findsOneWidget);
    expect(row(tester, 'beta.txt').isSelected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await menuOpens(tester);

    await tester.pump(const Duration(milliseconds: 400));
    await withKey(tester, LogicalKeyboardKey.controlLeft, () async {
      await tester.tapAt(const Offset(900, 760), kind: PointerDeviceKind.mouse);
      await tester.pump();
    });
    await menuOpens(tester);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Open in new window'), findsOneWidget);
  });
}
