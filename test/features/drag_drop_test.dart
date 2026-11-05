import 'dart:io';

import 'package:folder/features/file_explorere/widgets/file_drag_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Move or copy on drop, as File Explorer decides.
void main() {
  final here = Platform.isWindows ? r'C:\Users\me\Documents\a.txt' : '/home/me/a.txt';
  final sameDrive = Platform.isWindows ? r'C:\Users\me\Pictures' : '/home/me/Pictures';
  final otherDrive = r'D:\Backup';

  testWidgets('same drive moves, another drive copies; Ctrl copies, Shift moves', (tester) async {
    expect(dropMoves(here, sameDrive, fromThisApp: true), isTrue);
    if (Platform.isWindows) expect(dropMoves(here, otherDrive, fromThisApp: true), isFalse);
    expect(dropMoves(null, sameDrive, fromThisApp: false), isFalse, reason: 'from other apps: copy');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(dropMoves(here, sameDrive, fromThisApp: true), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    expect(dropMoves(null, sameDrive, fromThisApp: false), isTrue);
    if (Platform.isWindows) expect(dropMoves(here, otherDrive, fromThisApp: true), isTrue);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }, skip: Platform.isMacOS); // Finder's rules there: drag_drop_macos_test.dart.
}
