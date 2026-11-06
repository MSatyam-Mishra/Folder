import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:bloc/bloc.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/file_clipboard.dart';
import 'package:folders/features/clipboard/paste_task.dart';
import 'package:folders/features/tasks/bloc/task_progress_bloc.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

part 'clipboard_event.dart';
part 'clipboard_state.dart';

/// Copy, cut and paste of files. The clipboard is shared with the other
/// Folders windows, and on Windows and macOS with other apps (File
/// Explorer, Finder), see [FileClipboard].
class ClipboardBloc extends Bloc<ClipboardEvent, ClipboardState> {
  ClipboardBloc({required this.taskProgressBloc, FileClipboard? store})
      : clipboard = store ?? FileClipboard.instance,
        super(ClipboardEmpty()) {
    on<CopyToClipboard>((event, emit) => _put(event.entities, ClipboardOperation.copy, emit));
    on<CutToClipboard>((event, emit) => _put(event.entities, ClipboardOperation.cut, emit));
    on<ClearClipboard>((event, emit) async {
      emit(ClipboardEmpty());
      await _quietly(clipboard.clear);
    });
    on<_ClipboardChanged>(_onChanged);
    on<PasteFromClipboard>(_onPaste);
    on<TransferFiles>(_onTransfer);
    _changes = clipboard.changes.listen((_) => add(_ClipboardChanged()));
    // What another window copied before this one opened.
    add(_ClipboardChanged());
  }

  final TaskProgressBloc taskProgressBloc;
  final FileClipboard clipboard;
  late final StreamSubscription<void> _changes;
  bool _pasting = false;

  /// Whether Paste has something to paste: files copied or cut, or files
  /// another app copied (macOS), read when pasting.
  bool get canPaste => state is ClipboardReadyToPaste || state is ClipboardOtherAppFiles;

  /// macOS: files another app copied are read only when the user pastes,
  /// as the system may ask the user first ([FileClipboard.readToPaste]).
  bool get _readsOnPaste => clipboard is MacFileClipboard;

  Future<void> _put(
    List<FileSystemEntity> entities,
    ClipboardOperation operation,
    Emitter<ClipboardState> emit,
  ) async {
    if (entities.isEmpty) return;
    final ready = ClipboardReadyToPaste(entities: entities, operation: operation);
    emit(ready);
    await _quietly(() => clipboard.write(ClipboardFiles(
          [for (final e in entities) e.path],
          cut: operation == ClipboardOperation.cut,
        )));
    // macOS: the pasteboard holds these now.
    if (_readsOnPaste) _stamped(ready, await _stamp());
  }

  Future<void> _onChanged(_ClipboardChanged event, Emitter<ClipboardState> emit) async {
    if (_pasting) return;
    // Looked at first: anything copied while reading makes it older.
    final stamp = await _stamp();
    ClipboardFiles? files;
    try {
      files = await clipboard.read();
    } catch (_) {
      return;
    }
    final entities = _existing(files);
    final current = state;
    if (entities.isEmpty) {
      // macOS: another app's files, left until the user pastes.
      final elsewhere = files == null && _readsOnPaste && await _holdsFiles();
      // Something copied or pasted meanwhile wins.
      if (!identical(state, current) || _pasting) return;
      if (elsewhere) {
        if (current is! ClipboardOtherAppFiles) emit(ClipboardOtherAppFiles());
      } else if (current is ClipboardReadyToPaste || current is ClipboardOtherAppFiles) {
        emit(ClipboardEmpty());
      }
      return;
    }
    final operation = files!.cut ? ClipboardOperation.cut : ClipboardOperation.copy;
    if (current is ClipboardReadyToPaste &&
        current.operation == operation &&
        listEquals([for (final e in current.entities) e.path], [for (final e in entities) e.path])) {
      // Ours, or unchanged.
      if (identical(state, current)) _stamped(current, stamp);
      return;
    }
    emit(_stamped(ClipboardReadyToPaste(entities: entities, operation: operation), stamp));
  }

  Future<void> _onPaste(PasteFromClipboard event, Emitter<ClipboardState> emit) async {
    if (_pasting) return;
    final before = state;
    if (before is! ClipboardReadyToPaste && !_readsOnPaste) return;
    _pasting = true;
    try {
      // macOS: what's on the pasteboard now, unless nothing was copied
      // since the last look (which is every 0.7 s).
      final current = before is ClipboardReadyToPaste && await _unchanged(before)
          ? before
          : await _readToPaste(before, emit);
      if (current == null) return; // Nothing to paste after all.
      final move = current.operation == ClipboardOperation.cut;
      final sources = [for (final e in current.entities) e.path];
      try {
        final targets = await _transfer(sources, event.destinationPath, move);
        emit(ClipboardPasteSuccess(targets));
        if (move) {
          // Moved: nothing left to paste, in any window.
          emit(ClipboardEmpty());
          await _quietly(clipboard.clear);
        } else {
          emit(_stamped(
            ClipboardReadyToPaste(entities: current.entities, operation: current.operation, pasted: true),
            _readAt[current],
          ));
        }
      } catch (e) {
        emit(ClipboardPasteFailure(
          error: e is FileSystemException ? _describe(e) : '$e',
          previousState: current,
        ));
        emit(current);
      }
    } finally {
      _pasting = false;
    }
  }

  /// macOS: what's on the pasteboard, read now that the user pastes (for
  /// another app's files the system may ask them first). Null when there's
  /// nothing to paste; when Paste looked possible it says why.
  Future<ClipboardReadyToPaste?> _readToPaste(ClipboardState before, Emitter<ClipboardState> emit) async {
    final stamp = await _stamp();
    ClipboardFiles? files;
    try {
      files = await clipboard.readToPaste();
    } catch (_) {
      // Unreadable: told below, if the pasteboard holds files.
    }
    final entities = _existing(files);
    if (entities.isNotEmpty) {
      return _stamped(
        ClipboardReadyToPaste(
          entities: entities,
          // A copy, unless an Folders window cut them.
          operation: files!.cut ? ClipboardOperation.cut : ClipboardOperation.copy,
          // Pasted straight away: no paste bar for them.
          pasted: true,
        ),
        stamp,
      );
    }
    final String why;
    if (files != null) {
      why = files.paths.length == 1 ? 'the copied item is no longer there' : 'the copied items are no longer there';
    } else if (await _holdsFiles()) {
      // The user chose Don't Allow, or settings deny it.
      why = "macOS didn't allow reading the copied files";
    } else {
      // Something other than files was copied since.
      if (before is ClipboardReadyToPaste || before is ClipboardOtherAppFiles) {
        emit(ClipboardPasteFailure(error: 'the clipboard no longer holds files'));
        emit(ClipboardEmpty());
      }
      return null;
    }
    emit(ClipboardPasteFailure(error: why));
    // Still on the pasteboard, for another try.
    emit(ClipboardOtherAppFiles());
    return null;
  }

  /// macOS: the pasteboard's [MacFileClipboard.stamp] when each
  /// [ClipboardReadyToPaste] was read from it.
  final _readAt = Expando<Object>();

  /// macOS: something that changes whenever anything is copied; null
  /// elsewhere or when it can't be told.
  Future<Object?> _stamp() async {
    final clipboard = this.clipboard;
    if (clipboard is! MacFileClipboard) return null;
    try {
      return await clipboard.stamp();
    } catch (_) {
      return null;
    }
  }

  /// [ready], noted as read when the pasteboard's stamp was [stamp].
  ClipboardReadyToPaste _stamped(ClipboardReadyToPaste ready, Object? stamp) {
    if (stamp != null) _readAt[ready] = stamp;
    return ready;
  }

  /// Whether [ready] is still what's on the clipboard: always, except on
  /// macOS when something was copied since it was read.
  Future<bool> _unchanged(ClipboardReadyToPaste ready) async {
    if (!_readsOnPaste) return true;
    final then = _readAt[ready];
    return then != null && then == await _stamp();
  }

  /// macOS: whether the pasteboard holds files, from the kinds of data on
  /// it alone, which the system doesn't ask the user about.
  Future<bool> _holdsFiles() async {
    try {
      return await clipboard.holdsFiles();
    } catch (_) {
      return false;
    }
  }

  /// The files and folders [files] names that are still there.
  static List<FileSystemEntity> _existing(ClipboardFiles? files) => [
        for (final path in files?.paths ?? const <String>[])
          if (FileSystemEntity.isDirectorySync(path))
            Directory(path)
          else if (FileSystemEntity.isFileSync(path))
            File(path),
      ];

  Future<void> _onTransfer(TransferFiles event, Emitter<ClipboardState> emit) async {
    if (event.sources.isEmpty) return;
    final before = state;
    try {
      final targets = await _transfer(event.sources, event.destination, event.move);
      emit(ClipboardPasteSuccess(targets));
    } catch (e) {
      emit(ClipboardPasteFailure(error: e is FileSystemException ? _describe(e) : '$e'));
    }
    // What's on the clipboard stays.
    if (before is ClipboardReadyToPaste || before is ClipboardEmpty) emit(before);
  }

  /// Copies or moves with a progress card; returns where things went.
  Future<List<String>> _transfer(List<String> sources, String destination, bool move) async {
    final verb = move ? 'Moving' : 'Copying';
    final title = sources.length == 1
        ? '$verb "${p.basename(sources.single)}"'
        : '$verb ${sources.length} items';
    taskProgressBloc.add(TaskStarted(title: title, initialMessage: 'Getting ready…'));
    _task = BackgroundTasks.instance.start(
      title,
      message: 'Getting ready…',
      headline: move ? 'Move in progress' : 'Copy in progress',
      kind: TaskKind.copy,
    );
    try {
      final targets = await _pasteInIsolate(sources, destination, move);
      _task!.outputs.addAll(targets);
      BackgroundTasks.instance.finish(_task!, message: 'Done: ${p.basename(destination)}');
      return targets;
    } catch (e) {
      BackgroundTasks.instance.fail(_task!, e is FileSystemException ? _describe(e) : '$e');
      rethrow;
    } finally {
      taskProgressBloc.add(TaskEnded());
      _task = null;
    }
  }

  BackgroundTask? _task;

  Future<List<String>> _pasteInIsolate(List<String> sources, String destination, bool move) async {
    final port = ReceivePort();
    final errors = ReceivePort();
    await Isolate.spawn(_paste, (port.sendPort, sources, destination, move), onError: errors.sendPort);
    final result = Completer<List<String>>();
    errors.listen((message) {
      if (!result.isCompleted) result.completeError(FileSystemException('${(message as List).first}'));
    });
    port.listen((message) {
      switch (message) {
        case PasteProgress(:final done, :final total, :final name):
          taskProgressBloc.add(TaskProgressUpdated(
            progress: total > 0 ? done / total : 1,
            message: name.isEmpty ? 'Finishing…' : name,
          ));
          _task?.update(
            progress: total > 0 ? done / total : 1,
            message: name.isEmpty ? 'Finishing…' : name,
            detail: total > 0 ? '${filesize(done, 1)}/${filesize(total, 1)}' : null,
          );
        case List<String> targets:
          result.complete(targets);
        case (String message, String? path):
          result.completeError(FileSystemException(message, path));
      }
    });
    try {
      return await result.future;
    } finally {
      port.close();
      errors.close();
    }
  }

  static Future<void> _paste((SendPort, List<String>, String, bool) args) async {
    final (port, sources, destination, move) = args;
    try {
      port.send(await pasteEntities(sources, destination, move: move, onProgress: port.send));
    } on FileSystemException catch (e) {
      port.send((e.osError?.message.trim().isNotEmpty ?? false) ? ('${e.message}: ${e.osError!.message.trim()}', e.path) : (e.message, e.path));
    } catch (e) {
      port.send(('$e', null));
    }
  }

  static String _describe(FileSystemException e) =>
      e.path == null ? e.message : '${e.message} (${p.basename(e.path!)})';

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // The clipboard is busy or unavailable: this window still works.
    }
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    return super.close();
  }
}
