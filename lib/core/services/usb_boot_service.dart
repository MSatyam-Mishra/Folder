import 'dart:convert';
import 'dart:io';
import 'package:folders/core/services/root_service.dart';

class BlockDevice {
  final String path;
  final String name;
  final int sizeBytes;
  final String model;

  BlockDevice({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.model = 'Unknown',
  });

  String get sizeHumanReadable {
    final kb = sizeBytes / 1024;
    final mb = kb / 1024;
    final gb = mb / 1024;
    if (gb >= 1) return '${gb.toStringAsFixed(2)} GB';
    if (mb >= 1) return '${mb.toStringAsFixed(2)} MB';
    return '${kb.toStringAsFixed(2)} KB';
  }
}

class UsbBootService {
  final RootService _rootService;

  UsbBootService({RootService? rootService})
    : _rootService = rootService ?? RootService();

  /// Lists available block devices, filtering out internal storage if possible.
  /// This is a heuristic-based approach and requires Root.
  Future<List<BlockDevice>> getConnectableDevices() async {
    final devices = <BlockDevice>[];

    // Method 1: Try using lsblk (JSON output if available is best, but standard is safer across busybox versions)
    // We'll stick to parsing /proc/partitions as it's the most standard on Android/Linux.
    try {
      final result = await _rootService.runRootCommand('cat /proc/partitions');
      if (result.exitCode != 0) return [];

      final lines = LineSplitter.split(result.stdout.toString());

      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 4) continue;
        if (parts[0] == 'major') continue; // Header

        final blocks = int.tryParse(parts[2]) ?? 0;
        final name = parts[3];

        // Filter:
        // Exclude 'mmcblk0' (usually internal storage on phones)
        // Exclude 'dm-*' (device mapper)
        // Exclude 'loop*' (loopback)
        // Exclude 'zram*' (compressed RAM)
        // Exclude partitions (e.g., sda1), only show base disks (sda)?
        // Actually, valid to write to partition? No, usually write ISO to WHOLE disk (sda).
        // But let's show sda, sdb, etc.

        // Android OTG often shows as 'sda', 'sdb', or 'sg*'.
        if (name.startsWith('mmcblk')) continue;
        if (name.startsWith('dm-')) continue;
        if (name.startsWith('loop')) continue;
        if (name.startsWith('zram')) continue;
        // Also exclude partitions (ending in digits) if we want raw disk writing
        // e.g. 'sda' is disk, 'sda1' is partition.
        // Regex: ends with digit?
        // if (RegExp(r'\d$').hasMatch(name)) continue;
        // Wait, on some systems 'sda' might not be listed if only partitions are active?
        // Usually /proc/partitions lists both.
        // Let's stick to devices that look like 'sd[a-z]'

        if (!name.startsWith('sd'))
          continue; // Strictly safe? Maybe too strict.
        // Some OTG might be vold...

        // Let's trust 'sd*' for now as standard USB Mass Storage.
        // Also check if it is a whole disk (no digit at end) logic?
        // sda, sdb...
        final isPartition = RegExp(r'\d+$').hasMatch(name);
        if (isPartition) continue;

        devices.add(
          BlockDevice(
            path: '/dev/block/$name',
            name: name,
            sizeBytes: blocks * 1024,
          ),
        );
      }
    } catch (e) {
      print("Error listing devices: $e");
    }
    return devices;
  }

  /// Writes ISO to the target device using 'dd'.
  /// Returns a Process to allow monitoring/killing.
  /// The caller should listen to stdout/stderr.
  Future<Process> flashIsoToDevice(String isoPath, String devicePath) async {
    // Command: dd if=ISO of=DEVICE bs=4M status=progress
    // Note: status=progress might not be supported in all toybox/busybox versions of dd.
    // If not, we won't get progress updates.
    // We'll calculate progress manually if necessary by polling size? No, too complex.
    // Just try status=progress.

    final cmd = "dd if='$isoPath' of='$devicePath' bs=4M status=progress";
    return _rootService.startRootCommand(cmd);
  }
}
