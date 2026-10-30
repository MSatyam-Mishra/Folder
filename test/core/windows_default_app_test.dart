import 'dart:io';

import 'package:explorer/core/platform/windows_default_app.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows: which program opens a type, so Explorer never hands a file to
/// itself (that started Explorer again and again for .apk files).
void main() {
  test('finds the program for a type; this app is not it', () {
    final notepad = WindowsDefaultApp.executableFor(r'C:\notes\read me.txt');
    expect(notepad, isNotNull);
    expect(notepad!.toLowerCase(), endsWith('.exe'));
    expect(WindowsDefaultApp.isThisApp(r'C:\notes\read me.txt'), isFalse);
    expect(WindowsDefaultApp.executableFor(r'C:\x\no-extension'), isNull);
    expect(WindowsDefaultApp.executableFor(r'C:\x\file.nosuchtype123'), isNull);
  }, skip: !Platform.isWindows);
}
