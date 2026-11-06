import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:path/path.dart' as p;

/// Folders are only ever made at real paths. On Windows a path with no drive
/// lands at the root of the current drive: Git Bash's "/c/Users" once left a
/// stray C:\c. And This PC is an address, not a folder.
void main() {
  test('a path needs a drive or a server to be a folder on Windows', () {
    for (final good in [r'C:\Users\me', 'C:/Users/me', r'D:\', r'\\server\share\folder']) {
      expect(ExplorerPaths.isFullWindowsPath(good), isTrue, reason: good);
    }
    for (final bad in ['/c/Users/me', '/tmp/x', r'\c\Users', 'c', 'Users/me', 'C:Users', ExplorerPaths.windowsRoots]) {
      expect(ExplorerPaths.isFullWindowsPath(bad), isFalse, reason: bad);
    }
  });

  test('This PC and the other virtual folders are not on disk', () {
    expect(ExplorerPaths.isOnDisk(ExplorerPaths.windowsRoots), isFalse);
    expect(ExplorerPaths.isOnDisk(p.join(Directory.systemTemp.path, 'x')), isTrue);
  });

  test('the user folder is a real folder', () {
    expect(ExplorerPaths.isOnDisk(ExplorerPaths.userFolder), isTrue);
    expect(Directory(ExplorerPaths.userFolder).existsSync(), isTrue);
  }, skip: Platform.isAndroid);

  test('on Windows it is the profile, not This PC', () {
    expect(ExplorerPaths.userFolder, Platform.environment['USERPROFILE']);
    expect(ExplorerPaths.homePath, ExplorerPaths.windowsRoots);
  }, skip: !Platform.isWindows);

  test('the code builds no path on the virtual home, and has no Git Bash paths', () {
    final problems = <String>[];
    final allowed = {'explorer_paths.dart', 'explorer_tabs.dart'};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      if (text.contains('ExplorerPaths.homePath') && !allowed.contains(p.basename(file.path))) {
        problems.add('${file.path}: homePath is This PC on Windows; use userFolder');
      }
      if (RegExp(r'''['"]/[a-zA-Z]/''').hasMatch(text)) {
        problems.add('${file.path}: a Git Bash path');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
