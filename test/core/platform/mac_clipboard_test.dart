import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/file_clipboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The macOS pasteboard as the runner's 'explorer/mac_clipboard' channel
/// shows it.
class _Pasteboard {
  List<String> paths = [];
  int count = 0;

  /// Whether an Folders window put the files there.
  bool explorer = false;

  /// Whether reading another app's files goes ahead without the system
  /// asking (false: macOS 26 asks).
  bool quiet = true;

  /// How many times the files' paths were read.
  int reads = 0;

  /// Another app (Finder) puts files on it.
  void copyElsewhere(List<String> files) {
    count++;
    paths = files;
    explorer = false;
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'write':
        count++;
        // macOS hands paths back decomposed (é as e and an accent).
        paths = [
          for (final path in ((call.arguments as Map)['paths'] as List).cast<String>())
            path.replaceAll('é', 'é'),
        ];
        explorer = paths.isNotEmpty;
        return count;
      case 'peek':
        return {'change': count, 'files': paths.isNotEmpty, 'explorer': explorer, 'quiet': quiet};
      case 'read':
        reads++;
        return paths;
      case 'changeCount':
        return count;
      case 'clear':
        if (paths.isNotEmpty) {
          count++;
          paths = [];
          explorer = false;
        }
        return null;
    }
    throw MissingPluginException();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('explorer/mac_clipboard');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late _Pasteboard pasteboard;
  late Future<String> file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('explorer_mac_clipboard');
    file = Future.value(p.join(dir.path, 'clipboard.json'));
    pasteboard = _Pasteboard();
    messenger.setMockMethodCallHandler(channel, pasteboard.handle);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  test('files go on the pasteboard; cut is shared with the other windows', () async {
    final window = MacFileClipboard(file);
    final other = MacFileClipboard(file);

    await window.write(const ClipboardFiles(['/a/notes.txt', '/a/album'], cut: false));
    expect(pasteboard.paths, ['/a/notes.txt', '/a/album']);
    expect(await other.read(), const ClipboardFiles(['/a/notes.txt', '/a/album'], cut: false));

    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));
    expect(await other.read(), const ClipboardFiles(['/a/notes.txt'], cut: true));
    expect(pasteboard.reads, 0, reason: "Folders' own files come from the shared file");
  });

  test('a cut name with accents stays a cut in the other windows', () async {
    final window = MacFileClipboard(file);
    final other = MacFileClipboard(file);
    await window.write(const ClipboardFiles(['/a/Résumé.pdf'], cut: true));
    expect(pasteboard.paths, ['/a/Résumé.pdf']);
    expect(await other.read(), const ClipboardFiles(['/a/Résumé.pdf'], cut: true));
  });

  test('files copied in Finder paste as a copy, even after a cut', () async {
    final window = MacFileClipboard(file);
    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));

    pasteboard.copyElsewhere(['/b/photo.jpg']);
    expect(await window.read(), const ClipboardFiles(['/b/photo.jpg'], cut: false));

    pasteboard.copyElsewhere(['/a/notes.txt']);
    expect(await window.read(), const ClipboardFiles(['/a/notes.txt'], cut: false),
        reason: 'the same file copied again in Finder is a copy');

    pasteboard.copyElsewhere([]);
    expect(await window.read(), isNull, reason: 'text or a picture, not files');
  });

  test("a change count that started again (after logging out) isn't taken for a cut", () async {
    final window = MacFileClipboard(file);
    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));
    pasteboard.count = 0;
    pasteboard.copyElsewhere(['/b/photo.jpg']);
    expect(await window.read(), const ClipboardFiles(['/b/photo.jpg'], cut: false));
  });

  test("when the system would ask, Finder's files are read only to paste", () async {
    pasteboard.quiet = false;
    final window = MacFileClipboard(file);

    pasteboard.copyElsewhere(['/b/photo.jpg']);
    expect(await window.read(), isNull);
    expect(pasteboard.reads, 0);
    expect(await window.readToPaste(), const ClipboardFiles(['/b/photo.jpg'], cut: false));
    expect(pasteboard.reads, 1);

    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));
    expect(await MacFileClipboard(file).read(), const ClipboardFiles(['/a/notes.txt'], cut: true));
    expect(pasteboard.reads, 1, reason: "Folders' own files need no asking");
  });

  test('a read during a write sees the write finished', () async {
    final window = MacFileClipboard(file);
    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: false));
    final writing = window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));
    expect(await window.read(), const ClipboardFiles(['/a/notes.txt'], cut: true));
    await writing;
  });

  test('clearing empties the pasteboard and the shared file', () async {
    final window = MacFileClipboard(file);
    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));
    await window.clear();
    expect(pasteboard.paths, isEmpty);
    expect(File(await file).existsSync(), isFalse);
    expect(await window.read(), isNull);
  });

  test('a change on the pasteboard is noticed', () async {
    final window = MacFileClipboard(file);
    final changed = Completer<void>();
    final sub = window.changes.listen((_) {
      if (pasteboard.paths.isNotEmpty && !changed.isCompleted) changed.complete();
    });
    addTearDown(sub.cancel);
    // Let the first look settle, then Finder copies something.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    pasteboard.copyElsewhere(['/b/photo.jpg']);
    await changed.future.timeout(const Duration(seconds: 5));
  });

  test('without the native channel it works like the Linux shared file', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final window = MacFileClipboard(file);
    final other = MacFileClipboard(file);
    await window.write(const ClipboardFiles(['/a/notes.txt'], cut: true));
    expect(await other.read(), const ClipboardFiles(['/a/notes.txt'], cut: true));
    await window.clear();
    expect(await other.read(), isNull);
  });
}
