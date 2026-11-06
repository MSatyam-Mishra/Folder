import 'dart:io';

import 'package:folders/core/platform/desktop.dart';
import 'package:flutter_test/flutter_test.dart';

/// New windows (how the app starts another copy of itself) and the media
/// players' setup on desktops.
void main() {
  group('windowCommand', () {
    const exe = '/Applications/Folders.app/Contents/MacOS/Folders';

    /// The command as a list: the program, then its arguments.
    List<String> command(String executable, List<String> args,
        {required bool macOS}) {
      final (program, programArgs) =
          Desktop.windowCommand(executable, args, macOS: macOS);
      return [program, ...programArgs];
    }

    test('macOS starts the bundle through LaunchServices', () {
      expect(command(exe, ['--folder=/Users/me/Docs'], macOS: true), [
        '/usr/bin/open',
        '-n',
        '/Applications/Folders.app',
        '--args',
        '--folder=/Users/me/Docs',
      ]);
      const file = '/Users/me/My Notes/a b.txt';
      expect(command(exe, [file], macOS: true),
          ['/usr/bin/open', '-n', '/Applications/Folders.app', '--args', file]);
      expect(command(exe, [], macOS: true),
          ['/usr/bin/open', '-n', '/Applications/Folders.app']);
    });

    test('a binary outside an .app bundle runs as it is', () {
      for (final path in [
        '/Users/me/flutter/bin/cache/artifacts/engine/darwin-x64/flutter_tester',
        '/opt/Folders.app/Folders',
        '/opt/Folders/Contents/MacOS/Folders',
      ]) {
        expect(command(path, ['--folder=/tmp'], macOS: true),
            [path, '--folder=/tmp']);
      }
    });

    test('Windows and Linux are unchanged', () {
      for (final path in [
        r'C:\Program Files\Folders\explorer.exe',
        '/usr/lib/explorer/explorer',
        exe,
      ]) {
        expect(command(path, ['--folder=/tmp'], macOS: false),
            [path, '--folder=/tmp']);
      }
    });

    test('openWindow hands the command to the launcher', () async {
      final launched = <List<String>>[];
      final original = Desktop.launcher;
      Desktop.launcher =
          (executable, args) async => launched.add([executable, ...args]);
      addTearDown(() => Desktop.launcher = original);

      // The test runner isn't inside an .app, so it runs as it is.
      await Desktop.openWindow(folder: '/tmp/a');
      await Desktop.openWindow(file: '/tmp/a/b.txt', folder: '/tmp/a');
      expect(launched, [
        [Platform.resolvedExecutable, '--folder=/tmp/a'],
        [Platform.resolvedExecutable, '/tmp/a/b.txt'],
      ]);
    });
  });

  test(
    'macOS without Mpv.framework still starts, and says it has no player',
    () {
      // The test runner has no Mpv.framework next to it.
      expect(Desktop.initMedia, returnsNormally);
      expect(Desktop.macMediaKit, isFalse);
    },
    testOn: 'mac-os',
  );
}
