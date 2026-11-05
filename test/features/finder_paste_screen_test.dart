import 'dart:io';

import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/services/file_clipboard.dart';
import 'package:folder/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
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

/// Files copied in Finder on macOS 26, where reading them asks the user:
/// the pasteboard as the runner's 'explorer/mac_clipboard' channel shows it.
class _Pasteboard {
  List<String> paths = [];
  int count = 0;
  int reads = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'peek':
        return {'change': count, 'files': paths.isNotEmpty, 'explorer': false, 'quiet': false};
      case 'read':
        reads++;
        return paths;
      case 'changeCount':
        return count;
    }
    return null;
  }
}

/// The browser's Paste (folder menu, Cmd+V) takes files copied in Finder.
void main() {
  const channel = MethodChannel('explorer/mac_clipboard');
  late Directory root;
  late Directory here;
  late _Pasteboard pasteboard;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_finder_paste_screen');
    here = await Directory(p.join(root.path, 'here')).create();
    await File(p.join(here.path, 'existing.txt')).writeAsString('here');
    final finder = await Directory(p.join(root.path, 'finder')).create();
    await File(p.join(finder.path, 'from finder.txt')).writeAsString('finder');
    ExplorerPaths.startFolder = here.path;
    pasteboard = _Pasteboard()
      ..paths = [p.join(finder.path, 'from finder.txt')]
      ..count = 1;
    FileClipboard.instance = MacFileClipboard(Future.value(p.join(root.path, 'clipboard.json')));
  });

  tearDown(() async {
    ExplorerPaths.startFolder = null;
    FileClipboard.instance = MemoryFileClipboard();
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Opens the browser on the folder and waits until the clipboard saw
  /// Finder's files (without reading them).
  Future<ClipboardBloc> open(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, pasteboard.handle);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final context = tester.element(find.byType(Scaffold).first);
    final explorer = BlocProvider.of<FileExplorerBloc>(context);
    final clipboard = BlocProvider.of<ClipboardBloc>(context);
    for (var i = 0; i < 40 && (explorer.state is! FileExplorerLoaded || !clipboard.canPaste); i++) {
      await settle(tester);
    }
    expect(clipboard.state, isA<ClipboardOtherAppFiles>());
    expect(pasteboard.reads, 0, reason: 'not read before a paste');
    return clipboard;
  }

  /// Settles until Finder's file is pasted and shown.
  Future<void> pasted(WidgetTester tester) async {
    for (var i = 0; i < 40 && find.text('from finder.txt').evaluate().isEmpty; i++) {
      await settle(tester);
    }
    expect(find.text('from finder.txt'), findsOneWidget, reason: 'pasted and shown');
    expect(File(p.join(here.path, 'from finder.txt')).readAsStringSync(), 'finder');
    expect(pasteboard.reads, 1);
  }

  testWidgets('copied in Finder: Paste in the folder menu is on and pastes', (tester) async {
    await open(tester);
    await tester.tapAt(const Offset(900, 760), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    // Until it's open: the menu comes after real file work, then animates.
    for (var i = 0; i < 40 && find.text('Paste').evaluate().isEmpty; i++) {
      await settle(tester);
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final paste = find.ancestor(of: find.text('Paste'), matching: find.byType(PopupMenuItem<Object>));
    expect(tester.widget<PopupMenuItem<Object>>(paste).enabled, isTrue);
    await tester.tap(paste, kind: PointerDeviceKind.mouse);
    await pasted(tester);
  });

  testWidgets('copied in Finder: Cmd+V pastes', (tester) async {
    await open(tester);
    await tester.sendKeyDownEvent(commandKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(commandKey);
    await pasted(tester);
  });
}
