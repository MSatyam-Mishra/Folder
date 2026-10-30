import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/core/services/file_clipboard.dart';
import 'package:explorer/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:explorer/features/clipboard/paste_task.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/tasks/bloc/task_progress_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late Directory a;
  late Directory b;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('explorer_clipboard_test');
    a = await Directory(p.join(root.path, 'a')).create();
    b = await Directory(p.join(root.path, 'b')).create();
    await File(p.join(a.path, 'notes.txt')).writeAsString('notes');
    await File(p.join(a.path, 'photo.jpg')).writeAsString('jpeg');
    await File(p.join(a.path, 'album', 'one.jpg')).create(recursive: true);
    await File(p.join(a.path, 'album', 'one.jpg')).writeAsString('1');
    await File(p.join(a.path, 'album', 'deep', 'two.jpg')).create(recursive: true);
  });

  tearDown(() => root.delete(recursive: true));

  String name(String path) => p.relative(path, from: root.path).replaceAll(r'\', '/');
  List<String> names(Directory dir) =>
      (dir.listSync().map((e) => p.basename(e.path)).toList()..sort());

  group('pasteEntities', () {
    test('copies files and folders, keeping both when a name is taken', () async {
      await File(p.join(b.path, 'notes.txt')).writeAsString('other');
      final progress = <PasteProgress>[];
      final targets = await pasteEntities(
        [p.join(a.path, 'notes.txt'), p.join(a.path, 'album')],
        b.path,
        move: false,
        onProgress: progress.add,
      );
      expect(targets.map(name), ['b/notes (2).txt', 'b/album']);
      expect(File(p.join(b.path, 'notes.txt')).readAsStringSync(), 'other', reason: 'not overwritten');
      expect(File(p.join(b.path, 'notes (2).txt')).readAsStringSync(), 'notes');
      expect(File(p.join(b.path, 'album', 'deep', 'two.jpg')).existsSync(), isTrue);
      expect(File(p.join(a.path, 'notes.txt')).existsSync(), isTrue, reason: 'a copy');
      expect(progress.last.done, progress.last.total);
      expect(
        File(p.join(b.path, 'notes (2).txt')).lastModifiedSync(),
        File(p.join(a.path, 'notes.txt')).lastModifiedSync(),
      );
    });

    test('a copy into its own folder is "name - Copy"', () async {
      final notes = p.join(a.path, 'notes.txt');
      await pasteEntities([notes], a.path, move: false);
      await pasteEntities([notes], a.path, move: false);
      await pasteEntities([p.join(a.path, 'album')], a.path, move: false);
      expect(names(a), [
        'album',
        'album - Copy',
        'notes - Copy (2).txt',
        'notes - Copy.txt',
        'notes.txt',
        'photo.jpg',
      ]);
    });

    test('moves, and leaves things already in place alone', () async {
      final targets = await pasteEntities(
        [p.join(a.path, 'photo.jpg'), p.join(a.path, 'album')],
        b.path,
        move: true,
      );
      expect(targets.map(name), ['b/photo.jpg', 'b/album']);
      expect(names(a), ['notes.txt']);
      expect(names(b), ['album', 'photo.jpg']);

      final same = await pasteEntities([p.join(b.path, 'photo.jpg')], b.path, move: true);
      expect(same.map(name), ['b/photo.jpg']);
      expect(names(b), ['album', 'photo.jpg']);
    });

    test("a folder can't go into itself", () async {
      expect(
        pasteEntities([p.join(a.path, 'album')], p.join(a.path, 'album', 'deep'), move: false),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('ClipboardBloc', () {
    // Two windows share the clipboard.
    late FileClipboard shared;
    late ClipboardBloc first;
    late ClipboardBloc second;

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

    Future<ClipboardState> after(ClipboardBloc bloc, bool Function(ClipboardState) done) =>
        bloc.stream.firstWhere(done).timeout(const Duration(seconds: 10));

    setUp(() {
      shared = MemoryFileClipboard();
      first = ClipboardBloc(taskProgressBloc: TaskProgressBloc(), store: shared);
      second = ClipboardBloc(taskProgressBloc: TaskProgressBloc(), store: shared);
    });

    tearDown(() async {
      await first.close();
      await second.close();
    });

    test('copied in one window, pasted in another; the copy stays', () async {
      first.add(CopyToClipboard([File(p.join(a.path, 'notes.txt')), Directory(p.join(a.path, 'album'))]));
      await settle();
      final ready = second.state as ClipboardReadyToPaste;
      expect(ready.entities.map((e) => name(e.path)), ['a/notes.txt', 'a/album']);
      expect(ready.operation, ClipboardOperation.copy);

      final done = after(second, (s) => s is ClipboardReadyToPaste && s.pasted);
      second.add(PasteFromClipboard(b.path));
      await done;
      expect(names(b), ['album', 'notes.txt']);
      expect(first.state, isA<ClipboardReadyToPaste>(), reason: 'still on the clipboard');
    });

    test('cut in one window, pasted in another: moved, and gone everywhere', () async {
      first.add(CutToClipboard([File(p.join(a.path, 'photo.jpg'))]));
      await settle();
      expect((second.state as ClipboardReadyToPaste).operation, ClipboardOperation.cut);

      final done = after(second, (s) => s is ClipboardEmpty);
      second.add(PasteFromClipboard(b.path));
      await done;
      await settle();
      expect(names(b), ['photo.jpg']);
      expect(File(p.join(a.path, 'photo.jpg')).existsSync(), isFalse);
      expect(first.state, isA<ClipboardEmpty>());
    });

    test('a window opened later sees what was copied', () async {
      first.add(CopyToClipboard([File(p.join(a.path, 'notes.txt'))]));
      await settle();
      final third = ClipboardBloc(taskProgressBloc: TaskProgressBloc(), store: shared);
      addTearDown(third.close);
      await settle();
      expect(third.state, isA<ClipboardReadyToPaste>());
    });

    test('a failed paste says why and keeps the clipboard', () async {
      first.add(CopyToClipboard([Directory(p.join(a.path, 'album'))]));
      await settle();
      final failed = after(first, (s) => s is ClipboardPasteFailure);
      first.add(PasteFromClipboard(p.join(a.path, 'album', 'deep')));
      expect((await failed as ClipboardPasteFailure).error, contains("can't be pasted into itself"));
      await settle();
      expect(first.state, isA<ClipboardReadyToPaste>());
    });
  });

  test('the folder on screen reloads when its files change', () async {
    SharedPreferences.setMockInitialValues({});
    final bloc = FileExplorerBloc(watchFolders: true);
    addTearDown(bloc.close);
    bloc.add(LoadDirectory(b.path));
    await bloc.stream.firstWhere((s) => s is FileExplorerLoaded);

    final shown = bloc.stream.firstWhere(
      (s) => s is FileExplorerLoaded && s.entities.any((e) => p.basename(e.path) == 'new.txt'),
    );
    await File(p.join(b.path, 'new.txt')).writeAsString('from another window');
    await shown.timeout(const Duration(seconds: 10));
  });

  test('Windows clipboard file list format', () {
    final bytes = WindowsFileClipboard.dropFilesBytes([r'C:\a.txt', r'D:\b']);
    final data = bytes.buffer.asByteData();
    expect(data.getUint32(0, Endian.little), 20, reason: 'paths start after the header');
    expect(data.getUint32(16, Endian.little), 1, reason: 'UTF-16');
    final units = [for (var i = 20; i < bytes.length; i += 2) data.getUint16(i, Endian.little)];
    expect(String.fromCharCodes(units), 'C:\\a.txt\u0000D:\\b\u0000\u0000');
  });

  // Uses the real clipboard: EXPLORER_REAL_CLIPBOARD=1 flutter test …
  test('Windows clipboard round trip', () async {
    final clipboard = WindowsFileClipboard();
    final files = ClipboardFiles([p.join(a.path, 'notes.txt'), p.join(a.path, 'album')], cut: true);
    await clipboard.write(files);
    expect(await clipboard.read(), files);
    await clipboard.write(ClipboardFiles([p.join(a.path, 'photo.jpg')], cut: false));
    expect((await clipboard.read())!.cut, isFalse);
    await clipboard.clear();
    expect(await clipboard.read(), isNull);
  }, skip: !(Platform.isWindows && Platform.environment['EXPLORER_REAL_CLIPBOARD'] == '1'));

  // File Explorer's Paste (the shell's paste verb on a folder) takes what
  // Explorer copied or cut. Uses the real clipboard too.
  test('File Explorer pastes what Explorer copied or cut', () async {
    Future<void> shellPaste(Directory into) async {
      final result = await Process.run('powershell', [
        '-NoProfile', '-STA', '-Command',
        r"$s = New-Object -ComObject Shell.Application; "
            r"$s.Namespace($args[0]).ParseName($args[1]).InvokeVerb('paste'); "
            // The shell copies in the background: time to finish first.
            r'Start-Sleep -Seconds 3',
        p.dirname(into.path), p.basename(into.path),
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    final clipboard = WindowsFileClipboard();
    final notes = File(p.join(a.path, 'notes.txt'));
    final album = Directory(p.join(a.path, 'album'));
    await clipboard.write(ClipboardFiles([notes.path, album.path], cut: false));
    await shellPaste(b);
    await waitFor(() => File(p.join(b.path, 'notes.txt')).existsSync());
    expect(names(b), containsAll(['notes.txt', 'album']));
    expect(notes.existsSync(), isTrue, reason: 'copied, not moved');

    final c = await Directory(p.join(root.path, 'c')).create();
    await clipboard.write(ClipboardFiles([notes.path], cut: true));
    await shellPaste(c);
    await waitFor(() => !notes.existsSync());
    expect(names(c), ['notes.txt']);
    expect(notes.existsSync(), isFalse, reason: 'cut: moved');
    await clipboard.clear();
  }, skip: !(Platform.isWindows && Platform.environment['EXPLORER_REAL_CLIPBOARD'] == '1'));
}
