import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/new_files.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart'
    show
        CloseHandle,
        CoInitializeEx,
        CoUninitialize,
        COINIT_APARTMENTTHREADED,
        DRIVE_FIXED,
        FO_DELETE,
        FOF_ALLOWUNDO,
        FOF_NOCONFIRMATION,
        FOF_NOERRORUI,
        FOF_SILENT,
        FOF_WANTNUKEWARNING,
        GetCurrentProcess,
        GetDriveType,
        GetLogicalDrives,
        GetTokenInformation,
        LocalFree,
        OpenProcessToken,
        SHEmptyRecycleBin,
        SHFILEOPSTRUCT,
        SHFileOperation,
        SHQUERYRBINFO,
        SHQueryRecycleBin,
        TOKEN_QUERY,
        TokenUser;

/// Windows' Recycle Bin. Files go there through the shell (SHFileOperation
/// with undo), as File Explorer sends them. It's read straight from each
/// fixed drive's `$Recycle.Bin\<user's SID>` folder: an item is a `$R…` file
/// or folder, and the `$I…` file of the same name says where it was, when
/// it was deleted and how big it is.
class WindowsRecycleBin extends Trash {
  WindowsRecycleBin({this.drives});

  /// The drives to look in (`C:\`...); every fixed drive when null.
  final List<String>? drives;

  @override
  String get label => 'Recycle Bin';

  @override
  bool canTrash(String path) =>
      super.canTrash(path) && ExplorerPaths.isFullWindowsPath(path) && !path.startsWith(r'\\');

  @override
  bool contains(String path) => path.toLowerCase().contains(r'\$recycle.bin\');

  @override
  Future<void> Function()? get openInSystem =>
      () => Process.start('explorer.exe', ['shell:RecycleBinFolder'], mode: ProcessStartMode.detached);

  @override
  Future<TrashResult> moveToTrash(List<String> paths) async {
    final failed = <String, String>{};
    final sending = <String>[];
    for (final path in paths) {
      final root = p.windows.rootPrefix(path);
      if (!canTrash(path)) {
        failed[path] = 'It can\'t go to the Recycle Bin';
      } else if (!_hasRecycleBin(root)) {
        failed[path] = 'This drive has no Recycle Bin';
      } else {
        sending.add(path);
      }
    }
    if (sending.isNotEmpty) {
      final started = DateTime.now().subtract(const Duration(seconds: 2));
      final code = await Isolate.run(() => _shellDelete(sending));
      final gone = <String>[];
      for (final path in sending) {
        if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound) {
          gone.add(path);
        } else {
          failed[path] = code == 0 ? "Windows didn't move it" : 'Windows refused (error $code)';
        }
      }
      final trashed = _findTrashed(gone, since: started);
      return TrashResult(trashed: trashed, failed: failed);
    }
    return TrashResult(failed: failed);
  }

  /// The items now in the Recycle Bin for [paths], the newest for each.
  List<TrashItem> _findTrashed(List<String> paths, {required DateTime since}) {
    if (paths.isEmpty) return const [];
    final wanted = {for (final path in paths) path.toLowerCase(): path};
    final roots = {for (final path in paths) p.windows.rootPrefix(path).toUpperCase()};
    final newest = <String, TrashItem>{};
    for (final item in _listSync(roots: roots)) {
      final key = item.originalPath.toLowerCase();
      if (!wanted.containsKey(key)) continue;
      final before = newest[key];
      final at = item.deletedAt ?? DateTime(0);
      if (at.isBefore(since)) continue;
      if (before == null || at.isAfter(before.deletedAt ?? DateTime(0))) newest[key] = item;
    }
    return [for (final path in paths) if (newest[path.toLowerCase()] case final item?) item];
  }

  @override
  Future<List<TrashItem>> list() async => _listSync();

  List<TrashItem> _listSync({Set<String>? roots}) {
    final sid = userSid();
    if (sid == null) return const [];
    final items = <TrashItem>[];
    for (final root in roots ?? (drives ?? fixedDrives())) {
      final folder = Directory(p.windows.join(root, r'$Recycle.Bin', sid));
      List<FileSystemEntity> entries;
      try {
        entries = folder.listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final entry in entries) {
        final name = p.windows.basename(entry.path);
        if (!name.startsWith(r'$I') || entry is! File) continue;
        final stored = p.windows.join(folder.path, '\$R${name.substring(2)}');
        final type = FileSystemEntity.typeSync(stored, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        try {
          final info = parseInfo(entry.readAsBytesSync());
          if (info == null) continue;
          items.add(TrashItem(
            name: p.windows.basename(info.path),
            originalPath: info.path,
            storedPath: stored,
            isDirectory: type == FileSystemEntityType.directory,
            deletedAt: info.deletedAt,
            size: info.size,
          ));
        } catch (_) {
          // An $I file being written, or one we can't read.
        }
      }
    }
    return items;
  }

  @override
  Future<String> restore(TrashItem item) async {
    var target = item.originalPath;
    final folder = p.windows.dirname(target);
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      final name = p.windows.basename(target);
      final ext = item.isDirectory ? '' : p.windows.extension(name);
      final base = ext.isEmpty ? name : name.substring(0, name.length - ext.length);
      target = p.windows.join(folder, NewFiles.freeName(folder, base, ext.isEmpty ? '' : ext.substring(1)));
    }
    await Directory(folder).create(recursive: true);
    if (item.isDirectory) {
      await Directory(item.storedPath).rename(target);
    } else {
      await File(item.storedPath).rename(target);
    }
    await _deleteQuietly(File(_infoOf(item.storedPath)));
    _updateIcon();
    return target;
  }

  @override
  Future<void> deleteForGood(TrashItem item) async {
    if (item.isDirectory) {
      await Directory(item.storedPath).delete(recursive: true);
    } else {
      await File(item.storedPath).delete();
    }
    await _deleteQuietly(File(_infoOf(item.storedPath)));
    _updateIcon();
  }

  @override
  Future<void> empty() async {
    // Every drive's, as File Explorer's Empty Recycle Bin does.
    await Isolate.run(() {
      // SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND. An empty
      // bin answers E_UNEXPECTED, which is fine.
      SHEmptyRecycleBin(0, nullptr, 0x7);
    });
  }

  static String _infoOf(String stored) {
    final name = p.windows.basename(stored);
    return p.windows.join(p.windows.dirname(stored), '\$I${name.substring(2)}');
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Fixed drives (`C:\`...): removable sticks, network drives and discs
  /// have no Recycle Bin.
  static List<String> fixedDrives() {
    final mask = GetLogicalDrives();
    final drives = <String>[];
    for (var i = 0; i < 26; i++) {
      if (mask & (1 << i) == 0) continue;
      final root = '${String.fromCharCode(65 + i)}:\\';
      final name = root.toNativeUtf16();
      try {
        if (GetDriveType(name) == DRIVE_FIXED) drives.add(root);
      } finally {
        calloc.free(name);
      }
    }
    return drives;
  }

  static bool _hasRecycleBin(String root) {
    if (root.isEmpty || root.startsWith(r'\\')) return false;
    final name = root.toNativeUtf16();
    final info = calloc<SHQUERYRBINFO>()..ref.cbSize = sizeOf<SHQUERYRBINFO>();
    try {
      return GetDriveType(name) == DRIVE_FIXED && SHQueryRecycleBin(name, info) == 0;
    } finally {
      calloc.free(name);
      calloc.free(info);
    }
  }

  /// Sends [paths] to the Recycle Bin through the shell; 0 when it went.
  /// Runs in its own isolate: a big folder takes a while.
  static int _shellDelete(List<String> paths) {
    // Double-null-terminated, as SHFileOperation wants.
    final from = '${paths.join('\u0000')}\u0000'.toNativeUtf16();
    final op = calloc<SHFILEOPSTRUCT>();
    final com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    try {
      op.ref
        ..wFunc = FO_DELETE
        ..pFrom = from
        // Asks (the shell's own prompt) only if something is too big for
        // the Recycle Bin and would be deleted for good.
        ..fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT | FOF_WANTNUKEWARNING;
      final result = SHFileOperation(op);
      return result != 0 ? result : (op.ref.fAnyOperationsAborted != 0 ? -1 : 0);
    } finally {
      if (com >= 0) CoUninitialize();
      calloc.free(op);
      calloc.free(from);
    }
  }

  static void Function()? _iconUpdater;

  /// Tells the desktop's Recycle Bin icon it may have filled or emptied.
  static void _updateIcon() {
    try {
      _iconUpdater ??= DynamicLibrary.open('shell32.dll')
          .lookupFunction<Void Function(), void Function()>('SHUpdateRecycleBinIcon');
      _iconUpdater!();
    } catch (_) {}
  }

  static String? _sid;

  /// The user's security id (S-1-5-21-…), which names their folder in each
  /// `$Recycle.Bin`.
  static String? userSid() => _sid ??= _sidFromToken() ?? _sidFromWhoami();

  static String? _sidFromToken() {
    final token = calloc<IntPtr>();
    final needed = calloc<Uint32>();
    final text = calloc<Pointer<Utf16>>();
    Pointer<Uint8>? buffer;
    try {
      if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, token) == 0) return null;
      GetTokenInformation(token.value, TokenUser, nullptr, 0, needed);
      if (needed.value == 0) return null;
      buffer = calloc<Uint8>(needed.value);
      if (GetTokenInformation(token.value, TokenUser, buffer, needed.value, needed) == 0) return null;
      // TOKEN_USER starts with SID_AND_ATTRIBUTES, which starts with the SID.
      final sid = buffer.cast<Pointer>().value;
      final convert = DynamicLibrary.open('advapi32.dll').lookupFunction<
          Int32 Function(Pointer, Pointer<Pointer<Utf16>>),
          int Function(Pointer, Pointer<Pointer<Utf16>>)>('ConvertSidToStringSidW');
      if (convert(sid, text) == 0) return null;
      final result = text.value.toDartString();
      LocalFree(text.value);
      return result;
    } catch (_) {
      return null;
    } finally {
      if (token.value != 0) CloseHandle(token.value);
      calloc.free(token);
      calloc.free(needed);
      calloc.free(text);
      if (buffer != null) calloc.free(buffer);
    }
  }

  static String? _sidFromWhoami() {
    try {
      final result = Process.runSync('whoami', ['/user', '/fo', 'csv', '/nh']);
      final match = RegExp(r'S-1-[0-9-]+').firstMatch('${result.stdout}');
      return match?.group(0);
    } catch (_) {
      return null;
    }
  }

  /// What a `$I` file holds: version 1 (Vista to 8.1) has the path in a
  /// fixed 520-byte field, version 2 (10 and later) gives its length first.
  @visibleForTesting
  static ({String path, int size, DateTime deletedAt})? parseInfo(Uint8List bytes) {
    if (bytes.length < 28) return null;
    final data = ByteData.sublistView(bytes);
    final version = data.getInt64(0, Endian.little);
    final size = data.getInt64(8, Endian.little);
    final filetime = data.getInt64(16, Endian.little);
    int start;
    int chars;
    if (version == 1) {
      start = 24;
      chars = (bytes.length - 24) ~/ 2;
    } else if (version == 2) {
      chars = data.getUint32(24, Endian.little);
      start = 28;
    } else {
      return null;
    }
    final units = <int>[];
    for (var i = 0; i < chars && start + i * 2 + 1 < bytes.length; i++) {
      final unit = data.getUint16(start + i * 2, Endian.little);
      if (unit == 0) break;
      units.add(unit);
    }
    if (units.isEmpty) return null;
    // FILETIME: 100 ns steps since 1601, in UTC.
    final deletedAt = DateTime.utc(1601).add(Duration(microseconds: filetime ~/ 10)).toLocal();
    return (path: String.fromCharCodes(units), size: size, deletedAt: deletedAt);
  }
}
