import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// How much is in a folder so far: [bytes] in [files] files and [folders]
/// folders; [done] once everything was counted.
class FolderSize {
  const FolderSize({this.bytes = 0, this.files = 0, this.folders = 0, this.done = false});

  final int bytes;
  final int files;
  final int folders;
  final bool done;

  /// Adds up [paths] (folders and files) in an isolate of its own, telling
  /// how far it got now and then. Cancelling the subscription stops it.
  /// Links and junctions aren't followed; what can't be read is skipped.
  static Stream<FolderSize> measure(List<String> paths) {
    late StreamController<FolderSize> controller;
    Isolate? isolate;
    ReceivePort? port;
    void stop() {
      isolate?.kill(priority: Isolate.immediate);
      isolate = null;
      port?.close();
      port = null;
    }

    controller = StreamController<FolderSize>(
      onListen: () async {
        final receive = port = ReceivePort();
        receive.listen((message) {
          if (message is List && message.length == 4) {
            final size = FolderSize(
              bytes: message[0] as int,
              files: message[1] as int,
              folders: message[2] as int,
              done: message[3] as bool,
            );
            controller.add(size);
            if (size.done) {
              stop();
              controller.close();
            }
          }
        });
        try {
          isolate = await Isolate.spawn(_count, (receive.sendPort, paths));
          // Cancelled while it started.
          if (port == null) stop();
        } catch (e) {
          controller.addError(e);
          stop();
          await controller.close();
        }
      },
      onCancel: stop,
    );
    return controller.stream;
  }

  static Future<void> _count((SendPort, List<String>) args) async {
    final (send, paths) = args;
    var bytes = 0, files = 0, folders = 0;
    var told = DateTime.now();
    void tell({bool done = false}) => send.send([bytes, files, folders, done]);
    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        files++;
        try {
          bytes += File(path).lengthSync();
        } on FileSystemException {
          // Not readable: left out.
        }
        continue;
      }
      if (type != FileSystemEntityType.directory) continue;
      final stack = [Directory(path)];
      while (stack.isNotEmpty) {
        final dir = stack.removeLast();
        try {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is File) {
              files++;
              try {
                bytes += (await entity.stat()).size;
              } on FileSystemException {
                // Gone or locked.
              }
            } else if (entity is Directory) {
              folders++;
              stack.add(entity);
            }
            final now = DateTime.now();
            if (now.difference(told).inMilliseconds > 200) {
              told = now;
              tell();
            }
          }
        } on FileSystemException {
          // A folder that can't be listed.
        }
      }
    }
    tell(done: true);
  }
}
