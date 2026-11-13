import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'package:filesize/filesize.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/compress/archive_sink.dart';
import 'package:folders/core/services/compress/sevenz_writer.dart';
import 'package:folders/core/services/compress/stream_codecs.dart';
import 'package:folders/core/services/compress/tar_writer.dart';
import 'package:folders/core/services/compress/zip_writer.dart';
import 'package:path/path.dart' as p;

/// The kinds of archive the app makes.
enum ArchiveKind {
  zip('ZIP', 'zip'),
  sevenZip('7z', '7z'),
  tar('TAR', 'tar'),
  tarGz('TAR.GZ', 'tar.gz'),
  tarXz('TAR.XZ', 'tar.xz'),
  tarBz2('TAR.BZ2', 'tar.bz2');

  const ArchiveKind(this.label, this.extension);

  final String label;
  final String extension;

  /// ZIP and 7z can have a password; tar can't.
  bool get canEncrypt => this == zip || this == sevenZip;

  /// The levels that make a difference: none for a plain tar, and one for
  /// bzip2, whose encoder has no other.
  List<CompressLevel> get levels => switch (this) {
        zip || sevenZip => CompressLevel.values,
        tarGz || tarXz => const [CompressLevel.fast, CompressLevel.normal, CompressLevel.best],
        tar || tarBz2 => const [],
      };

  /// [name] with this kind's extension in place of any archive extension.
  String nameFor(String name) {
    var base = name.trim();
    for (final kind in [...ArchiveKind.values]..sort((a, b) => b.extension.length.compareTo(a.extension.length))) {
      final ext = '.${kind.extension}';
      if (base.toLowerCase().endsWith(ext)) {
        base = base.substring(0, base.length - ext.length);
        break;
      }
    }
    return '$base.$extension';
  }
}

enum CompressLevel {
  store('Store'),
  fast('Fast'),
  normal('Normal'),
  best('Best');

  const CompressLevel(this.label);

  final String label;
}

/// How to compress: the kind, the level, a password, and parts.
class CompressOptions {
  const CompressOptions({
    this.kind = ArchiveKind.zip,
    this.level = CompressLevel.normal,
    this.password,
    this.encryptNames = false,
    this.volumeSize,
  });

  final ArchiveKind kind;
  final CompressLevel level;

  /// Null or empty for none; ignored where [ArchiveKind.canEncrypt] is false.
  final String? password;
  final bool encryptNames;

  /// Bytes per part, or null for one file.
  final int? volumeSize;

  String? get effectivePassword => kind.canEncrypt && (password?.isNotEmpty ?? false) ? password : null;
}

/// How far a job has come.
class CompressProgress {
  const CompressProgress(this.done, this.total, this.name);

  final int done;
  final int total;

  /// The file being read.
  final String name;
}

/// What a job made.
class CompressResult {
  const CompressResult(this.parts, this.skipped);

  /// The archive, or its parts in order.
  final List<String> parts;

  /// Files that couldn't be read, left out.
  final List<String> skipped;
}

/// Makes an archive of [sources] at [destination] in a background isolate:
/// it tells how far it has come, and [cancel] stops it and removes what it
/// wrote. Cancel is a flag the isolate reads between chunks, not a kill, so
/// it closes the files it had open: Windows keeps a file locked as long as
/// a handle to it is open, even in an isolate that was killed.
class CompressJob {
  CompressJob(this.sources, this.destination, this.options, {this.onProgress});

  final List<String> sources;

  /// The archive's path; parts add `.001`, `.002`… to it.
  final String destination;
  final CompressOptions options;
  final void Function(CompressProgress progress)? onProgress;

  Isolate? _isolate;
  var _cancelled = false;
  final _done = Completer<CompressResult?>();

  /// Set to 1 to stop; the isolate reads it. Freed once the isolate is gone.
  final Pointer<Uint8> _stop = calloc<Uint8>();
  var _exited = false;
  var _killed = false;
  Timer? _fallback;

  bool get cancelled => _cancelled;

  /// What it made; null if cancelled. Throws if it failed.
  Future<CompressResult?> start() async {
    final port = ReceivePort();
    Object? failure;
    port.listen((message) {
      if (message is CompressProgress) {
        if (!_cancelled) onProgress?.call(message);
      } else if (message is CompressResult) {
        if (!_done.isCompleted) _done.complete(message);
      } else if (message is String) {
        failure = message;
      } else if (message is List) {
        failure ??= message.firstOrNull;
      } else if (message == null) {
        _exited = true;
        _fallback?.cancel();
        if (!_killed) calloc.free(_stop);
        if (!_done.isCompleted) {
          _cancelled
              ? _done.complete(null)
              : _done.completeError(CompressFailure('${failure ?? "It stopped unexpectedly"}'));
        }
        port.close();
      }
    });
    final send = port.sendPort;
    try {
      _isolate = await Isolate.spawn(
        _run,
        (send, sources, destination, options, _stop.address),
        onExit: send,
        onError: send,
      );
    } on Object catch (error) {
      port.close();
      _exited = true;
      calloc.free(_stop);
      if (!_done.isCompleted) _done.completeError(error);
    }
    return _done.future;
  }

  /// Stops within a chunk or two; the isolate closes its files and removes
  /// what it wrote. [start] gives null.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_exited) _stop.value = 1;
    if (!_done.isCompleted) _done.complete(null);
    // Should it not get to its next check (a hung drive), it's ended.
    _fallback = Timer(const Duration(seconds: 15), () {
      if (_exited) return;
      _killed = true;
      _isolate?.kill(priority: Isolate.immediate);
      Timer(const Duration(seconds: 1), () => removeParts(destination));
    });
  }

  /// Removes [destination] and its parts.
  static void removeParts(String destination) {
    for (final path in [destination, for (var n = 1; n < 10000; n++) ArchiveSink.partName(destination, n)]) {
      final file = File(path);
      if (!file.existsSync()) {
        if (path != destination) break;
        continue;
      }
      try {
        file.deleteSync();
      } on FileSystemException {
        // Still held for a moment; nothing more to do.
      }
    }
  }

  static void _run((SendPort, List<String>, String, CompressOptions, int) job) {
    final (send, sources, destination, options, stopAt) = job;
    final stop = Pointer<Uint8>.fromAddress(stopAt);
    try {
      Isolate.exit(send, compress(sources, destination, options, onProgress: send.send, stop: () => stop.value != 0));
    } on CompressCancelled {
      // What it wrote is removed; the job knows it was cancelled.
    } on CompressFailure catch (error) {
      send.send(error.message);
    }
  }

  /// Everything in [sources], however deep, as an archive's items: each
  /// source under its own name. Links and junctions are left out, never
  /// followed.
  static List<ArchiveItem> collect(List<String> sources) {
    final items = <ArchiveItem>[];
    void walk(String path, String name) {
      final stat = FileStat.statSync(path);
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      switch (type) {
        case FileSystemEntityType.file:
          items.add(ArchiveItem.file(name, path, stat.size, stat.modified));
        case FileSystemEntityType.directory:
          items.add(ArchiveItem.folder(name, stat.modified));
          final List<FileSystemEntity> children;
          try {
            children = Directory(path).listSync(followLinks: false)..sort((a, b) => a.path.compareTo(b.path));
          } on FileSystemException {
            return;
          }
          for (final child in children) {
            if (child is Link) continue;
            walk(child.path, '$name/${p.basename(child.path)}');
          }
        default:
          // A link, or gone.
          break;
      }
    }

    for (final source in sources) {
      walk(source, p.basename(source));
    }
    return items;
  }

  /// Writes the archive on this isolate; the job's isolate calls it.
  static CompressResult compress(
    List<String> sources,
    String destination,
    CompressOptions options, {
    void Function(CompressProgress progress)? onProgress,
    ShouldStop? stop,
  }) {
    final items = collect(sources);
    final total = items.fold<int>(0, (sum, item) => sum + item.size);
    var done = 0;
    var name = '';
    final clock = Stopwatch()..start();
    var told = -1000;
    void tell({bool now = false}) {
      if (onProgress == null) return;
      final at = clock.elapsedMilliseconds;
      if (!now && at - told < 100) return;
      told = at;
      onProgress(CompressProgress(done, total, name));
    }

    void onRead(int bytes) {
      done += bytes;
      tell();
    }

    final skipped = <String>[];
    final sink = ArchiveSink(destination, volumeSize: options.volumeSize);
    final password = options.effectivePassword;
    try {
      switch (options.kind) {
        case ArchiveKind.zip:
          final zip = ZipWriter(sink, level: _zipLevel(options.level), password: password);
          for (final item in items) {
            name = item.name;
            if (item.isFolder) {
              zip.addFolder(item.name, item.modified);
              continue;
            }
            try {
              zip.addFile(item.name, item.path!, item.size, item.modified, onRead: onRead, stop: stop);
            } on FileSystemException catch (error) {
              if (!_beforeWriting(error)) rethrow;
              skipped.add(item.path!);
            }
          }
          zip.close();
        case ArchiveKind.sevenZip:
          final (method, block) = _sevenZip(options.level);
          SevenZWriter(
            sink,
            method: method,
            blockSize: block,
            deflateLevel: 6,
            password: password,
            encryptNames: password != null && options.encryptNames,
          )
            ..write(items, onRead: onRead, stop: stop, onSkip: (item, _) => skipped.add(item.path!))
            ..close();
        case ArchiveKind.tar || ArchiveKind.tarGz || ArchiveKind.tarXz || ArchiveKind.tarBz2:
          final ByteEncoder encoder = switch (options.kind) {
            ArchiveKind.tarGz => ZlibEncoder(sink.add, level: _zipLevel(options.level).clamp(1, 9), gzip: true),
            ArchiveKind.tarXz => XzEncoder(sink.add, blockSize: _xzBlock(options.level)),
            ArchiveKind.tarBz2 => Bzip2Encoder(sink.add),
            _ => PlainEncoder(sink.add),
          };
          final tar = TarWriter(encoder);
          for (final item in items) {
            name = item.name;
            if (item.isFolder) {
              tar.addFolder(item.name, item.modified);
              continue;
            }
            try {
              tar.addFile(item.name, item.path!, item.size, item.modified, onRead: onRead, stop: stop);
            } on FileSystemException catch (error) {
              if (!_beforeWriting(error)) rethrow;
              skipped.add(item.path!);
            }
          }
          tar.close();
      }
      final parts = sink.close();
      done = total;
      tell(now: true);
      return CompressResult(parts, skipped);
    } on CompressCancelled {
      sink.discard();
      rethrow;
    } on Object catch (error) {
      sink.discard();
      throw CompressFailure(_reason(error));
    }
  }

  /// Whether [error] came from opening a file, before any of it was written.
  static bool _beforeWriting(FileSystemException error) => error.message.contains('Cannot open file');

  static String _reason(Object error) {
    if (error is FileSystemException) {
      final os = error.osError?.message.trim();
      final what = os == null || os.isEmpty ? error.message : os;
      return error.path == null ? what : '$what (${p.basename(error.path!)})';
    }
    return '$error';
  }

  static int _zipLevel(CompressLevel level) => switch (level) {
        CompressLevel.store => 0,
        CompressLevel.fast => 1,
        CompressLevel.normal => 6,
        CompressLevel.best => 9,
      };

  /// 7z: Store copies; Fast is Deflate, several times quicker than LZMA2 in
  /// Dart; Normal and Best are LZMA2 with 4 and 16 MB blocks (8 on phones,
  /// where memory is shorter).
  static (SevenZMethod, int) _sevenZip(CompressLevel level) => switch (level) {
        CompressLevel.store => (SevenZMethod.copy, 0),
        CompressLevel.fast => (SevenZMethod.deflate, 0),
        CompressLevel.normal => (SevenZMethod.lzma2, 4 << 20),
        CompressLevel.best => (SevenZMethod.lzma2, Platform.isAndroid || Platform.isIOS ? 8 << 20 : 16 << 20),
      };

  /// xz's blocks: bigger ones find more to share, at about the same speed.
  static int _xzBlock(CompressLevel level) => switch (level) {
        CompressLevel.store || CompressLevel.fast => 1 << 20,
        CompressLevel.normal => 4 << 20,
        CompressLevel.best => Platform.isAndroid || Platform.isIOS ? 8 << 20 : 16 << 20,
      };

  /// A name for an archive called [name] in [folder] that's free, parts
  /// and all.
  static String freePath(String folder, String name, {bool split = false}) {
    bool taken(String path) =>
        FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound ||
        (split && File(ArchiveSink.partName(path, 1)).existsSync());
    var path = p.join(folder, name);
    if (!taken(path)) return path;
    final kind = ArchiveKind.values.where((k) => name.toLowerCase().endsWith('.${k.extension}')).toList()
      ..sort((a, b) => b.extension.length.compareTo(a.extension.length));
    final ext = kind.isEmpty ? p.extension(name) : '.${kind.first.extension}';
    final base = name.substring(0, name.length - ext.length);
    for (var i = 2;; i++) {
      path = p.join(folder, '$base ($i)$ext');
      if (!taken(path)) return path;
    }
  }
}

class CompressFailure implements Exception {
  const CompressFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A compression going on as a background task: it shows in the progress
/// dock and the Tasks view, and can be cancelled from there.
abstract final class CompressTask {
  /// Starts compressing [sources] into [destination]; [onDone] hears what
  /// was made (null when cancelled or failed).
  static BackgroundTask start(
    List<String> sources,
    String destination,
    CompressOptions options, {
    void Function(CompressResult? result)? onDone,
  }) {
    late final CompressJob job;
    final task = BackgroundTasks.instance.start(
      'Compress to ${p.basename(destination)}',
      message: 'Getting ready…',
      headline: 'Compressing',
      onCancel: () => job.cancel(),
    );
    job = CompressJob(sources, destination, options, onProgress: (progress) {
      task.update(
        message: progress.name.isEmpty ? 'Finishing…' : p.basename(progress.name),
        progress: progress.total == 0 ? null : progress.done / progress.total,
        detail: '${filesize(progress.done, 1)}/${filesize(progress.total, 1)}',
      );
    });
    () async {
      try {
        final result = await job.start();
        if (result == null) {
          BackgroundTasks.instance.cancelled(task);
          onDone?.call(null);
          return;
        }
        task.outputs.addAll(result.parts);
        final made = result.parts.length == 1 ? p.basename(result.parts.single) : '${result.parts.length} parts';
        BackgroundTasks.instance.finish(
          task,
          message: result.skipped.isEmpty ? 'Made $made' : "Made $made. ${result.skipped.length} couldn't be read.",
        );
        onDone?.call(result);
      } on Object catch (error) {
        BackgroundTasks.instance.fail(task, "Couldn't compress: $error");
        onDone?.call(null);
      }
    }();
    return task;
  }
}
