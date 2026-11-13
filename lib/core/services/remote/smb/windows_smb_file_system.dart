import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

import '../remote_fs.dart';
import 'smb_bytes.dart' show fromFileTime;

/// Windows shares through Windows' own SMB client: UNC paths
/// (`\\host\share\...`) with dart:io, a sign-in through
/// `WNetAddConnection2W` on `\\host\IPC$`, and `NetShareEnum` for the list
/// of shares. Windows then does Kerberos, signing, encryption, DFS and
/// multichannel by itself, and uses the user's own sign-in when no user name
/// is given. Only for the standard port: Windows can't be told another one.
class WindowsSmbFileSystem implements RemoteFileSystem {
  WindowsSmbFileSystem(this.connection, this.secrets, {this.rootOverride});

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;

  /// For tests: a local folder standing in for `\\host`, whose subfolders
  /// play the shares. Skips the sign-in and NetShareEnum.
  final String? rootOverride;

  bool _addedConnection = false;

  bool get showHiddenShares => connection.options['showHiddenShares'] == 'true';

  /// `\\host`, with IPv6 literals in the form Windows takes in UNC paths.
  String get uncHost {
    if (rootOverride != null) return rootOverride!;
    var h = connection.host.trim();
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    final ip = InternetAddress.tryParse(h);
    if (ip != null && ip.type == InternetAddressType.IPv6) {
      h = '${h.replaceAll(':', '-').replaceAll('%', 's')}.ipv6-literal.net';
    }
    return '\\\\$h';
  }

  /// The UNC path of a connection path (`/Share/a/b` → `\\host\Share\a\b`).
  String uncOf(String path) {
    final parts = RemotePaths.normalize(path).split('/').where((p) => p.isNotEmpty);
    return parts.isEmpty ? uncHost : '$uncHost\\${parts.join('\\')}';
  }

  static (String, String) _split(String path) {
    final parts = RemotePaths.normalize(path).split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return ('', '');
    return (parts.first, parts.skip(1).join('/'));
  }

  String get _user {
    final u = connection.username.trim();
    final domain = (connection.options['domain'] ?? '').trim();
    if (u.isEmpty || domain.isEmpty || u.contains(r'\') || u.contains('@')) return u;
    return '$domain\\$u';
  }

  @override
  Future<void> connect() async {
    if (rootOverride != null) return;
    final user = _user;
    if (user.isNotEmpty) {
      final password = await secrets.read('password') ?? '';
      final remote = '$uncHost\\IPC\$';
      final code = await Isolate.run(() => _wnetAdd(remote, user, password));
      if (code == _errorAlreadyAssigned) {
        // Already connected with these details, from before.
      } else if (code != 0) {
        throw WindowsSmbException(code, windowsSmbError(code, host: connection.host));
      } else {
        _addedConnection = true;
      }
    }
    // Check the share (or the server) answers with these details.
    final (share, _) = _split(connection.rootPath);
    if (share.isNotEmpty) {
      await stat('/$share');
    } else {
      await _shares();
    }
  }

  Future<List<String>> _shares() async {
    final server = uncHost;
    final result = await Isolate.run(() => _netShareEnum(server));
    if (result.$1 != 0) throw WindowsSmbException(result.$1, windowsSmbError(result.$1, host: connection.host));
    return [
      for (final (name, type) in result.$2)
        if ((type & 0xffff) == 0 && (showHiddenShares || !(name.endsWith(r'$') || (type & 0x80000000) != 0))) name,
    ];
  }

  RemoteException _map(Object e) {
    if (e is RemoteException) return e;
    if (e is WindowsSmbException) return e.remote;
    if (e is FileSystemException) {
      final code = e.osError?.errorCode ?? 0;
      return windowsSmbError(code, host: connection.host, fallback: e.osError?.message ?? e.message);
    }
    return RemoteException(RemoteErrorKind.other, '$e');
  }

  Future<T> _io<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final norm = RemotePaths.normalize(path);
    final (share, _) = _split(norm);
    if (share.isEmpty) {
      if (rootOverride != null) {
        return _io(() async => [
              await for (final e in Directory(rootOverride!).list())
                if (e is Directory) RemoteEntry(path: '/${e.path.split(RegExp(r'[\\/]')).last}', isDirectory: true),
            ]);
      }
      try {
        return [for (final s in await _shares()) RemoteEntry(path: '/$s', isDirectory: true)];
      } on WindowsSmbException catch (e) {
        throw e.remote;
      }
    }
    final unc = uncOf(norm);
    final (code, items) = await Isolate.run(() => _findFiles(unc));
    if (code != 0) throw windowsSmbError(code, host: connection.host);
    return [
      for (final (name, attrs, size, modified) in items)
        RemoteEntry(
          path: RemotePaths.join(norm, name),
          isDirectory: (attrs & 0x10) != 0,
          size: (attrs & 0x10) != 0 ? 0 : size,
          modified: fromFileTime(modified),
        ),
    ];
  }

  @override
  Future<RemoteEntry> stat(String path) => _io(() async {
        final norm = RemotePaths.normalize(path);
        if (norm == '/') return const RemoteEntry(path: '/', isDirectory: true);
        final s = await FileStat.stat(uncOf(norm));
        if (s.type == FileSystemEntityType.notFound) {
          // FileStat doesn't say why; ask the folder above for a better error.
          final (share, rel) = _split(norm);
          if (rel.isEmpty && rootOverride == null) {
            final shares = await _shares();
            if (!shares.any((x) => x.toLowerCase() == share.toLowerCase())) {
              throw RemoteException(RemoteErrorKind.notFound, 'There\'s no share called $share on ${connection.host}.');
            }
          }
          throw const RemoteException(RemoteErrorKind.notFound, 'It isn\'t there any more.');
        }
        final dir = s.type == FileSystemEntityType.directory;
        return RemoteEntry(path: norm, isDirectory: dir, size: dir ? 0 : s.size, modified: s.modified);
      });

  @override
  Stream<List<int>> openRead(String path, {int start = 0, int? end}) async* {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) throw const RemoteException(RemoteErrorKind.other, 'That\'s a folder, not a file.');
    final stream = File(uncOf(path)).openRead(start, end);
    try {
      yield* stream;
    } catch (e) {
      throw _map(e);
    }
  }

  @override
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  }) async {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Files go inside a share, not next to them.');
    }
    final file = File(uncOf(path));
    var created = false;
    await _io(() async {
      if (!overwrite) {
        await file.create(exclusive: true);
        created = true;
      } else if (!await file.exists()) {
        created = true;
      }
    });
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.write);
      var sent = 0;
      await for (final chunk in data) {
        await raf.writeFrom(chunk);
        sent += chunk.length;
        onProgress?.call(sent);
      }
      await raf.close();
      raf = null;
    } catch (e) {
      try {
        await raf?.close();
      } catch (_) {}
      if (created) {
        try {
          await file.delete();
        } catch (_) {}
      }
      throw _map(e);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'New shares can only be made on the server itself.');
    }
    await _io(() async {
      final dir = Directory(uncOf(path));
      if (await FileSystemEntity.type(dir.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.');
      }
      await dir.create();
    });
  }

  @override
  Future<void> delete(String path) async {
    final (share, rel) = _split(path);
    if (share.isEmpty || rel.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Shares can only be removed on the server itself.');
    }
    final unc = uncOf(path);
    await _io(() async {
      final type = await FileSystemEntity.type(unc, followLinks: false);
      switch (type) {
        case FileSystemEntityType.notFound:
          throw const RemoteException(RemoteErrorKind.notFound, 'It isn\'t there any more.');
        case FileSystemEntityType.directory:
          await Directory(unc).delete(recursive: true);
        default:
          try {
            await File(unc).delete();
          } on FileSystemException catch (e) {
            if (e.osError?.errorCode != 5 || !Platform.isWindows) rethrow;
            // Read-only files need the attribute cleared first.
            await Isolate.run(() => _clearReadOnly(unc));
            await File(unc).delete();
          }
      }
    });
  }

  @override
  Future<void> rename(String from, String to) async {
    final (s1, r1) = _split(from);
    final (s2, r2) = _split(to);
    if (s1.isEmpty || r1.isEmpty || s2.isEmpty || r2.isEmpty) {
      throw const RemoteException(RemoteErrorKind.unsupported, 'Shares can only be renamed on the server itself.');
    }
    final src = uncOf(from);
    final dst = uncOf(to);
    await _io(() async {
      final type = await FileSystemEntity.type(src, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        throw const RemoteException(RemoteErrorKind.notFound, 'It isn\'t there any more.');
      }
      final same = src.toLowerCase() == dst.toLowerCase();
      if (!same && await FileSystemEntity.type(dst, followLinks: false) != FileSystemEntityType.notFound) {
        throw const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.');
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(src).rename(dst);
      } else {
        await File(src).rename(dst);
      }
    });
  }

  @override
  Future<void> close() async {
    if (!_addedConnection) return;
    _addedConnection = false;
    final remote = '$uncHost\\IPC\$';
    try {
      await Isolate.run(() => _wnetCancel(remote));
    } catch (_) {}
  }
}

class WindowsSmbException implements Exception {
  WindowsSmbException(this.code, this.remote);

  final int code;
  final RemoteException remote;

  /// Errors where the plain-Dart client may still get in: another sign-in to
  /// the same server already in use, guests blocked by policy, or Windows'
  /// client being off.
  bool get worthFallback => windowsSmbFallbackCodes.contains(code);

  @override
  String toString() => 'WindowsSmbException($code, ${remote.message})';
}

const _errorAlreadyAssigned = 85;

/// See [WindowsSmbException.worthFallback].
const windowsSmbFallbackCodes = {
  1219, // ERROR_SESSION_CREDENTIAL_CONFLICT
  1272, // guests blocked by policy (insecure guest logons)
  2138, // NERR_WkstaNotStarted
  1222, // ERROR_NO_NETWORK
  50, // ERROR_NOT_SUPPORTED
  1200, // ERROR_BAD_DEVICE
};

/// Plain words for Win32 and network error codes from UNC paths, WNet and
/// NetShareEnum.
RemoteException windowsSmbError(int code, {required String host, String? fallback}) {
  switch (code) {
    case 2:
    case 3:
    case 161: // ERROR_BAD_PATHNAME
      return const RemoteException(RemoteErrorKind.notFound, 'It isn\'t there any more.');
    case 5:
      return const RemoteException(RemoteErrorKind.permission, 'Access was refused.');
    case 32:
    case 33:
      return const RemoteException(RemoteErrorKind.other, 'Another program on the server is using this file.');
    case 17:
      return const RemoteException(RemoteErrorKind.unsupported, 'Moving between shares can\'t be done in one step.');
    case 39:
    case 112:
      return const RemoteException(RemoteErrorKind.other, 'There\'s no room left on the share.');
    case 19:
      return const RemoteException(RemoteErrorKind.permission, 'This share is read-only.');
    case 53:
    case 1203:
      return RemoteException(RemoteErrorKind.network, 'Couldn\'t find $host on the network, or file sharing is off there.');
    case 64:
    case 59:
    case 121:
    case 1231:
    case 1232:
    case 1222:
      return RemoteException(RemoteErrorKind.network, 'The connection to $host broke or couldn\'t be made.');
    case 67:
      return RemoteException(RemoteErrorKind.notFound, 'There\'s no share by that name on $host.');
    case 80:
    case 183:
      return const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.');
    case 86:
    case 1326:
    case 2202:
      return const RemoteException(RemoteErrorKind.auth, 'The user name or password was refused.');
    case 1327:
      return const RemoteException(
        RemoteErrorKind.auth,
        'This account can\'t sign in over the network. Windows refuses accounts with an empty password there.',
      );
    case 1330:
    case 1907:
      return const RemoteException(RemoteErrorKind.auth, 'The password has expired. Change it on the server first.');
    case 1331:
      return const RemoteException(RemoteErrorKind.auth, 'This account is turned off on the server.');
    case 1909:
      return const RemoteException(RemoteErrorKind.auth, 'This account is locked after too many wrong passwords.');
    case 1219:
      return RemoteException(
        RemoteErrorKind.auth,
        'Windows is already connected to $host as another user. Disconnect that first, or use the same user here.',
      );
    case 1272:
      return const RemoteException(RemoteErrorKind.auth, 'Windows blocks guest access to shares. Sign in with a user name and password.');
    case 145:
      return const RemoteException(RemoteErrorKind.other, 'The folder isn\'t empty.');
    case 267:
      return const RemoteException(RemoteErrorKind.notFound, 'That\'s a file, not a folder.');
    case 123:
      return const RemoteException(RemoteErrorKind.other, 'The server doesn\'t allow that name.');
  }
  return RemoteException(RemoteErrorKind.other, fallback ?? 'Windows reported error $code.');
}

// ------------------------------------------------------------------ FFI (run in isolates)

final class _NetResource extends Struct {
  @Uint32()
  external int dwScope;
  @Uint32()
  external int dwType;
  @Uint32()
  external int dwDisplayType;
  @Uint32()
  external int dwUsage;
  external Pointer<Utf16> lpLocalName;
  external Pointer<Utf16> lpRemoteName;
  external Pointer<Utf16> lpComment;
  external Pointer<Utf16> lpProvider;
}

final class _ShareInfo1 extends Struct {
  external Pointer<Utf16> netname;
  @Uint32()
  external int type;
  external Pointer<Utf16> remark;
}

typedef _WNetAddC = Uint32 Function(Pointer<_NetResource>, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _WNetAddD = int Function(Pointer<_NetResource>, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _WNetCancelC = Uint32 Function(Pointer<Utf16>, Uint32, Int32);
typedef _WNetCancelD = int Function(Pointer<Utf16>, int, int);
typedef _NetShareEnumC = Uint32 Function(Pointer<Utf16>, Uint32, Pointer<Pointer<Uint8>>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _NetShareEnumD = int Function(Pointer<Utf16>, int, Pointer<Pointer<Uint8>>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>);
typedef _NetFreeC = Uint32 Function(Pointer<Uint8>);
typedef _NetFreeD = int Function(Pointer<Uint8>);

int _wnetAdd(String remote, String user, String password) => using((arena) {
      final mpr = DynamicLibrary.open('mpr.dll');
      final add = mpr.lookupFunction<_WNetAddC, _WNetAddD>('WNetAddConnection2W');
      final res = arena<_NetResource>();
      res.ref
        ..dwScope = 0
        ..dwType = 0 // RESOURCETYPE_ANY
        ..dwDisplayType = 0
        ..dwUsage = 0
        ..lpLocalName = nullptr
        ..lpRemoteName = remote.toNativeUtf16(allocator: arena)
        ..lpComment = nullptr
        ..lpProvider = nullptr;
      const connectTemporary = 0x4;
      return add(res, password.toNativeUtf16(allocator: arena), user.toNativeUtf16(allocator: arena), connectTemporary);
    });

int _wnetCancel(String remote) => using((arena) {
      final mpr = DynamicLibrary.open('mpr.dll');
      final cancel = mpr.lookupFunction<_WNetCancelC, _WNetCancelD>('WNetCancelConnection2W');
      return cancel(remote.toNativeUtf16(allocator: arena), 0, 0);
    });

(int, List<(String, int)>) _netShareEnum(String server) => using((arena) {
      final net = DynamicLibrary.open('netapi32.dll');
      final enumShares = net.lookupFunction<_NetShareEnumC, _NetShareEnumD>('NetShareEnum');
      final free = net.lookupFunction<_NetFreeC, _NetFreeD>('NetApiBufferFree');
      final buf = arena<Pointer<Uint8>>();
      final read = arena<Uint32>();
      final total = arena<Uint32>();
      final resume = arena<Uint32>()..value = 0;
      final out = <(String, int)>[];
      while (true) {
        final code = enumShares(server.toNativeUtf16(allocator: arena), 1, buf, 0xffffffff, read, total, resume);
        if (code != 0 && code != 234) return (code, out);
        final items = buf.value.cast<_ShareInfo1>();
        for (var i = 0; i < read.value; i++) {
          final s = (items + i).ref;
          out.add((s.netname.toDartString(), s.type));
        }
        if (buf.value != nullptr) free(buf.value);
        if (code != 234) return (0, out);
      }
    });

/// (error, [(name, attributes, size, last write FILETIME)]) of a folder.
(int, List<(String, int, int, int)>) _findFiles(String dir) => using((arena) {
      final pattern = _longPath(dir, '*').toNativeUtf16(allocator: arena);
      final data = arena<win.WIN32_FIND_DATA>();
      final h = win.FindFirstFileEx(pattern, win.FindExInfoBasic, data, 0, nullptr, win.FIND_FIRST_EX_LARGE_FETCH);
      final out = <(String, int, int, int)>[];
      if (h == win.INVALID_HANDLE_VALUE) {
        // The last error isn't always kept across FFI calls, so ask the folder
        // itself whether it's empty, missing or a file.
        final err = win.GetLastError();
        final full = _longPath(dir, '');
        final attrs = win.GetFileAttributes(full.substring(0, full.length - 1).toNativeUtf16(allocator: arena));
        final unclear = err == 0 || err == 2 || err == 18;
        if (attrs == 0xffffffff) return (unclear ? 3 : err, out);
        if ((attrs & 0x10) == 0) return (267, out); // ERROR_DIRECTORY
        return (unclear ? 0 : err, out);
      }
      try {
        do {
          final d = data.ref;
          final name = d.cFileName;
          if (name != '.' && name != '..') {
            final size = (d.nFileSizeHigh << 32) | d.nFileSizeLow;
            final mtime = (d.ftLastWriteTime.dwHighDateTime << 32) | d.ftLastWriteTime.dwLowDateTime;
            out.add((name, d.dwFileAttributes, size, mtime));
          }
        } while (win.FindNextFile(h, data) != 0);
      } finally {
        win.FindClose(h);
      }
      return (0, out);
    });

/// [dir] joined with [name], in the `\\?\` form that has no length limit.
String _longPath(String dir, String name) {
  if (dir.startsWith(r'\\?\')) return '$dir\\$name';
  if (dir.startsWith(r'\\')) return '\\\\?\\UNC\\${dir.substring(2)}\\$name';
  if (RegExp(r'^[A-Za-z]:').hasMatch(dir)) return '\\\\?\\$dir\\$name';
  return '$dir\\$name';
}

void _clearReadOnly(String path) => using((arena) {
      final p = path.toNativeUtf16(allocator: arena);
      final attrs = win.GetFileAttributes(p);
      if (attrs == 0xffffffff) return;
      final cleared = attrs & ~0x1;
      win.SetFileAttributes(p, cleared == 0 ? 0x80 : cleared);
    });
