import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/app_shortcuts.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Shortcuts to tools, in each system's own way.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shortcut = AppShortcut(
    id: 'tool_ram',
    title: 'RAM cleaner',
    description: 'Free memory',
    icon: Icons.memory,
    route: 'tool/ram_cleaner',
  );

  test('a command line asks for a screen, and nothing else is taken for one', () {
    expect(AppShortcuts.routeIn(['--route=tool/ram_cleaner']), 'tool/ram_cleaner');
    expect(AppShortcuts.routeIn(['--folder=C:/x', r'C:\route.txt']), isNull);
  });

  test('each tool has a route that finds it again', () {
    for (final tool in Tool.values) {
      // As on Android, which has every tool (the document scanner only there).
      expect(Tool.fromRoute(tool.shortcut.route, android: true), tool);
    }
    expect(Tool.fromRoute('video_downloader'), isNull);
  });

  test("a file name keeps the title, without what files can't hold", () {
    expect(AppShortcuts.fileNameFor('RAM cleaner'), 'RAM cleaner');
    expect(AppShortcuts.fileNameFor(r'a/b\c:d*e?f"g<h>i|j'), 'abcdefghij');
  });

  test('Linux: a .desktop entry that starts this app at the tool, whatever the path', () {
    final entry = AppShortcuts.desktopEntry(shortcut, ['/opt/My Apps/explorer'], '/icons/ram.png');
    final lines = const LineSplitter().convert(entry);
    expect(lines.first, '[Desktop Entry]');
    expect(lines, contains('Exec="/opt/My Apps/explorer" --route=tool/ram_cleaner'));
    expect(lines, contains('Icon=/icons/ram.png'));
    expect(lines, contains('Name=RAM cleaner'));
    expect(lines, contains('Terminal=false'));
    expect(
      const LineSplitter().convert(AppShortcuts.desktopEntry(shortcut, ['flatpak', 'run', 'com.x'], '/i.png')),
      contains('Exec=flatpak run com.x --route=tool/ram_cleaner'),
    );
    expect(
      AppShortcuts.desktopEntry(shortcut, [r'/a$b%c'], '/i.png'),
      contains(r'Exec="/a\$b%%c"'),
      reason: 'the spec keeps these for itself',
    );
  });

  test('macOS: a small app that opens this one, with the quotes right', () {
    final script = AppShortcuts.macScript("/Apps/Satyam's/Folders.app", ['--route=tool/ram_cleaner']);
    expect(script, startsWith('#!/bin/sh\n'));
    expect(script, contains(r"/usr/bin/open -n '/Apps/Satyam'\''s/Folders.app' --args '--route=tool/ram_cleaner'"));
    final plist = AppShortcuts.macInfoPlist(const AppShortcut(
      id: 'x',
      title: 'A & B',
      description: '',
      icon: Icons.memory,
      route: 'tool/x',
    ));
    expect(plist, contains('<string>A &amp; B</string>'));
    expect(plist, contains('<key>CFBundleExecutable</key><string>run</string>'));
  });

  testWidgets('the icon is a picture of the asked size, solid in the middle', (tester) async {
    final png = await tester.runAsync(
      () => AppShortcuts.drawIcon(Icons.memory, colors: const [Colors.blue, Colors.green], size: 64),
    );
    final image = img.decodePng(png!)!;
    expect((image.width, image.height), (64, 64));
    expect(image.getPixel(0, 0).a, 0, reason: 'rounded, so its corner is clear');
    expect(image.getPixel(8, 32).a, 255);

    final bleed = await tester.runAsync(
      () => AppShortcuts.drawIcon(Icons.memory, colors: const [Colors.blue, Colors.green], size: 64, fullBleed: true),
    );
    expect(img.decodePng(bleed!)!.getPixel(0, 0).a, 255, reason: 'launchers cut their own shape');
  });

  group('on Windows, for real', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('explorer_shortcut');
    });

    tearDown(() => root.delete(recursive: true));

    testWidgets('a .lnk that starts this program at the tool, under its own icon', (tester) async {
      final folder = Directory(p.join(root.path, 'Desktop'));
      await tester.runAsync(() async {
        await folder.create();
        final added = await AppShortcuts.add(
          shortcut,
          ShortcutPlace.desktop,
          colors: const [Colors.blue, Colors.green],
          folder: folder,
        );
        expect(added, isTrue);
        final link = p.join(folder.path, 'RAM cleaner.lnk');
        expect(File(link).existsSync(), isTrue);
        final read = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'$l = (New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK); '
              r'$l.TargetPath; $l.Arguments; $l.IconLocation; $l.Description',
        ], environment: {'LNK': link});
        final lines = const LineSplitter().convert(read.stdout as String);
        expect(p.equals(lines[0], Platform.resolvedExecutable), isTrue);
        expect(lines[1], '"--route=tool/ram_cleaner"');
        final icon = lines[2].split(',').first;
        expect(p.basename(icon), 'tool_ram.ico');
        expect(File(icon).readAsBytesSync()[4], 5, reason: 'sizes in the file, as its header counts them');
        expect(lines[3], 'Free memory');
      });
    }, skip: !Platform.isWindows);
  });
}
