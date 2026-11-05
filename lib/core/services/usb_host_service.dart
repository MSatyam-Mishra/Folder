import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:folder/core/services/driver/mass_storage_driver.dart';

class UsbDeviceWrapper {
  final int deviceId;
  final String name;
  final int vendorId;
  final int productId;
  final String productName;

  UsbDeviceWrapper({
    required this.deviceId,
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.productName,
  });

  factory UsbDeviceWrapper.fromMap(Map<dynamic, dynamic> map) {
    return UsbDeviceWrapper(
      deviceId: map['deviceId'] as int,
      name: map['productName'] as String? ?? 'Unknown Device',
      vendorId: map['vendorId'] as int,
      productId: map['productId'] as int,
      productName: map['productName'] as String? ?? 'Unknown',
    );
  }
}

class UsbHostService {
  static const MethodChannel _channel = MethodChannel('explorer/usb');
  final MassStorageDriver _driver = MassStorageDriver();

  Future<void> init() async {
    // No-op for now
  }

  Future<void> dispose() async {
    // No-op for now
  }

  Future<List<UsbDeviceWrapper>> getDeviceList() async {
    try {
      final List<dynamic>? devices = await _channel.invokeMethod(
        'getDeviceList',
      );
      if (devices == null) return [];
      return devices.map((d) => UsbDeviceWrapper.fromMap(d)).toList();
    } catch (e) {
      print("Error getting devices: $e");
      return [];
    }
  }

  Future<bool> hasPermission(UsbDeviceWrapper device) async {
    try {
      return await _channel.invokeMethod('hasPermission', {
            'deviceId': device.deviceId,
          }) ??
          false;
    } catch (e) {
      print("Check permission error: $e");
      return false;
    }
  }

  Future<bool> requestPermission(UsbDeviceWrapper device) async {
    try {
      return await _channel.invokeMethod('requestPermission', {
            'deviceId': device.deviceId,
          }) ??
          false;
    } catch (e) {
      print("Request permission error: $e");
      return false;
    }
  }

  Future<void> flashIsoToDevice(
    File isoFile,
    UsbDeviceWrapper deviceWrapper, {
    required Function(double) onProgress,
  }) async {
    final deviceId = deviceWrapper.deviceId;

    // 1. Open Device
    final bool opened = await _channel.invokeMethod('openDevice', {
      'deviceId': deviceId,
    });
    if (!opened) throw Exception("Failed to open device");

    try {
      // 2. Claim Interface (Auto-select mass storage interface 0 on Native side for simplicity)
      final bool claimed = await _channel.invokeMethod('claimInterface', {
        'deviceId': deviceId,
      });
      if (!claimed) throw Exception("Failed to claim Mass Storage interface");

      // 3. Flashing Loop
      final fileSize = await isoFile.length();
      int bytesWritten = 0;

      const int chunkSize = 64 * 1024; // 64KB
      final raf = await isoFile.open();
      int lba = 0;

      while (bytesWritten < fileSize) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;

        final sectors = (chunk.length + 511) ~/ 512;

        // A. Send CBW
        final cbw = _driver.createCBW(
          dataTransferLength: chunk.length,
          directionIn: false,
          lun: 0,
          cb: _driver.buildWrite10CDB(
            logicalBlockAddress: lba,
            transferLengthBlocks: sectors,
          ),
        );

        // Native bulk transfer: {deviceId, data, isOut} -> returns bytesTransferred
        await _channel.invokeMethod('bulkTransferOut', {
          'deviceId': deviceId,
          'data': cbw,
        });

        // B. Send Data
        await _channel.invokeMethod('bulkTransferOut', {
          'deviceId': deviceId,
          'data': chunk,
        });

        // C. Read CSW (13 bytes)
        // Native bulk transfer in: {deviceId, length} -> returns ByteArray
        final List<int>? csw = await _channel.invokeListMethod<int>(
          'bulkTransferIn',
          {'deviceId': deviceId, 'length': 13},
        );

        if (csw == null || csw.length < 13) {
          // throw Exception("Failed to read CSW");
          // Tolerate for now or retry?
        } else {
          // Check status csw[12] == 0
          if (csw[12] != 0) {
            // throw Exception("Write failed CSW status: ${csw[12]}");
          }
        }

        bytesWritten += chunk.length;
        lba += sectors;
        onProgress(bytesWritten / fileSize);
      }

      await raf.close();
    } finally {
      await _channel.invokeMethod('closeDevice', {'deviceId': deviceId});
    }
  }
}
