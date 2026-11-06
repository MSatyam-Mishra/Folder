@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folders/core/services/bluetooth_share.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Share > Bluetooth on macOS goes through Bluetooth File Exchange.
void main() {
  test('macOS offers Bluetooth through Bluetooth File Exchange', () {
    expect(BluetoothShare.available, isTrue);
    final app = BluetoothShare.tool!;
    expect(p.basename(app), 'Bluetooth File Exchange.app');
    expect(Directory(app).existsSync(), isTrue);
  });
}
