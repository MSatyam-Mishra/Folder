@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folder/core/services/localsend/localsend_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Where LocalSend saves received files on macOS when Downloads can't be
/// written, e.g. after a declined privacy prompt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Map<String, String> folders;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('localsend_destination');
    folders = {
      'getDownloadsDirectory': p.join(root.path, 'Downloads'),
      'getApplicationDocumentsDirectory': p.join(root.path, 'Documents'),
      'getApplicationSupportDirectory': p.join(root.path, 'Support'),
    };
    for (final folder in folders.values) {
      await Directory(folder).create();
    }
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => folders[call.method],
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    for (final folder in folders.values) {
      await Process.run('chmod', ['755', folder]);
    }
    await root.delete(recursive: true);
  });

  Future<void> refuse(String method) async {
    final result = await Process.run('chmod', ['555', folders[method]!]);
    expect(result.exitCode, 0);
  }

  test('Downloads/LocalSend when Downloads can be written', () async {
    final (dir, usedFallback) = await LsSettingsStore.defaultDestination();
    expect(dir, p.join(folders['getDownloadsDirectory']!, 'LocalSend'));
    expect(usedFallback, isFalse);
  });

  test('a refused Downloads falls back to Application Support', () async {
    await refuse('getDownloadsDirectory');
    final (dir, usedFallback) = await LsSettingsStore.defaultDestination();
    expect(dir, p.join(folders['getApplicationSupportDirectory']!, 'LocalSend'));
    expect(usedFallback, isTrue);
    expect(Directory(dir).existsSync(), isTrue);
    // ~/Documents asks for permission on macOS, so it isn't tried.
    expect(
      Directory(
        p.join(folders['getApplicationDocumentsDirectory']!, 'LocalSend'),
      ).existsSync(),
      isFalse,
    );
  });
}
