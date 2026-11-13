import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/file_explorere/widgets/checksum_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

const _helloSha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';

/// Checksums in a file's Properties.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('checksum_panel_test');
    await File(p.join(root.path, 'hello.txt')).writeAsString('hello');
    await File(p.join(root.path, 'SHA256SUMS.txt')).writeAsString('$_helloSha256  hello.txt\n');
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

  Future<void> seen(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(finder, findsWidgets);
  }

  testWidgets('calculates on request, copies, compares, and checks SHA256SUMS.txt', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester);
    }
    await seen(tester, find.text('hello.txt'));

    await tester.tap(find.text('hello.txt'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await seen(tester, find.byType(ChecksumPanel));
    await seen(tester, find.text('SHA256SUMS.txt lists this file'));
    expect(find.text(_helloSha256), findsNothing, reason: 'only when asked');

    await tester.tap(find.text('Calculate'));
    await seen(tester, find.text(_helloSha256));
    expect(find.text('5d41402abc4b2a76b9719d911017c592'), findsOneWidget);
    expect(find.byTooltip('Copy SHA-256'), findsOneWidget);

    final compare = find.widgetWithText(TextField, 'Compare');
    await tester.enterText(compare, _helloSha256.toUpperCase());
    await tester.pump();
    expect(find.text('Match (SHA-256)'), findsOneWidget);
    await tester.enterText(compare, 'aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434e');
    await tester.pump();
    expect(find.text('No match (SHA-1)'), findsOneWidget);
    await tester.enterText(compare, 'not a hash');
    await tester.pump();
    expect(find.textContaining('Not an MD5'), findsOneWidget);

    await tester.tap(find.text('Check'));
    await tester.pump();
    expect(find.text('Matches SHA256SUMS.txt (SHA-256)'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
