import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/platform/terminal.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/themed_app.dart';

void main() {
  group('which terminal', () {
    String? Function(String) only(Set<String> installed) =>
        (program) => installed.contains(program) ? '/usr/bin/$program' : null;

    test('Windows: Windows Terminal if there, else PowerShell in a console of its own', () {
      final wt = Terminal.commandFor(r'C:\Users\me',
          system: 'windows', environment: const {}, find: (p) => p == 'wt.exe' ? r'C:\Apps\wt.exe' : null)!;
      expect(wt.executable, r'C:\Apps\wt.exe');
      expect(wt.arguments, ['-d', '.']);
      expect(wt.workingDirectory, r'C:\Users\me');
      expect(wt.newConsole, isFalse);

      final ps = Terminal.commandFor(r'C:\', system: 'windows', environment: const {}, find: (_) => null)!;
      expect(ps.executable, 'powershell.exe');
      expect(ps.arguments, ['-NoExit']);
      expect(ps.workingDirectory, r'C:\');
      expect(ps.newConsole, isTrue);
    });

    test('macOS: Terminal', () {
      final mac = Terminal.commandFor('/Users/me/Code', system: 'macos', environment: const {})!;
      expect([mac.executable, ...mac.arguments], ['/usr/bin/open', '-a', 'Terminal', '/Users/me/Code']);
    });

    test(r'Linux: $TERMINAL first, then the usual ones, each with its own flag', () {
      expect(Terminal.commandFor('/home/me', system: 'linux', environment: const {}, find: only({})), isNull);

      final chosen = Terminal.commandFor('/home/me',
          system: 'linux', environment: const {'TERMINAL': 'kitty --single-instance'}, find: only({'kitty', 'konsole'}))!;
      expect(chosen.executable, '/usr/bin/kitty');
      expect(chosen.arguments, ['--single-instance', '--directory', '/home/me']);

      final cases = <String, List<String>>{
        'x-terminal-emulator': [],
        'gnome-terminal': ['--working-directory=/home/me'],
        'konsole': ['--workdir', '/home/me'],
        'xfce4-terminal': ['--working-directory=/home/me'],
        'kitty': ['--directory', '/home/me'],
        'alacritty': ['--working-directory', '/home/me'],
        'foot': ['--working-directory=/home/me'],
        'wezterm': ['start', '--cwd', '/home/me'],
      };
      for (final MapEntry(key: name, value: args) in cases.entries) {
        final command = Terminal.commandFor('/home/me', system: 'linux', environment: const {}, find: only({name}))!;
        expect(command.executable, '/usr/bin/$name');
        expect(command.arguments, args, reason: name);
        expect(command.workingDirectory, '/home/me');
      }
      // gnome-terminal comes before konsole.
      final both = Terminal.commandFor('/home/me',
          system: 'linux', environment: const {}, find: only({'konsole', 'gnome-terminal'}))!;
      expect(both.executable, '/usr/bin/gnome-terminal');
    });

    test('not for virtual or remote places', () {
      expect(Terminal.canOpen(ExplorerPaths.trash), isFalse);
      expect(Terminal.canOpen(ExplorerPaths.windowsRoots), isFalse);
      expect(Terminal.canOpen('explorer://remote/nas/Photos'), isFalse);
      expect(Terminal.canOpen(Directory.systemTemp.path), isTrue);
    });
  });

  group('in the browser', () {
    late Directory root;
    final launched = <TerminalCommand>[];
    final original = Terminal.launcher;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('terminal_test');
      await Directory(p.join(root.path, 'Code')).create();
      await File(p.join(root.path, 'readme.txt')).writeAsString('hi');
      ExplorerPaths.startFolder = root.path;
      launched.clear();
      Terminal.launcher = (command) async => launched.add(command);
    });

    tearDown(() async {
      Terminal.launcher = original;
      ExplorerPaths.startFolder = null;
      await root.delete(recursive: true);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> menuOpens(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('F4, the folder menu and a folder\'s menu open a terminal there', (tester) async {
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

      await tester.tap(find.text('readme.txt'), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await settle(tester);
      expect(launched.single.workingDirectory, root.path);

      // The space around the items.
      await tester.tapAt(const Offset(900, 700), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await menuOpens(tester);
      expect(find.text('Open in Terminal'), findsOneWidget);
      await tester.tap(find.text('Open in Terminal'));
      await settle(tester);
      expect(launched, hasLength(2));
      expect(launched.last.workingDirectory, root.path);

      // A folder's own menu.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Code'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await menuOpens(tester);
      await tester.tap(find.text('Open in Terminal'));
      await settle(tester);
      expect(launched.last.workingDirectory, p.join(root.path, 'Code'));

      // Not for a file.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('readme.txt'), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
      await menuOpens(tester);
      expect(find.text('Open in Terminal'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await menuOpens(tester);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
