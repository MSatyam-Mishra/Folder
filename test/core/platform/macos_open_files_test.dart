import 'dart:io';

import 'package:folder/core/platform/macos_open_files.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late String folder;
  late String file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('macos_open_files');
    folder = (Directory(p.join(dir.path, 'Photos'))..createSync()).path;
    file = (File(p.join(dir.path, 'notes.txt'))..writeAsStringSync('hi')).path;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('the first item Finder sent at launch is what the window shows', () {
    final missing = p.join(dir.path, 'gone.txt');
    final sent = MacosOpenFiles.sort(
      (folder: null, file: null),
      [missing, folder, file, folder, 'relative/notes.txt'],
    );
    expect(sent.launch, (folder: folder, file: null));
    expect(sent.others, [(folder: dir.path, file: file)]);

    final viewed = MacosOpenFiles.sort((folder: null, file: null), [file]);
    expect(viewed.launch, (folder: dir.path, file: file));
    expect(viewed.others, isEmpty);
  });

  test('the command line wins over what Finder sent', () {
    final sent = MacosOpenFiles.sort(
      (folder: dir.path, file: file),
      [file, folder],
    );
    expect(sent.launch, (folder: dir.path, file: file));
    expect(sent.others, isEmpty);

    final none = MacosOpenFiles.sort(
      (folder: null, file: null),
      [p.join(dir.path, 'gone')],
    );
    expect(none.launch, (folder: null, file: null));
    expect(none.others, isEmpty);
  });

  test('items sent while the app runs open in new windows', () async {
    final opened = <({String? folder, String? file})>[];
    final previous = MacosOpenFiles.openWindow;
    MacosOpenFiles.openWindow = ({String? folder, String? file}) async =>
        opened.add((folder: folder, file: file));
    addTearDown(() => MacosOpenFiles.openWindow = previous);

    await MacosOpenFiles.handleCall(
      MethodCall('open', {
        'paths': [file, folder, p.join(dir.path, 'gone')],
      }),
    );
    expect(opened, [
      (folder: dir.path, file: file),
      (folder: folder, file: null),
    ]);

    opened.clear();
    await MacosOpenFiles.handleCall(MethodCall('other', {'paths': [file]}));
    await MacosOpenFiles.handleCall(const MethodCall('open', 'bad'));
    expect(opened, isEmpty);
  });

  test('does nothing in widget tests', () async {
    expect(MacosOpenFiles.supported, isFalse);
    expect(await MacosOpenFiles.takeInitial(), isEmpty);
    expect(
      await MacosOpenFiles.launchTarget((folder: null, file: null)),
      (folder: null, file: null),
    );
  });
}
