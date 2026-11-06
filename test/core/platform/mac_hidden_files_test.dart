@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/features/file_explorere/bloc/folder_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('what Finder hides is hidden, in listings and in search', () async {
    final home = Platform.environment['HOME']!;
    expect(LocalFileRepository.isHidden(p.join(home, 'Library')), isTrue);
    expect(LocalFileRepository.isHidden('/usr'), isTrue);
    expect(LocalFileRepository.isHidden(p.join(home, 'Desktop')), isFalse);

    final root = await Directory.systemTemp.createTemp('explorer_mac_hidden');
    addTearDown(() => root.delete(recursive: true));
    for (final path in ['Work/report.pdf', 'Secret/report.txt', '.cache/report.tmp']) {
      await File(p.join(root.path, path)).create(recursive: true);
    }
    final secret = p.join(root.path, 'Secret');
    expect((await Process.run('chflags', ['hidden', secret])).exitCode, 0);
    expect(LocalFileRepository.isHidden(secret), isTrue);
    expect(LocalFileRepository.isHidden(p.join(root.path, 'Work')), isFalse);

    Future<List<String>> search({required bool showHidden}) async => [
          await for (final batch in searchSubfolders(root.path, 'report', showHidden: showHidden))
            for (final e in batch) p.relative(e.path, from: root.path),
        ];
    expect(await search(showHidden: false), ['Work/report.pdf']);
    expect(await search(showHidden: true), containsAll(['Work/report.pdf', 'Secret/report.txt', '.cache/report.tmp']));
  });
}
