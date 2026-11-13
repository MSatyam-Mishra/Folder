import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart'
    show
        FILE_ATTRIBUTE_DIRECTORY,
        FILE_ATTRIBUTE_REPARSE_POINT,
        FIND_FIRST_EX_LARGE_FETCH,
        FindClose,
        FindExInfoBasic,
        FindExSearchNameMatch,
        FindFirstFileEx,
        FindNextFile,
        INVALID_HANDLE_VALUE,
        WIN32_FIND_DATA;

enum EntryKind { file, folder, link }

/// Something right in a folder: a link (or junction) is marked as one and
/// never followed.
class FolderEntry {
  const FolderEntry(this.name, this.kind, this.size, this.modified);

  final String name;
  final EntryKind kind;

  /// A file's size; 0 for the rest.
  final int size;

  /// Milliseconds since the epoch.
  final int modified;
}

/// Lists a folder with each file's size and modified time. On Windows that's
/// one system call per batch of names (FindFirstFileEx), where asking each
/// file for them costs several times more than listing.
abstract final class FolderListing {
  /// What's right in [folder]; null if it can't be read.
  static List<FolderEntry>? list(String folder) => Platform.isWindows ? _windows(folder) : _portable(folder);

  static List<FolderEntry>? _portable(String folder) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(folder).listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }
    final listed = <FolderEntry>[];
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (entry is File) {
        final FileStat stat;
        try {
          stat = entry.statSync();
        } on FileSystemException {
          continue;
        }
        if (stat.type != FileSystemEntityType.file) continue;
        listed.add(FolderEntry(name, EntryKind.file, stat.size, stat.modified.millisecondsSinceEpoch));
      } else if (entry is Directory) {
        listed.add(FolderEntry(name, EntryKind.folder, 0, 0));
      } else {
        listed.add(FolderEntry(name, EntryKind.link, 0, 0));
      }
    }
    return listed;
  }

  /// Reparse points that lead elsewhere, as Dart's own listing takes them:
  /// symbolic links, junctions and WSL's links; also app aliases, which
  /// aren't files that can be read. OneDrive's placeholders are files.
  static bool _isLink(int tag) =>
      tag == 0xA000000C || tag == 0xA0000003 || tag == 0xA000001D || tag == 0x8000001B;

  /// Windows' FILETIME (100 ns steps since 1601) in milliseconds since 1970.
  static const _epochGap = 11644473600000;

  /// [path] as Windows takes it past 260 characters.
  static String _long(String path) {
    final normal = p.windows.normalize(path);
    if (normal.length < 240 || normal.startsWith(r'\\?\')) return normal;
    if (normal.startsWith(r'\\')) return '\\\\?\\UNC\\${normal.substring(2)}';
    return '\\\\?\\$normal';
  }

  static List<FolderEntry>? _windows(String folder) {
    final pattern = p.windows.join(_long(folder), '*').toNativeUtf16(allocator: calloc);
    final data = calloc<WIN32_FIND_DATA>();
    try {
      final handle = FindFirstFileEx(
        pattern,
        FindExInfoBasic,
        data,
        FindExSearchNameMatch,
        nullptr,
        FIND_FIRST_EX_LARGE_FETCH,
      );
      if (handle == INVALID_HANDLE_VALUE) return null;
      final listed = <FolderEntry>[];
      try {
        do {
          final found = data.ref;
          final name = found.cFileName;
          if (name == '.' || name == '..') continue;
          final attributes = found.dwFileAttributes;
          final kind = attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 && _isLink(found.dwReserved0)
              ? EntryKind.link
              : (attributes & FILE_ATTRIBUTE_DIRECTORY != 0 ? EntryKind.folder : EntryKind.file);
          final written = found.ftLastWriteTime;
          final time = written.dwHighDateTime * 0x100000000 + written.dwLowDateTime;
          listed.add(FolderEntry(
            name,
            kind,
            kind == EntryKind.file ? found.nFileSizeHigh * 0x100000000 + found.nFileSizeLow : 0,
            time ~/ 10000 - _epochGap,
          ));
        } while (FindNextFile(handle, data) != 0);
      } finally {
        FindClose(handle);
      }
      return listed;
    } finally {
      calloc.free(pattern);
      calloc.free(data);
    }
  }
}
