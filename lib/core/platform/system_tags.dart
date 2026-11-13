import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:folders/core/formats/finder_tags_plist.dart';

/// Tags the system keeps beside a file, in an extended attribute, so other
/// apps show the tags Folders sets: Finder's on macOS, and `user.xdg.tags`
/// (what Dolphin and other KDE apps read) on Linux. Folders' own list stays
/// the source of truth; this is a copy for the system, and where tags set in
/// Finder or Dolphin are read from.
///
/// Neither has been run yet: this was written on Windows. Only Finder's
/// property list encoding is tested ([FinderTagsPlist]).
abstract class SystemTags {
  /// The system's tags here; none on Windows, Android or in tests.
  static SystemTags? forPlatform() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    if (Platform.isMacOS) return MacFinderTags();
    if (Platform.isLinux) return XdgTags();
    return null;
  }

  /// The tags on [path]; null when there are none or they can't be read.
  List<FinderTag>? read(String path);

  /// Puts [tags] on [path] (none removes the attribute). Returns false when
  /// the file system doesn't allow it (FAT drives, read-only places).
  bool write(String path, List<FinderTag> tags);
}

/// Finder's tags: `com.apple.metadata:_kMDItemUserTags`, a binary plist of
/// "Name\nColour" strings.
class MacFinderTags extends SystemTags {
  @override
  List<FinderTag>? read(String path) {
    final bytes = _MacXattr.get(path, FinderTagsPlist.attribute);
    return bytes == null ? null : FinderTagsPlist.decode(bytes);
  }

  @override
  bool write(String path, List<FinderTag> tags) => tags.isEmpty
      ? _MacXattr.remove(path, FinderTagsPlist.attribute)
      : _MacXattr.set(path, FinderTagsPlist.attribute, FinderTagsPlist.encode(tags));
}

/// The freedesktop tags attribute: names, comma separated, in UTF-8. It has
/// no colours.
class XdgTags extends SystemTags {
  static const attribute = 'user.xdg.tags';

  @override
  List<FinderTag>? read(String path) {
    final bytes = _LinuxXattr.get(path, attribute);
    if (bytes == null) return null;
    final names = utf8.decode(bytes, allowMalformed: true).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    return [for (final name in names) FinderTag(name)];
  }

  @override
  bool write(String path, List<FinderTag> tags) => tags.isEmpty
      ? _LinuxXattr.remove(path, attribute)
      : _LinuxXattr.set(path, attribute, utf8.encode([for (final t in tags) t.name.replaceAll(',', ' ')].join(',')));
}

/// macOS's `sys/xattr.h`: getxattr, setxattr and removexattr, which take a
/// position and options more than Linux's.
abstract final class _MacXattr {
  static final _lib = DynamicLibrary.process();

  static final _get = _lib.lookupFunction<
      IntPtr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, Size, Uint32, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, int, int, int)>('getxattr');

  static final _set = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, Size, Uint32, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, int, int, int)>('setxattr');

  static final _remove = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, int)>('removexattr');

  static Uint8List? get(String path, String name) => using((arena) {
        final p = path.toNativeUtf8(allocator: arena);
        final n = name.toNativeUtf8(allocator: arena);
        final size = _get(p, n, nullptr, 0, 0, 0);
        if (size <= 0) return null;
        final buffer = arena<Uint8>(size);
        final read = _get(p, n, buffer.cast(), size, 0, 0);
        return read <= 0 ? null : Uint8List.fromList(buffer.asTypedList(read));
      });

  static bool set(String path, String name, List<int> value) => using((arena) {
        final buffer = arena<Uint8>(value.isEmpty ? 1 : value.length);
        buffer.asTypedList(value.length).setAll(0, value);
        return _set(path.toNativeUtf8(allocator: arena), name.toNativeUtf8(allocator: arena), buffer.cast(), value.length, 0, 0) == 0;
      });

  /// True also when there was nothing to remove.
  static bool remove(String path, String name) => using((arena) {
        final p = path.toNativeUtf8(allocator: arena);
        final n = name.toNativeUtf8(allocator: arena);
        if (_get(p, n, nullptr, 0, 0, 0) < 0) return true;
        return _remove(p, n, 0) == 0;
      });
}

/// Linux's `sys/xattr.h`.
abstract final class _LinuxXattr {
  static final _lib = DynamicLibrary.process();

  static final _get = _lib.lookupFunction<
      IntPtr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, Size),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, int)>('getxattr');

  static final _set = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, Size, Int32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>, int, int)>('setxattr');

  static final _remove = _lib.lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)>('removexattr');

  static Uint8List? get(String path, String name) => using((arena) {
        final p = path.toNativeUtf8(allocator: arena);
        final n = name.toNativeUtf8(allocator: arena);
        final size = _get(p, n, nullptr, 0);
        if (size <= 0) return null;
        final buffer = arena<Uint8>(size);
        final read = _get(p, n, buffer.cast(), size);
        return read <= 0 ? null : Uint8List.fromList(buffer.asTypedList(read));
      });

  static bool set(String path, String name, List<int> value) => using((arena) {
        final buffer = arena<Uint8>(value.isEmpty ? 1 : value.length);
        buffer.asTypedList(value.length).setAll(0, value);
        return _set(path.toNativeUtf8(allocator: arena), name.toNativeUtf8(allocator: arena), buffer.cast(), value.length, 0) == 0;
      });

  static bool remove(String path, String name) => using((arena) {
        final p = path.toNativeUtf8(allocator: arena);
        final n = name.toNativeUtf8(allocator: arena);
        if (_get(p, n, nullptr, 0) < 0) return true;
        return _remove(p, n) == 0;
      });
}
