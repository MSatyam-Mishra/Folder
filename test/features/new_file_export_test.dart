import 'dart:io';

import 'package:explorer/core/services/new_files.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Temporary: writes every blank file for checking with real document readers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export', () async {
    final out = Platform.environment['NEW_FILES_OUT'];
    if (out == null) return;
    await Directory(out).create(recursive: true);
    for (final kind in NewFiles.kinds) {
      await File(p.join(out, 'blank.${kind.extension}')).writeAsBytes(await NewFiles.contents(kind));
    }
  });
}
