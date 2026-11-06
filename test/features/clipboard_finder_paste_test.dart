import 'dart:io';

import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/file_clipboard.dart';
import 'package:folders/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folders/features/tasks/bloc/task_progress_bloc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The macOS pasteboard as the runner's 'explorer/mac_clipboard' channel
/// shows it, with Finder copying files on macOS 26 (reading them asks the
/// user, so it's left until they paste).
class _Pasteboard {
  List<String> paths = [];
  int count = 0;
  bool explorer = false;

  /// Whether reading another app's files goes ahead without asking.
  bool quiet = false;

  /// How many times the files' paths were read.
  int reads = 0;

  /// The user chooses Don't Allow when macOS asks: nothing is read.
  bool deny = false;

  /// Finder copies files.
  void copyInFinder(List<String> files) {
    count++;
    paths = files;
    explorer = false;
  }

  /// Something that isn't a file (text) is copied.
  void copyText() {
    count++;
    paths = [];
    explorer = false;
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'write':
        count++;
        paths = ((call.arguments as Map)['paths'] as List).cast<String>();
        explorer = paths.isNotEmpty;
        return count;
      case 'peek':
        return {'change': count, 'files': paths.isNotEmpty, 'explorer': explorer, 'quiet': quiet};
      case 'read':
        reads++;
        return deny ? <String>[] : paths;
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

/// A pasteboard watcher that hasn't caught up: it never hands files over
/// before a paste, as when Cmd+V comes right after the copy.
class _Behind extends MacFileClipboard {
  _Behind(super.path);

  @override
  Future<ClipboardFiles?> read() async => null;
}

/// A pasteboard watcher that looks only once, at the start: every paste
/// comes within 0.7 s of the copy before it.
class _Unwatched extends MacFileClipboard {
  _Unwatched(super.path);

  @override
  Stream<void> get changes => const Stream.empty();
}

/// Files copied in Finder paste into Folders on macOS: they're read only
/// when the user pastes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('explorer/mac_clipboard');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Directory finder;
  late Directory here;
  late Future<String> file;
  late _Pasteboard pasteboard;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('explorer_finder_paste');
    finder = await Directory(p.join(root.path, 'finder')).create();
    here = await Directory(p.join(root.path, 'here')).create();
    await File(p.join(finder.path, 'notes.txt')).writeAsString('notes');
    await File(p.join(finder.path, 'album', 'one.jpg')).create(recursive: true);
    file = Future.value(p.join(root.path, 'clipboard.json'));
    pasteboard = _Pasteboard();
    messenger.setMockMethodCallHandler(channel, pasteboard.handle);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  List<String> names(Directory dir) => (dir.listSync().map((e) => p.basename(e.path)).toList()..sort());

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  Future<ClipboardState> after(ClipboardBloc bloc, bool Function(ClipboardState) done) =>
      bloc.stream.firstWhere(done).timeout(const Duration(seconds: 10));

  ClipboardBloc window(FileClipboard store) {
    final bloc = ClipboardBloc(taskProgressBloc: TaskProgressBloc(), store: store);
    addTearDown(bloc.close);
    return bloc;
  }

  test('copied in Finder: Paste is on, and the files are read and copied only on paste', () async {
    pasteboard.copyInFinder([p.join(finder.path, 'notes.txt'), p.join(finder.path, 'album')]);
    final bloc = window(MacFileClipboard(file));
    await settle();
    expect(bloc.state, isA<ClipboardOtherAppFiles>());
    expect(bloc.canPaste, isTrue);
    expect(pasteboard.reads, 0, reason: "not read before a paste, so macOS doesn't ask");

    final done = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    final pasted = await done as ClipboardReadyToPaste;
    expect(names(here), ['album', 'notes.txt']);
    expect(File(p.join(finder.path, 'notes.txt')).existsSync(), isTrue, reason: 'a copy');
    expect(pasted.operation, ClipboardOperation.copy);
    expect(pasteboard.reads, 1);

    // Again: the files already read, so no second read (or question).
    final again = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await again;
    expect(names(here), ['album', 'album (2)', 'notes (2).txt', 'notes.txt']);
    expect(pasteboard.reads, 1);
  });

  test('nothing on the pasteboard: Paste is off and does nothing', () async {
    final bloc = window(MacFileClipboard(file));
    await settle();
    expect(bloc.state, isA<ClipboardEmpty>());
    expect(bloc.canPaste, isFalse);
    bloc.add(PasteFromClipboard(here.path));
    await settle();
    expect(names(here), isEmpty);
    expect(bloc.state, isA<ClipboardEmpty>());
  });

  test('copying something else turns Paste off again', () async {
    pasteboard.copyInFinder([p.join(finder.path, 'notes.txt')]);
    final bloc = window(MacFileClipboard(file));
    await settle();
    expect(bloc.state, isA<ClipboardOtherAppFiles>());

    final emptied = after(bloc, (s) => s is ClipboardEmpty && s is! ClipboardOtherAppFiles);
    pasteboard.copyText();
    await emptied; // The pasteboard is checked every 0.7 s.
    expect(bloc.canPaste, isFalse);
  });

  test('pasted right after the copy, before the watcher saw it', () async {
    final bloc = window(_Behind(file));
    await settle();
    pasteboard.copyInFinder([p.join(finder.path, 'notes.txt')]);
    expect(bloc.state, isNot(isA<ClipboardReadyToPaste>()));

    final done = after(bloc, (s) => s is ClipboardPasteSuccess);
    bloc.add(PasteFromClipboard(here.path));
    await done;
    expect(names(here), ['notes.txt']);
  });

  test('cut in another Folders window and pasted before this one saw it: moved', () async {
    final other = MacFileClipboard(file);
    await other.write(ClipboardFiles([p.join(finder.path, 'notes.txt')], cut: true));
    final bloc = window(_Behind(file));
    await settle();

    final done = after(bloc, (s) => s is ClipboardEmpty && s is! ClipboardOtherAppFiles);
    bloc.add(PasteFromClipboard(here.path));
    await done;
    await settle();
    expect(names(here), ['notes.txt']);
    expect(File(p.join(finder.path, 'notes.txt')).existsSync(), isFalse);
    expect(pasteboard.paths, isEmpty, reason: 'moved: nothing left to paste');
  });

  test('copied again in Finder right after a paste: the new files paste', () async {
    pasteboard.copyInFinder([p.join(finder.path, 'notes.txt')]);
    final bloc = window(_Unwatched(file));
    await settle();
    final first = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await first;
    expect(names(here), ['notes.txt']);

    // Not seen by the watcher yet: the paste looks again.
    pasteboard.copyInFinder([p.join(finder.path, 'album')]);
    final second = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await second;
    expect(names(here), ['album', 'notes.txt'], reason: 'not the notes again');
    expect(pasteboard.reads, 2);

    // Nothing copied since: no new read.
    final third = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await third;
    expect(names(here), ['album', 'album (2)', 'notes.txt']);
    expect(pasteboard.reads, 2);
  });

  test('copied in Folders, then in Finder: Finder\'s files paste', () async {
    final bloc = window(_Unwatched(file));
    await settle();
    bloc.add(CopyToClipboard([File(p.join(finder.path, 'notes.txt'))]));
    await settle();
    final first = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await first;
    expect(names(here), ['notes.txt']);
    expect(pasteboard.reads, 0, reason: "Folders' own files come from the shared file");

    pasteboard.copyInFinder([p.join(finder.path, 'album')]);
    final second = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await second;
    expect(names(here), ['album', 'notes.txt']);
    expect(pasteboard.reads, 1);
  });

  test('Finder files that are gone: nothing pasted, and the user is told', () async {
    pasteboard.copyInFinder([p.join(finder.path, 'deleted.txt')]);
    final bloc = window(MacFileClipboard(file));
    await settle();
    BackgroundTasks.instance.reset();
    final states = <ClipboardState>[];
    final listening = bloc.stream.listen(states.add);
    addTearDown(listening.cancel);
    final failed = after(bloc, (s) => s is ClipboardPasteFailure);
    bloc.add(PasteFromClipboard(here.path));
    expect((await failed as ClipboardPasteFailure).error, contains('no longer there'));
    await settle();
    expect(pasteboard.reads, 1);
    expect(names(here), isEmpty);
    expect(states.whereType<ClipboardPasteSuccess>(), isEmpty);
    expect(BackgroundTasks.instance.all, isEmpty, reason: 'no copy started');
    expect(bloc.state, isA<ClipboardOtherAppFiles>());
  });

  test("Don't Allow: nothing pasted, the user is told, and Paste stays on", () async {
    pasteboard
      ..copyInFinder([p.join(finder.path, 'notes.txt')])
      ..deny = true;
    final bloc = window(MacFileClipboard(file));
    await settle();
    final failed = after(bloc, (s) => s is ClipboardPasteFailure);
    bloc.add(PasteFromClipboard(here.path));
    expect((await failed as ClipboardPasteFailure).error, contains("didn't allow"));
    await settle();
    expect(names(here), isEmpty);
    expect(bloc.state, isA<ClipboardOtherAppFiles>());
    expect(bloc.canPaste, isTrue);

    // Allowed the next time.
    pasteboard.deny = false;
    final done = after(bloc, (s) => s is ClipboardReadyToPaste && s.pasted);
    bloc.add(PasteFromClipboard(here.path));
    await done;
    expect(names(here), ['notes.txt']);
  });

  test('Paste was on but something else was copied since: told, and Paste goes off', () async {
    pasteboard.copyInFinder([p.join(finder.path, 'notes.txt')]);
    final bloc = window(_Unwatched(file));
    await settle();
    expect(bloc.state, isA<ClipboardOtherAppFiles>());
    pasteboard.copyText();
    final failed = after(bloc, (s) => s is ClipboardPasteFailure);
    bloc.add(PasteFromClipboard(here.path));
    expect((await failed as ClipboardPasteFailure).error, contains('no longer holds files'));
    await settle();
    expect(names(here), isEmpty);
    expect(bloc.canPaste, isFalse);
  });
}
