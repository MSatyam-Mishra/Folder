import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// How much memory the device has, in bytes.
class MemoryStats {
  const MemoryStats(this.total, this.available);

  final int total;
  final int available;

  int get used => total - available;
  double get usedFraction => total <= 0 ? 0 : (used / total).clamp(0.0, 1.0);
}

/// What the RAM cleaner did.
class RamCleanResult {
  const RamCleanResult({required this.others});

  /// How many other apps or processes it could ask to give memory back.
  final int others;
}

/// The device's memory, and giving some back in each system's own way: Windows
/// trims every process it may touch, Linux drops its file cache and macOS runs
/// `purge` (those two ask for the password), and older Android closes
/// background apps. Android 14 and newer don't let an app close others, so
/// there it's only what Explorer holds.
abstract final class RamCleaner {
  static const _channel = MethodChannel('explorer/device');

  /// Whether other apps' memory can be touched at all.
  static Future<bool> canCleanOthers() async {
    if (Platform.isWindows || Platform.isMacOS) return true;
    if (Platform.isLinux) {
      try {
        return (await Process.run('which', const ['pkexec'])).exitCode == 0;
      } on ProcessException {
        return false;
      }
    }
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canFreeMemory') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<MemoryStats?> read() async {
    try {
      if (Platform.isAndroid) {
        final info = await _channel.invokeMapMethod<String, int>('memoryInfo');
        return info == null ? null : MemoryStats(info['total'] ?? 0, info['available'] ?? 0);
      }
      if (Platform.isWindows) return await Isolate.run(_windowsStats);
      if (Platform.isLinux) return parseMeminfo(await File('/proc/meminfo').readAsString());
      if (Platform.isMacOS) {
        final size = await Process.run('sysctl', ['-n', 'hw.memsize']);
        final pages = await Process.run('vm_stat', const []);
        return parseVmStat(pages.stdout as String, int.parse((size.stdout as String).trim()));
      }
    } catch (e) {
      debugPrint('Memory info: $e');
    }
    return null;
  }

  static Future<RamCleanResult> clean() async {
    // Explorer's own first: decoded pictures are most of what it holds.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    var others = 0;
    try {
      if (Platform.isAndroid) {
        others = await _channel.invokeMethod<int>('freeMemory') ?? 0;
      } else if (Platform.isWindows) {
        others = await Isolate.run(_windowsTrim);
      } else if (Platform.isLinux) {
        // pkexec asks for the password; cancelling just leaves things as they are.
        final done = await Process.run('pkexec', const ['sh', '-c', 'sync; echo 3 > /proc/sys/vm/drop_caches']);
        others = done.exitCode == 0 ? 1 : 0;
      } else if (Platform.isMacOS) {
        final done = await Process.run('osascript', const ['-e', 'do shell script "purge" with administrator privileges']);
        others = done.exitCode == 0 ? 1 : 0;
      }
    } catch (e) {
      debugPrint('Freeing memory: $e');
    }
    return RamCleanResult(others: others);
  }

  /// Linux's /proc/meminfo, in kB.
  @visibleForTesting
  static MemoryStats? parseMeminfo(String text) {
    int? field(String name) {
      final match = RegExp('^$name:\\s+(\\d+) kB', multiLine: true).firstMatch(text);
      return match == null ? null : int.parse(match.group(1)!) * 1024;
    }

    final total = field('MemTotal');
    final available = field('MemAvailable') ?? field('MemFree');
    return total == null || available == null ? null : MemoryStats(total, available);
  }

  /// macOS's vm_stat: what's free or can be taken back at once.
  @visibleForTesting
  static MemoryStats? parseVmStat(String text, int total) {
    final page = int.tryParse(RegExp(r'page size of (\d+) bytes').firstMatch(text)?.group(1) ?? '');
    if (page == null) return null;
    int pages(String name) => int.tryParse(RegExp('$name:\\s+(\\d+)').firstMatch(text)?.group(1) ?? '') ?? 0;
    return MemoryStats(total, (pages('Pages free') + pages('Pages inactive') + pages('Pages speculative')) * page);
  }

  static MemoryStats _windowsStats() => using((arena) {
        final status = arena<MEMORYSTATUSEX>()..ref.dwLength = sizeOf<MEMORYSTATUSEX>();
        if (GlobalMemoryStatusEx(status) == 0) throw StateError('GlobalMemoryStatusEx failed');
        return MemoryStats(status.ref.ullTotalPhys, status.ref.ullAvailPhys);
      });

  static int _windowsTrim() => using((arena) {
        const capacity = 8192;
        final ids = arena<Uint32>(capacity);
        final written = arena<Uint32>();
        if (EnumProcesses(ids, capacity * sizeOf<Uint32>(), written) == 0) return 0;
        var trimmed = 0;
        for (var i = 0; i < written.value ~/ sizeOf<Uint32>(); i++) {
          final process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_SET_QUOTA, FALSE, ids[i]);
          if (process == 0) continue;
          if (EmptyWorkingSet(process) != 0) trimmed++;
          CloseHandle(process);
        }
        return trimmed;
      });
}
