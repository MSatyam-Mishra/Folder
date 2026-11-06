import 'package:folders/shared/widgets/main_drawer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the sidebar lists from /Volumes on macOS.
void main() {
  test('hidden and system entries in /Volumes are not listed as drives', () {
    for (final name in ['USB STICK', 'Backup', 'Install macOS', 'my.disk']) {
      expect(isListedMacVolume(name), isTrue, reason: name);
    }
    for (final name in [
      '.timemachine',
      '.DS_Store',
      'com.apple.TimeMachine.localsnapshots',
    ]) {
      expect(isListedMacVolume(name), isFalse, reason: name);
    }
  });
}
