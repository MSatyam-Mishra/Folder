@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folder/features/clipboard/paste_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A copy on macOS keeps what Finder keeps: permissions, extended
/// attributes, folder times, and links as links.
void main() {
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('explorer_paste_macos_test'));
  tearDown(() => root.delete(recursive: true));

  int mode(String path) => FileStat.statSync(path).mode & 0x1ff;
  int octal(String digits) => int.parse(digits, radix: 8);
  Future<String> run(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    expect(result.exitCode, 0, reason: '$executable ${args.join(' ')}: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  test('a copied app keeps its executable, attributes and links', () async {
    final app = p.join(root.path, 'Tool.app');
    final binary = File(p.join(app, 'Contents', 'MacOS', 'tool'));
    await binary.create(recursive: true);
    await binary.writeAsString('#!/bin/sh\necho hi\n');
    await run('chmod', ['755', binary.path]);
    await run('xattr', ['-w', 'com.example.tag', 'red', binary.path]);
    await Link(p.join(app, 'Contents', 'Current')).create('MacOS');
    await run('chmod', ['700', app]);
    await run('touch', ['-t', '202001021230', app]);
    final destination = await Directory(p.join(root.path, 'Applications')).create();

    final targets = await pasteEntities([app], destination.path, move: false);
    final copy = targets.single;
    final copied = p.join(copy, 'Contents', 'MacOS', 'tool');

    expect(mode(copied), octal('755'));
    expect(await run('xattr', ['-p', 'com.example.tag', copied]), 'red');
    expect(await run(copied, []), 'hi');
    expect(mode(copy), octal('700'));
    expect(FileStat.statSync(copy).modified, FileStat.statSync(app).modified);
    expect(Link(p.join(copy, 'Contents', 'Current')).targetSync(), 'MacOS');
  });

  test('a read-only file stays read-only and keeps its time', () async {
    final notes = File(p.join(root.path, 'notes.txt'));
    await notes.writeAsString('notes');
    await run('touch', ['-t', '202001021230', notes.path]);
    await run('chmod', ['444', notes.path]);
    final destination = await Directory(p.join(root.path, 'b')).create();

    final copy = (await pasteEntities([notes.path], destination.path, move: false)).single;
    expect(mode(copy), octal('444'));
    expect(File(copy).lastModifiedSync(), notes.lastModifiedSync());
    expect(File(copy).readAsStringSync(), 'notes');
  });
}
