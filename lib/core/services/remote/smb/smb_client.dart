import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'smb_bytes.dart';
import 'smb_connection.dart';
import 'smb_constants.dart';
import 'smb_rpc.dart';

/// File operations over one signed-in SMB2/3 session: shares, CREATE, READ,
/// WRITE, QUERY_DIRECTORY, SET_INFO, with pipelined transfers.

class SmbFileInfo {
  const SmbFileInfo({
    required this.name,
    required this.attributes,
    this.size = 0,
    this.modified,
    this.created,
  });

  final String name;
  final int attributes;
  final int size;
  final DateTime? modified;
  final DateTime? created;

  bool get isDirectory => (attributes & FileAttr.directory) != 0;
  bool get isHidden => (attributes & FileAttr.hidden) != 0;
  bool get isReadOnly => (attributes & FileAttr.readonly) != 0;
}

/// An open file or folder.
class SmbHandle {
  SmbHandle(this.tree, this.fileId, this.createAction, this.attributes, this.endOfFile, this.modified);

  final SmbTree tree;
  final Uint8List fileId;
  final int createAction;
  final int attributes;
  final int endOfFile;
  final DateTime? modified;
  bool closed = false;

  bool get isDirectory => (attributes & FileAttr.directory) != 0;
  bool get created => createAction == CreateAction.created;
}

class SmbShareInfo {
  const SmbShareInfo(this.name, this.type, this.remark);

  final String name;

  /// STYPE_*: 0 disk, 1 printer, 3 IPC; 0x80000000 marks special shares.
  final int type;
  final String remark;

  bool get isDisk => (type & 0xffff) == 0;
  bool get isSpecial => (type & 0x80000000) != 0 || name.endsWith(r'$');
}

class SmbClient {
  SmbClient._(this.connection, this.session);

  final SmbConnection connection;
  final SmbSession session;
  final Map<String, Future<SmbTree>> _trees = {};

  /// Requests kept in flight during a read or a write.
  int pipelineDepth = 8;

  /// Bytes per READ/WRITE request, before the server's own limits.
  int preferredIoSize = 1 << 20;

  String get host => connection.host;
  int get dialect => connection.dialect;
  bool get isGuest => session.isGuest || session.isAnonymous;
  bool get encrypted => session.encryptData;
  bool get signed => session.signingRequired;

  /// Connects, negotiates and signs in. With no [user], tries an anonymous
  /// session and then the guest account.
  static Future<SmbClient> connect({
    required String host,
    InternetAddress? address,
    int port = 445,
    String user = '',
    String password = '',
    String domain = '',
    String workstation = '',
    SmbOptions options = const SmbOptions(),
  }) async {
    final c = await SmbConnection.open(host, port, address: address, options: options);
    try {
      await c.negotiate();
      SmbSession s;
      if (user.isEmpty) {
        try {
          s = await c.sessionSetup(user: '', password: '', workstation: workstation);
        } on SmbStatusException catch (e) {
          if (c.isClosed || !_isAuthFailure(e.status)) rethrow;
          s = await c.sessionSetup(user: 'Guest', password: password, workstation: workstation);
        }
      } else {
        s = await c.sessionSetup(user: user, password: password, domain: domain, workstation: workstation);
      }
      return SmbClient._(c, s);
    } catch (_) {
      c.destroy();
      rethrow;
    }
  }

  static bool _isAuthFailure(int s) => s == NtStatus.logonFailure || s == NtStatus.accessDenied || s == NtStatus.accountDisabled;

  bool get isClosed => connection.isClosed;

  Future<void> close() async {
    for (final t in _trees.values) {
      try {
        await connection.treeDisconnect(await t);
      } catch (_) {}
    }
    _trees.clear();
    await connection.close();
  }

  // ---------------------------------------------------------------- trees

  Future<SmbTree> tree(String share) {
    final key = share.toLowerCase();
    final f = _trees[key];
    if (f != null) return f;
    final created = connection.treeConnect(session, share);
    _trees[key] = created;
    created.then<void>((_) {}, onError: (Object e) {
      if (identical(_trees[key], created)) _trees.remove(key);
    });
    return created;
  }

  /// Forgets a tree the server dropped (NETWORK_NAME_DELETED).
  void forgetTree(String share) => _trees.remove(share.toLowerCase());

  // ---------------------------------------------------------------- CREATE / CLOSE

  static String smbPath(String path) {
    final parts = path.replaceAll('/', r'\').split(r'\').where((p) => p.isNotEmpty);
    return parts.join(r'\');
  }

  Future<SmbHandle> create(
    SmbTree tree,
    String path, {
    required int access,
    int attributes = 0,
    int share = ShareAccess.all,
    int disposition = CreateDisposition.open,
    int options = 0,
  }) async {
    final name = utf16le(smbPath(path));
    final w = SmbConnection.newRequest(56 + name.length + 8)
      ..u16(57)
      ..u8(0)
      ..u8(0) // no oplock
      ..u32(2) // impersonation
      ..u64(0)
      ..u64(0)
      ..u32(access)
      ..u32(attributes)
      ..u32(share)
      ..u32(disposition)
      ..u32(options)
      ..u16(64 + 56)
      ..u16(name.length)
      ..u32(0)
      ..u32(0)
      ..bytes(name);
    if (name.isEmpty) w.zeros(8);
    final r = await connection.send(SmbCommand.create, w, session: session, tree: tree);
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.create, path);
    return SmbHandle(
      tree,
      Uint8List.fromList(r.slice(64 + 64, 16)),
      r.u32(4),
      r.u32(56),
      r.u64(48),
      fromFileTime(r.u64(24)),
    );
  }

  Future<void> closeHandle(SmbHandle h) async {
    if (h.closed) return;
    h.closed = true;
    if (connection.isClosed) return;
    final w = SmbConnection.newRequest(24)
      ..u16(24)
      ..u16(0)
      ..u32(0)
      ..bytes(h.fileId);
    final r = await connection.send(SmbCommand.close, w, session: session, tree: h.tree);
    if (r.status != NtStatus.success && r.status != NtStatus.fileClosed) {
      throw SmbStatusException(r.status, SmbCommand.close);
    }
  }

  /// Runs [body] with [h] open and closes it afterwards, without letting a
  /// failed close hide [body]'s own error.
  Future<T> using<T>(SmbHandle h, Future<T> Function(SmbHandle h) body) async {
    T result;
    try {
      result = await body(h);
    } catch (_) {
      try {
        await closeHandle(h);
      } catch (_) {}
      rethrow;
    }
    await closeHandle(h);
    return result;
  }

  // ---------------------------------------------------------------- READ / WRITE

  int get readSize => connection.ioSize(connection.maxReadSize, preferredIoSize);
  int get writeSize => connection.ioSize(connection.maxWriteSize, preferredIoSize);

  /// Up to [length] bytes at [offset]; empty at the end of the file.
  Future<Uint8List> read(SmbHandle h, int offset, int length) async {
    final w = SmbConnection.newRequest(49)
      ..u16(49)
      ..u8(0x50)
      ..u8(0)
      ..u32(length)
      ..u64(offset)
      ..bytes(h.fileId)
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..u16(0)
      ..u16(0)
      ..u8(0);
    final r = await connection.send(
      SmbCommand.read,
      w,
      session: session,
      tree: h.tree,
      size: length,
      timeout: const Duration(seconds: 60),
    );
    if (r.status == NtStatus.endOfFile) return Uint8List(0);
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.read);
    return r.slice(r.u8(2), r.u32(4));
  }

  /// Writes [data] (from [start] to [end]) at [offset]; returns how much the
  /// server took.
  Future<int> write(SmbHandle h, int offset, Uint8List data, [int start = 0, int? end]) async {
    final e = end ?? data.length;
    final len = e - start;
    final w = SmbConnection.newRequest(48 + len)
      ..u16(49)
      ..u16(64 + 48)
      ..u32(len)
      ..u64(offset)
      ..bytes(h.fileId)
      ..u32(0)
      ..u32(0)
      ..u16(0)
      ..u16(0)
      ..u32(0)
      ..bytes(data, start, e);
    if (len == 0) w.u8(0);
    final r = await connection.send(
      SmbCommand.write,
      w,
      session: session,
      tree: h.tree,
      size: len,
      timeout: const Duration(seconds: 60),
    );
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.write);
    return r.u32(4);
  }

  /// The bytes of [h] from [start] to [end], several reads in flight at once,
  /// in order. Stops early if the file is shorter.
  Stream<Uint8List> readRange(SmbHandle h, int start, int end) async* {
    final chunk = readSize;
    final queue = Queue<(int, int, Future<Uint8List>)>();
    var next = start;

    void fill() {
      while (next < end && queue.length < pipelineDepth) {
        final n = min(chunk, end - next);
        // Marked as handled now: if the connection drops, the reads still
        // queued fail together, before anyone gets to await them.
        queue.add((next, n, read(h, next, n)..ignore()));
        next += n;
      }
    }

    try {
      fill();
      while (queue.isNotEmpty) {
        final (offset, want, future) = queue.removeFirst();
        var data = await future;
        if (data.length < want && data.isNotEmpty) {
          // A short read: fetch the rest of this piece before going on.
          final parts = <Uint8List>[data];
          var got = data.length;
          while (got < want) {
            final more = await read(h, offset + got, want - got);
            if (more.isEmpty) break;
            parts.add(more);
            got += more.length;
          }
          data = concatBytes(parts);
          if (got < want) {
            for (final (_, _, f) in queue) {
              f.ignore();
            }
            queue.clear();
            next = end;
          }
        } else if (data.isEmpty) {
          for (final (_, _, f) in queue) {
            f.ignore();
          }
          queue.clear();
          break;
        }
        fill();
        yield data;
      }
    } finally {
      for (final (_, _, f) in queue) {
        f.ignore();
      }
    }
  }

  /// Writes everything from [data] to [h] starting at offset 0, several
  /// writes in flight; [onProgress] gets the bytes the server confirmed.
  Future<int> writeStream(SmbHandle h, Stream<List<int>> data, {void Function(int sent)? onProgress}) async {
    final chunk = writeSize;
    final inFlight = Queue<Future<void>>();
    var buf = Uint8List(chunk);
    var fill = 0;
    var offset = 0;
    var confirmed = 0;
    Object? error;
    StackTrace? errorStack;

    void sendChunk(Uint8List b, int len) {
      final at = offset;
      offset += len;
      inFlight.add(write(h, at, b, 0, len).then((n) {
        if (n != len) throw SmbStatusException(NtStatus.diskFull, SmbCommand.write, 'short write');
        confirmed += n;
        onProgress?.call(confirmed);
      }).catchError((Object e, StackTrace st) {
        error ??= e;
        errorStack ??= st;
      }));
    }

    Future<void> drainTo(int depth) async {
      while (inFlight.length > depth) {
        await inFlight.removeFirst();
      }
      if (error != null) Error.throwWithStackTrace(error!, errorStack ?? StackTrace.current);
    }

    try {
      await for (final piece in data) {
        var i = 0;
        while (i < piece.length) {
          final n = min(piece.length - i, chunk - fill);
          buf.setRange(fill, fill + n, piece, i);
          fill += n;
          i += n;
          if (fill == chunk) {
            sendChunk(buf, fill);
            buf = Uint8List(chunk);
            fill = 0;
            await drainTo(pipelineDepth - 1);
          }
        }
      }
      if (fill > 0) sendChunk(buf, fill);
      await drainTo(0);
    } catch (_) {
      // Let the writes already sent settle before reporting.
      for (final f in inFlight) {
        await f;
      }
      inFlight.clear();
      rethrow;
    }
    return confirmed;
  }

  // ---------------------------------------------------------------- info

  Future<void> setInfo(SmbHandle h, int infoClass, Uint8List data, {int infoType = InfoType.file}) async {
    final w = SmbConnection.newRequest(32 + data.length)
      ..u16(33)
      ..u8(infoType)
      ..u8(infoClass)
      ..u32(data.length)
      ..u16(64 + 32)
      ..u16(0)
      ..u32(0)
      ..bytes(h.fileId)
      ..bytes(data);
    final r = await connection.send(SmbCommand.setInfo, w, session: session, tree: h.tree, size: data.length);
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.setInfo);
  }

  Future<Uint8List> queryInfo(SmbHandle h, int infoClass, {int infoType = InfoType.file, int maxOutput = 4096}) async {
    final w = SmbConnection.newRequest(41)
      ..u16(41)
      ..u8(infoType)
      ..u8(infoClass)
      ..u32(maxOutput)
      ..u16(0)
      ..u16(0)
      ..u32(0)
      ..u32(0)
      ..u32(0)
      ..bytes(h.fileId)
      ..u8(0);
    final r = await connection.send(SmbCommand.queryInfo, w, session: session, tree: h.tree, size: maxOutput);
    if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.queryInfo);
    return r.slice(r.u16(2), r.u32(4));
  }

  // ---------------------------------------------------------------- folders

  /// The folder's entries, without `.` and `..`.
  Future<List<SmbFileInfo>> list(SmbTree tree, String path) async {
    final h = await create(
      tree,
      path,
      access: FileAccess.readData | FileAccess.readAttributes | FileAccess.synchronize,
      options: CreateOptions.directoryFile,
    );
    return using(h, (h) async {
      final out = <SmbFileInfo>[];
      var infoClass = FileInfoClass.idBothDirectory;
      var first = true;
      final bufSize = connection.supportsMultiCredit ? min(connection.maxTransactSize, 256 * 1024) : min(connection.maxTransactSize, 65536);
      while (true) {
        final pattern = utf16le('*');
        final w = SmbConnection.newRequest(32 + pattern.length)
          ..u16(33)
          ..u8(infoClass)
          ..u8(first ? 1 : 0) // RESTART_SCANS on the first call
          ..u32(0)
          ..bytes(h.fileId)
          ..u16(64 + 32)
          ..u16(pattern.length)
          ..u32(bufSize)
          ..bytes(pattern);
        final r = await connection.send(SmbCommand.queryDirectory, w, session: session, tree: tree, size: bufSize);
        if (r.status == NtStatus.noMoreFiles) break;
        if (first && (r.status == NtStatus.invalidInfoClass || r.status == NtStatus.notSupported || r.status == NtStatus.invalidParameter) && infoClass != FileInfoClass.directory) {
          infoClass = FileInfoClass.directory;
          continue;
        }
        if (r.status != NtStatus.success) throw SmbStatusException(r.status, SmbCommand.queryDirectory, path);
        first = false;
        final data = r.slice(r.u16(2), r.u32(4));
        if (data.isEmpty) break;
        _parseDirectory(data, infoClass, out);
      }
      return out;
    });
  }

  static void _parseDirectory(Uint8List b, int infoClass, List<SmbFileInfo> out) {
    final nameAt = infoClass == FileInfoClass.idBothDirectory ? 104 : 64;
    var o = 0;
    while (o + nameAt <= b.length) {
      final next = le32(b, o);
      final nameLen = le32(b, o + 60);
      if (o + nameAt + nameLen > b.length) break;
      final name = fromUtf16le(b, o + nameAt, o + nameAt + nameLen);
      if (name != '.' && name != '..') {
        out.add(SmbFileInfo(
          name: name,
          attributes: le32(b, o + 56),
          size: le64(b, o + 40),
          modified: fromFileTime(le64(b, o + 24)),
          created: fromFileTime(le64(b, o + 8)),
        ));
      }
      if (next == 0) break;
      o += next;
    }
  }

  Future<SmbFileInfo> stat(SmbTree tree, String path) async {
    final h = await create(tree, path, access: FileAccess.readAttributes | FileAccess.synchronize);
    return using(h, (h) async => SmbFileInfo(
          name: smbPath(path).split(r'\').last,
          attributes: h.attributes,
          size: h.isDirectory ? 0 : h.endOfFile,
          modified: h.modified,
        ));
  }

  Future<void> createDirectory(SmbTree tree, String path) async {
    final h = await create(
      tree,
      path,
      access: FileAccess.readAttributes | FileAccess.synchronize,
      disposition: CreateDisposition.create,
      options: CreateOptions.directoryFile,
    );
    await closeHandle(h);
  }

  Future<void> rename(SmbTree tree, String from, String to, {bool replace = false}) async {
    final h = await create(tree, from, access: FileAccess.delete | FileAccess.readAttributes | FileAccess.synchronize);
    await using(h, (h) async {
      final name = utf16le(smbPath(to));
      final info = ByteWriter(20 + name.length)
        ..u8(replace ? 1 : 0)
        ..zeros(7)
        ..u64(0)
        ..u32(name.length)
        ..bytes(name);
      await setInfo(h, FileInfoClass.rename, info.toBytes());
    });
  }

  /// Deletes a file, or an empty folder.
  Future<void> deleteEntry(SmbTree tree, String path, {required bool directory}) async {
    Future<void> attempt() async {
      final h = await create(
        tree,
        path,
        access: FileAccess.delete | FileAccess.readAttributes | FileAccess.synchronize,
        options: directory ? CreateOptions.directoryFile : CreateOptions.nonDirectoryFile,
      );
      await using(h, (h) => setInfo(h, FileInfoClass.disposition, Uint8List.fromList([1])));
    }

    try {
      await attempt();
    } on SmbStatusException catch (e) {
      if (e.status != NtStatus.cannotDelete) rethrow;
      // Read-only: clear the attribute and try again, as Explorer does.
      await clearReadOnly(tree, path, directory: directory);
      await attempt();
    }
  }

  Future<void> clearReadOnly(SmbTree tree, String path, {required bool directory}) async {
    final h = await create(
      tree,
      path,
      access: FileAccess.readAttributes | FileAccess.writeAttributes | FileAccess.synchronize,
      options: directory ? CreateOptions.directoryFile : CreateOptions.nonDirectoryFile,
    );
    await using(h, (h) async {
      var attrs = h.attributes & ~FileAttr.readonly;
      if (attrs == 0) attrs = FileAttr.normal;
      final info = ByteWriter(40)
        ..zeros(32)
        ..u32(attrs)
        ..u32(0);
      await setInfo(h, FileInfoClass.basic, info.toBytes());
    });
  }

  // ---------------------------------------------------------------- shares

  Future<List<SmbShareInfo>> listShares() async {
    final ipc = await tree(r'IPC$');
    return SrvsvcClient(this, ipc).netShareEnumAll();
  }
}
