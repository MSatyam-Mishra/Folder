@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folder/core/platform/macos_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('reads the hidden flag and the volume, and copies permissions', () {
    final home = Platform.environment['HOME']!;
    expect(MacosFiles.isHidden(p.join(home, 'Library')), isTrue);
    expect(MacosFiles.isHidden(p.join(home, 'Desktop')), isFalse);
    expect(MacosFiles.isHidden('/usr'), isTrue);
    expect(MacosFiles.sameVolume(home, Directory.systemTemp.path), isNotNull);
    expect(MacosFiles.volumeOf('/no/such/path'), isNull);

    final dir = Directory.systemTemp.createTempSync('macos_files');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = File(p.join(dir.path, 'run.sh'))..writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['755', src.path]);
    final dst = File(p.join(dir.path, 'copy.sh'))..writeAsStringSync('#!/bin/sh\n');
    expect(dst.statSync().mode & 0x1ff, isNot(0x1ed));
    expect(MacosFiles.copyMetadata(src.path, dst.path), isTrue);
    expect(dst.statSync().mode & 0x1ff, 0x1ed);
  });
}
