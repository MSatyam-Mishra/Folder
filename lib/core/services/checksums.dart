import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

/// The checksums Properties offers.
enum HashKind {
  md5('MD5', 32),
  sha1('SHA-1', 40),
  sha256('SHA-256', 64),
  sha512('SHA-512', 128);

  const HashKind(this.label, this.hexLength);

  final String label;

  /// How many hex digits it has.
  final int hexLength;

  crypto.Hash get _algorithm => switch (this) {
        HashKind.md5 => crypto.md5,
        HashKind.sha1 => crypto.sha1,
        HashKind.sha256 => crypto.sha256,
        HashKind.sha512 => crypto.sha512,
      };

  static HashKind? ofLength(int length) {
    for (final kind in values) {
      if (kind.hexLength == length) return kind;
    }
    return null;
  }
}

/// A checksum found in text, and the file it's for when the text said.
typedef FoundChecksum = ({String hex, HashKind kind, String? name});

/// A sums file beside a file that lists it.
typedef SumsEntry = ({String sumsPath, String hex, HashKind kind});

/// Stopped by [ChecksumJob.cancel].
class ChecksumCancelled implements Exception {
  const ChecksumCancelled();
}

/// Works out a file's MD5, SHA-1, SHA-256 and SHA-512 in one read, in an
/// isolate of its own, telling how far it is.
class ChecksumJob {
  ChecksumJob(this.path, {this.onProgress}) {
    _run();
  }

  final String path;

  /// From 0 to 1, about a hundred times over a big file.
  final void Function(double fraction)? onProgress;

  final _done = Completer<Map<HashKind, String>>();
  ReceivePort? _port;

  /// Where to ask the isolate to stop: it then closes the file itself (a
  /// killed isolate could leave it open, and Windows locked).
  SendPort? _control;
  bool _cancelled = false;

  Future<Map<HashKind, String>> get result => _done.future;

  Future<void> _run() async {
    final port = ReceivePort();
    _port = port;
    port.listen((message) {
      if (message is SendPort) {
        _control = message;
        if (_cancelled) message.send(true);
        return;
      }
      if (message == null) {
        // The isolate ended.
        _complete(() => _done.completeError(FileSystemException('Stopped', path)));
        port.close();
        return;
      }
      if (_done.isCompleted) return;
      if (message is double) {
        onProgress?.call(message);
      } else if (message is Map) {
        _complete(() => _done.complete({
              for (final kind in HashKind.values)
                if (message[kind.name] case final String hex) kind: hex,
            }));
      } else if (message is String) {
        _complete(() => _done.completeError(FileSystemException(message, path)));
      } else if (message is List) {
        // An uncaught error: [message, stack].
        _complete(() => _done.completeError(FileSystemException('${message.first}', path)));
      }
    });
    try {
      await Isolate.spawn(
        _hashFile,
        (port.sendPort, path),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'checksums',
      );
    } catch (e) {
      _complete(() => _done.completeError(e));
      port.close();
    }
  }

  void _complete(void Function() complete) {
    if (!_done.isCompleted) complete();
  }

  /// Stops it; [result] fails with [ChecksumCancelled].
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _control?.send(true);
    _complete(() => _done.completeError(const ChecksumCancelled()));
  }

  static Future<void> _hashFile((SendPort, String) args) async {
    final (port, path) = args;
    final control = ReceivePort();
    var stop = false;
    control.listen((_) => stop = true);
    port.send(control.sendPort);
    RandomAccessFile? file;
    try {
      file = await File(path).open();
      final length = await file.length();
      final catchers = {for (final kind in HashKind.values) kind: _DigestCatcher()};
      final inputs = {for (final kind in HashKind.values) kind: kind._algorithm.startChunkedConversion(catchers[kind]!)};
      final buffer = Uint8List(1 << 20);
      var read = 0;
      var reported = 0;
      while (!stop) {
        // Awaited, so a request to stop gets through between chunks.
        final n = await file.readInto(buffer);
        if (n <= 0) break;
        // The hashes copy what they're given, so the buffer is reused.
        final chunk = Uint8List.sublistView(buffer, 0, n);
        for (final input in inputs.values) {
          input.add(chunk);
        }
        read += n;
        if (length > 0 && read - reported >= length ~/ 100) {
          reported = read;
          port.send(read / length);
        }
      }
      if (stop) return;
      for (final input in inputs.values) {
        input.close();
      }
      port.send({for (final e in catchers.entries) e.key.name: e.value.value.toString()});
    } on FileSystemException catch (e) {
      port.send(e.osError?.message ?? e.message);
    } catch (e) {
      port.send('$e');
    } finally {
      await file?.close();
      control.close();
    }
  }
}

class _DigestCatcher implements Sink<crypto.Digest> {
  late crypto.Digest value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}

abstract final class Checksums {
  /// The four checksums of [bytes], at once (small things and tests).
  static Map<HashKind, String> ofBytes(List<int> bytes) =>
      {for (final kind in HashKind.values) kind: kind._algorithm.convert(bytes).toString()};

  static final _bsd = RegExp(r'^(MD5|SHA-?1|SHA-?256|SHA-?512)\s*\((.+)\)\s*=\s*([0-9a-fA-F]+)$', caseSensitive: false);
  static final _gnu = RegExp(r'^\\?([0-9a-fA-F]{32,128})\s+[ *]?(.+)$');
  static final _anywhere = RegExp(r'(?<![0-9a-fA-F])([0-9a-fA-F]{128}|[0-9a-fA-F]{64}|[0-9a-fA-F]{40}|[0-9a-fA-F]{32})(?![0-9a-fA-F])');

  /// The checksum in [text]: a bare one (spaces and colons between pairs
  /// are fine), a line of a sums file (`hash  name`, `hash *name`,
  /// `SHA256 (name) = hash`), or any text with one in it (PowerShell's
  /// Get-FileHash). Null if there's none.
  static FoundChecksum? parse(String text) {
    final line = text.trim();
    if (line.isEmpty) return null;
    final bsd = _bsd.firstMatch(line);
    if (bsd != null) return _found(bsd[3]!, bsd[2]);
    final gnu = _gnu.firstMatch(line);
    if (gnu != null) {
      final found = _found(gnu[1]!, gnu[2]!.trim());
      if (found != null) return found;
    }
    final bare = line.replaceAll(RegExp(r'[\s:]'), '');
    if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(bare)) return _found(bare, null);
    final any = _anywhere.firstMatch(line);
    return any == null ? null : _found(any[1]!, null);
  }

  static FoundChecksum? _found(String hex, String? name) {
    final kind = HashKind.ofLength(hex.length);
    if (kind == null) return null;
    return (hex: hex.toLowerCase(), kind: kind, name: name);
  }

  /// Names of sums files that list many files.
  static final _sumsName = RegExp(
    r'^((sha(1|224|256|384|512)|md5|b2)sums?|checksums?|hashes)(\.txt|\.asc)?$|\.(sha256|sha256sum|sha512|sha512sum|sha1|md5|sums)$',
    caseSensitive: false,
  );

  /// A sums file in [file]'s folder that lists it (Folders' own releases ship
  /// `SHA256SUMS.txt`), or `<file>.sha256` and the like with just its hash.
  static Future<SumsEntry?> findSums(String file) async {
    final folder = p.dirname(file);
    final name = p.basename(file);
    List<FileSystemEntity> entries;
    try {
      entries = await Directory(folder).list(followLinks: false).toList();
    } catch (_) {
      return null;
    }
    final own = <File>[];
    final shared = <File>[];
    for (final entry in entries) {
      if (entry is! File || p.equals(entry.path, file)) continue;
      final entryName = p.basename(entry.path);
      if (p.basenameWithoutExtension(entryName) == name && _sumsName.hasMatch(entryName)) {
        own.add(entry);
      } else if (_sumsName.hasMatch(entryName)) {
        shared.add(entry);
      }
    }
    for (final sums in [...own, ...shared]) {
      final found = await _lookUp(sums, name, alone: own.contains(sums));
      if (found != null) return found;
    }
    return null;
  }

  static Future<SumsEntry?> _lookUp(File sums, String name, {required bool alone}) async {
    try {
      if (await sums.length() > 1 << 20) return null;
      final lines = const LineSplitter().convert(await sums.readAsString());
      for (final line in lines) {
        final found = parse(line);
        if (found == null) continue;
        final listed = found.name;
        if (listed == null ? alone : _sameName(listed, name)) {
          return (sumsPath: sums.path, hex: found.hex, kind: found.kind);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Whether a name in a sums file (`./dist/app.apk`, `*app.apk`) is [name].
  static bool _sameName(String listed, String name) {
    var n = listed.trim();
    if (n.startsWith('*')) n = n.substring(1);
    n = n.replaceAll('\\', '/');
    return n.split('/').last == name;
  }
}
