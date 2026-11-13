import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/services/local_content_server.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_transfer.dart';
import 'package:folders/features/video_player/video_player_page.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opening files that are on network places: a video streams to the player
/// (it seeks through HTTP ranges); anything else is downloaded to a cache
/// folder first, with its progress and Cancel, then opened as usual. If the
/// viewer or editor changed it, or saved a copy beside it, the user is
/// offered to upload that back.
abstract final class RemoteOpener {
  /// Where downloads go; tests replace it.
  @visibleForTesting
  static Future<Directory> Function() cacheRoot = () async =>
      Directory(p.join((await getTemporaryDirectory()).path, 'remote_files'));

  /// Whether videos are streamed (not where Folders has no player).
  static bool get _streams => !(Platform.isMacOS && !Desktop.macMediaKit);

  /// Opens [file] as a tap does, or with the viewer for [as], or with the
  /// "Open with" chooser when [chooser]. Returns true when something was
  /// uploaded, so the folder is listed again.
  static Future<bool?> open(
    BuildContext context,
    RemoteFile file, {
    FileKind? as,
    bool chooser = false,
    bool allowExternal = true,
  }) async {
    final kind = as ?? FileTypes.kindOf(file.path);
    if (!chooser && kind == FileKind.video && _streams) {
      await stream(context, file);
      return null;
    }
    return openThrough(context, file, (local) {
      if (chooser) return FileOpener.showOpenWith(context, local, allowExternal: allowExternal);
      if (as != null) return FileOpener.openAs(context, local, as, allowExternal: allowExternal);
      return FileOpener.open(context, local, allowExternal: allowExternal);
    });
  }

  /// Downloads [file], opens the copy with [viewer], then offers to upload
  /// what changed in its cache folder.
  @visibleForTesting
  static Future<bool?> openThrough(BuildContext context, RemoteFile file, Future<bool?> Function(File local) viewer) async {
    final local = await download(context, file);
    if (local == null || !context.mounted) return null;
    final folder = local.parent;
    final before = await _snapshot(folder);
    if (!context.mounted) return null;
    final result = await viewer(local);
    final changed = await _changes(folder, before);
    if (changed.isEmpty || !context.mounted) return result;
    if (!await _askUpload(context, file, changed, local.path) || !context.mounted) return result;
    final uploaded = await _upload(context, file, changed, local.path);
    return uploaded || (result ?? false);
  }

  /// Plays [file] in the video player, streamed through
  /// [LocalContentServer] with ranges read from the place.
  static Future<void> stream(BuildContext context, RemoteFile file) async {
    final base = await mount(file);
    try {
      if (!context.mounted) return;
      await VideoPlayerPage.open(context, [streamUrl(base, file).toString()]);
    } finally {
      LocalContentServer.instance.unmount(base);
    }
  }

  /// Mounts [file] on [LocalContentServer]; unmount when done.
  static Future<Uri> mount(RemoteFile file) {
    final name = file.entry.name;
    return LocalContentServer.instance.mountRanged((path) async {
      if (path != name) return null;
      var size = file.entry.size;
      if (size <= 0) {
        size = (await RemotePool.instance.run(file.connectionId, (fs) => fs.stat(file.remotePath))).size;
      }
      return RangedContent(
        size,
        (start, end) => RemotePool.instance.openRead(file.connectionId, file.remotePath, start: start, end: end),
      );
    });
  }

  /// The address of [file] under a [mount]'s [base]: its own name last, so
  /// the player shows it and knows its type.
  static Uri streamUrl(Uri base, RemoteFile file) => base.resolve(Uri.encodeComponent(file.entry.name));

  /// The cache folder of [file]: one per file, so a copy an editor saves
  /// beside it can be told apart.
  static Future<Directory> folderFor(RemoteFile file) async {
    final hash = sha1.convert(utf8.encode('${file.connectionId}:${file.remotePath}')).toString().substring(0, 16);
    return Directory(p.join((await cacheRoot()).path, file.connectionId, hash));
  }

  /// [file] in the cache, downloaded unless the copy there is the same size
  /// and date. Null if cancelled or failed (and then the user was told).
  static Future<File?> download(BuildContext context, RemoteFile file) async {
    final folder = await folderFor(file);
    final local = File(p.join(folder.path, file.entry.name));
    final modified = file.entry.modified;
    if (await local.exists()) {
      final stat = await local.stat();
      if (stat.size == file.entry.size && modified != null && stat.modified.difference(modified).inSeconds.abs() < 2) {
        return local;
      }
    }
    await folder.create(recursive: true);
    if (!context.mounted) return null;
    final partial = File('${local.path}.part');
    final done = await _withProgress(
      context,
      title: 'Downloading "${file.entry.name}"',
      total: file.entry.size,
      run: (progress, cancel) async {
        final sink = partial.openWrite();
        var got = 0;
        final finished = Completer<void>();
        // Cancel stops at once, even with the server gone quiet.
        late final StreamSubscription<List<int>> reading;
        reading = RemotePool.instance.openRead(file.connectionId, file.remotePath).listen(
          (chunk) {
            sink.add(chunk);
            got += chunk.length;
            progress(got);
          },
          onError: (Object e) {
            if (!finished.isCompleted) finished.completeError(e);
            reading.cancel();
          },
          onDone: () {
            if (!finished.isCompleted) finished.complete();
          },
          cancelOnError: true,
        );
        cancel.whenCancelled(() {
          reading.cancel();
          if (!finished.isCompleted) finished.completeError(const RemoteException(RemoteErrorKind.cancelled, 'Cancelled'));
        });
        try {
          await finished.future;
        } finally {
          await sink.close();
        }
        if (await local.exists()) await local.delete();
        await partial.rename(local.path);
        if (modified != null) {
          try {
            await local.setLastModified(modified);
          } on FileSystemException {
            // The copy is still good.
          }
        }
      },
    );
    if (!done) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      return null;
    }
    return local;
  }

  /// Copies of [entities] on this device (files and folders), downloaded
  /// into a new temporary folder; null if cancelled or failed. For sharing
  /// them with other apps.
  static Future<List<FileSystemEntity>?> fetch(BuildContext context, List<FileSystemEntity> entities) async {
    final remote = [for (final e in entities) if (e is RemoteEntity) e.path];
    if (remote.isEmpty) return entities;
    final root = await cacheRoot();
    await root.create(recursive: true);
    final folder = await root.createTemp('share');
    if (!context.mounted) return null;
    List<String> targets = const [];
    final done = await _withProgress(
      context,
      title: remote.length == 1 ? 'Downloading "${_nameOf(remote.single)}"' : 'Downloading ${remote.length} items',
      total: 0,
      run: (progress, cancel) async {
        targets = await transferEntities(remote, folder.path, move: false, cancel: cancel, onProgress: (p) => progress(p.done, p.total));
      },
    );
    if (!done) return null;
    final local = [
      for (final path in targets) FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path),
    ];
    return [...entities.where((e) => e is! RemoteEntity), ...local];
  }

  static String _nameOf(String browserPath) => RemotePaths.nameOf(RemotePaths.parse(browserPath)?.$2 ?? '/');

  /// Runs [run] with a dialog showing its progress and Cancel, shown only
  /// if it takes more than a moment. False if it was cancelled or failed.
  static Future<bool> _withProgress(
    BuildContext context, {
    required String title,
    required int total,
    required Future<void> Function(void Function(int done, [int? total]) progress, RemoteCancel cancel) run,
    String failure = "Couldn't download",
  }) async {
    final cancel = RemoteCancel();
    final state = ValueNotifier<(int, int)>((0, total));
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var dialogOpen = false;
    var finished = false;
    final work = run((done, [newTotal]) => state.value = (done, newTotal ?? state.value.$2), cancel);
    final shown = Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (finished || !navigator.mounted) return;
      dialogOpen = true;
      showDialog<void>(
        context: navigator.context,
        barrierDismissible: false,
        builder: (dialog) => _ProgressDialog(title: title, state: state, onCancel: cancel.cancel),
      ).whenComplete(() => dialogOpen = false);
    });
    Object? error;
    try {
      await work;
    } catch (e) {
      error = e;
    } finally {
      finished = true;
      await shown;
      if (dialogOpen && navigator.mounted) navigator.pop();
      state.dispose();
    }
    if (error == null) return true;
    if (!cancel.isCancelled) {
      messenger?.showSnackBar(SnackBar(content: Text('$failure: ${remoteError(error).message}')));
    }
    return false;
  }

  /// Name, size and date of each file in [folder].
  static Future<Map<String, (int, DateTime)>> _snapshot(Directory folder) async {
    final out = <String, (int, DateTime)>{};
    try {
      await for (final entity in folder.list()) {
        if (entity is! File || entity.path.endsWith('.part')) continue;
        final stat = await entity.stat();
        out[entity.path] = (stat.size, stat.modified);
      }
    } on FileSystemException {
      // Gone: nothing changed that could be uploaded.
    }
    return out;
  }

  /// The files in [folder] that are new or changed since [before].
  static Future<List<String>> _changes(Directory folder, Map<String, (int, DateTime)> before) async {
    final now = await _snapshot(folder);
    return [
      for (final MapEntry(key: path, value: info) in now.entries)
        if (before[path] != info) path,
    ];
  }

  static Future<bool> _askUpload(BuildContext context, RemoteFile file, List<String> changed, String original) async {
    final place = RemotePlaces.instance.byId(file.connectionId)?.name ?? 'the network place';
    final names = changed.map(p.basename).toList();
    final text = changed.length == 1
        ? changed.single == original
            ? '"${names.single}" was changed here. Save the changes back to $place?'
            : '"${names.single}" was saved beside it. Upload it to $place?'
        : '${names.join(', ')} were changed or saved here. Upload them to $place?';
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Upload the changes?'),
        content: Text(text),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Keep here only')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Upload')),
        ],
      ),
    );
    return answer ?? false;
  }

  static Future<bool> _upload(BuildContext context, RemoteFile file, List<String> changed, String original) async {
    var total = 0;
    for (final path in changed) {
      total += await File(path).length();
    }
    if (!context.mounted) return false;
    final folder = RemotePaths.build(file.connectionId, RemotePaths.parentOf(file.remotePath));
    final ok = await _withProgress(
      context,
      title: changed.length == 1 ? 'Uploading "${p.basename(changed.single)}"' : 'Uploading ${changed.length} files',
      total: total,
      failure: "Couldn't upload",
      run: (progress, cancel) async {
        var sent = 0;
        for (final path in changed) {
          cancel.check();
          if (path == original) {
            final length = await File(path).length();
            final start = sent;
            await RemotePool.instance.run(
              file.connectionId,
              (fs) => fs.write(
                file.remotePath,
                File(path).openRead().map((chunk) {
                  cancel.check();
                  return chunk;
                }),
                length: length,
                overwrite: true,
                onProgress: (n) => progress(start + n),
              ),
              retry: false,
            );
            sent += length;
          } else {
            // A copy saved beside it: added to the folder under a free name.
            await transferEntities([path], folder, move: false, cancel: cancel);
            sent += await File(path).length();
            progress(sent);
          }
        }
      },
    );
    if (ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Uploaded')));
    }
    if (ok) {
      // The server dates the upload anew: the copy here no longer matches
      // it, and is downloaded again next time.
      try {
        await File(original).setLastModified(DateTime.fromMillisecondsSinceEpoch(0));
      } catch (_) {}
    }
    return ok;
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({required this.title, required this.state, required this.onCancel});

  final String title;
  final ValueListenable<(int, int)> state;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 360,
        child: ValueListenableBuilder<(int, int)>(
          valueListenable: state,
          builder: (context, value, _) {
            final (done, total) = value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: total > 0 ? (done / total).clamp(0.0, 1.0) : null),
                const SizedBox(height: 10),
                Text(total > 0 ? '${filesize(done, 1)} of ${filesize(total, 1)}' : filesize(done, 1), style: text.bodySmall),
              ],
            );
          },
        ),
      ),
      actions: [
        OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
      ],
    );
  }
}
