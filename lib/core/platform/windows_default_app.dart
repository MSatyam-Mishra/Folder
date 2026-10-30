import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Which program Windows opens a file type with.
abstract final class WindowsDefaultApp {
  static final _assocQueryString = Platform.isWindows
      ? DynamicLibrary.open('shlwapi.dll').lookupFunction<
          Int32 Function(Uint32, Uint32, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>),
          int Function(int, int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Uint32>)>('AssocQueryStringW')
      : null;

  static const _assocfInitIgnoreUnknown = 0x400;
  static const _assocstrExecutable = 2;

  /// The program [path]'s type opens with, or null when there's none.
  static String? executableFor(String path) {
    final query = _assocQueryString;
    final extension = p.extension(path);
    if (query == null || extension.isEmpty) return null;
    return using((arena) {
      final size = arena<Uint32>()..value = 1024;
      final out = arena<Uint16>(1024).cast<Utf16>();
      final result = query(
        _assocfInitIgnoreUnknown,
        _assocstrExecutable,
        extension.toNativeUtf16(allocator: arena),
        'open'.toNativeUtf16(allocator: arena),
        out,
        size,
      );
      return result == 0 ? out.toDartString() : null;
    });
  }

  /// Whether [path]'s type opens with this app: handing it to Windows
  /// would only start Explorer again.
  static bool isThisApp(String path) {
    final exe = executableFor(path);
    return exe != null && p.equals(p.normalize(exe), p.normalize(Platform.resolvedExecutable));
  }

  /// Windows' own "How do you want to open this file?" dialog.
  static Future<void> chooseApp(String path) =>
      Process.start('rundll32.exe', ['shell32.dll,OpenAs_RunDLL', path], mode: ProcessStartMode.detached);
}
