import 'dart:io';

import 'package:folder/core/platform/windows_drop_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('explorer/drop');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('gives the files the runner read at the drop', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'lastFiles' ? [r'C:\Temp\Rar$DRa1.2.rartemp\a b.svg'] : null,
    );
    expect(await WindowsDropFiles.last(), Platform.isWindows ? [r'C:\Temp\Rar$DRa1.2.rartemp\a b.svg'] : isEmpty);
  });

  test('gives nothing without the runner', () async {
    expect(await WindowsDropFiles.last(), isEmpty);
  });
}
