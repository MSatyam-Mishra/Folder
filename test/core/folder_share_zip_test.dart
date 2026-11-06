import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:folders/core/services/file_action_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Sharing a folder zips it into its own share folder. On macOS the app
/// shared with may read the zip after share() returns (AirDrop waits for a
/// device), so it stays until a share an hour later sweeps it; elsewhere it
/// goes as soon as share() returns.
void main() {
  late Directory root;
  late Directory temp;
  final shared = <String>[];
  final existedWhenShared = <bool>[];
  var shareFails = false;

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

  String shareRoot() => p.join(temp.path, 'explorer_share');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('folder_share_zip_test');
    temp = await Directory(p.join(root.path, 'tmp')).create();
    for (final (folder, files) in [
      ('Holiday', ['beach.txt', 'day 2/dinner.txt']),
      ('Work', ['plan.txt']),
    ]) {
      for (final name in files) {
        final file = File(p.join(root.path, folder, name));
        await file.create(recursive: true);
        await file.writeAsString(name);
      }
    }
    shared.clear();
    existedWhenShared.clear();
    shareFails = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async => temp.path);
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      if (shareFails) throw PlatformException(code: 'share', message: 'no');
      final paths = ((call.arguments as Map)['paths'] as List).cast<String>();
      shared.addAll(paths);
      existedWhenShared.addAll(paths.map((path) => File(path).existsSync()));
      return 'com.apple.share.AirDrop.send';
    });
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    await root.delete(recursive: true);
  });

  test('each share gets its own folder; only old ones are swept', () async {
    final recent = await FileActionsService.newShareDir(temp);
    final recentZip = File(p.join(recent.path, 'Recent.zip'));
    await recentZip.writeAsString('zip');
    expect(p.dirname(recent.path), shareRoot());

    final next = await FileActionsService.newShareDir(temp);
    expect(next.path, isNot(recent.path));
    expect(recentZip.existsSync(), isTrue, reason: 'may still be read');

    // Two hours on, both are old. A zip still being written (changed
    // later) keeps its folder.
    final later = DateTime.now().add(const Duration(hours: 2));
    final writing = File(p.join(next.path, 'Writing.zip'));
    await writing.writeAsString('zip');
    await writing.setLastModified(later);
    final fresh = await FileActionsService.newShareDir(temp, now: later);
    expect(recent.existsSync(), isFalse, reason: 'swept');
    expect(writing.existsSync(), isTrue, reason: 'still being written');
    expect(fresh.existsSync(), isTrue);
  });

  Future<BuildContext> app(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          context = c;
          return const SizedBox.expand();
        }),
      ),
    ));
    return context;
  }

  testWidgets('on macOS the zip stays after sharing', (tester) async {
    final context = await app(tester);
    final service = FileActionsService();

    // Real file work runs outside the test's fake clock.
    await tester.runAsync(
      () => service.shareZippedFolder(context, Directory(p.join(root.path, 'Holiday'))),
    );
    final first = shared.single;
    expect(p.basename(first), 'Holiday.zip');
    expect(p.isWithin(shareRoot(), first), isTrue);
    expect(existedWhenShared, [true]);
    expect(File(first).existsSync(), Platform.isMacOS,
        reason: 'kept for AirDrop on macOS only');
    if (Platform.isMacOS) {
      final names = ZipDecoder()
          .decodeBytes(File(first).readAsBytesSync())
          .files
          .map((f) => f.name.replaceAll(r'\', '/'));
      expect(names, unorderedEquals(['beach.txt', 'day 2/dinner.txt']));
    }

    await tester.runAsync(
      () => service.shareZippedFolder(context, Directory(p.join(root.path, 'Work'))),
    );
    final second = shared.last;
    expect(p.basename(second), 'Work.zip');
    expect(p.dirname(second), isNot(p.dirname(first)));
    expect(existedWhenShared.last, isTrue);
    expect(File(second).existsSync(), Platform.isMacOS);
    expect(File(first).existsSync(), Platform.isMacOS,
        reason: 'a recent share is not swept');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failed share leaves no zip behind', (tester) async {
    final context = await app(tester);
    shareFails = true;
    await tester.runAsync(
      () => FileActionsService()
          .shareZippedFolder(context, Directory(p.join(root.path, 'Work'))),
    );
    final left = await tester.runAsync(() => Directory(shareRoot())
        .list(recursive: true)
        .where((e) => e is File)
        .toList());
    expect(left, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });
}
