@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folders/features/file_explorere/widgets/file_drag_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Move or copy on drop on macOS, as Finder decides.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('explorer_drop_test'));
  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('same volume moves, another copies; Option copies, Cmd moves', (tester) async {
    final file = File(p.join(root.path, 'a.txt'))..writeAsStringSync('a');
    final sameVolume = Directory(p.join(root.path, 'Pictures'))..createSync();
    // /dev is a volume of its own (devfs).
    const otherVolume = '/dev';
    final linkToOther = Link(p.join(root.path, 'dev'))..createSync(otherVolume);

    expect(dropMoves(file.path, sameVolume.path, fromThisApp: true), isTrue);
    expect(dropMoves(file.path, otherVolume, fromThisApp: true), isFalse);
    expect(dropMoves(file.path, linkToOther.path, fromThisApp: true), isFalse,
        reason: 'a folder that is a link counts where it points');
    expect(dropMoves(null, sameVolume.path, fromThisApp: false), isFalse, reason: 'from other apps: copy');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    expect(dropMoves(file.path, sameVolume.path, fromThisApp: true), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    expect(dropMoves(file.path, otherVolume, fromThisApp: true), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

    // Ctrl is File Explorer's copy key, not Finder's.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(dropMoves(file.path, sameVolume.path, fromThisApp: true), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets("what can't leave its folder is copied, Cmd or not", (tester) async {
    final destination = Directory(p.join(root.path, 'Desktop'))..createSync();
    final locked = Directory(p.join(root.path, 'Locked'))..createSync();
    final inLocked = File(p.join(locked.path, 'b.txt'))..writeAsStringSync('b');
    Process.runSync('chmod', ['555', locked.path]);
    addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

    // The sealed system volume reports the same device as the user's.
    const system = ['/System/Applications/Calculator.app', '/usr/bin/true'];
    for (final source in [...system, inLocked.path]) {
      expect(dropMoves(source, destination.path, fromThisApp: true), isFalse, reason: source);
    }

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    for (final source in [...system, inLocked.path]) {
      expect(dropMoves(source, destination.path, fromThisApp: true), isFalse, reason: 'Cmd: $source');
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  });
}
