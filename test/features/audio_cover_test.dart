import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folders/features/panes/audio_cover.dart';
import 'package:folders/features/panes/folder_size.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The preview pane's song covers and folder sizes.
void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('explorer_cover'));
  tearDown(() => dir.delete(recursive: true));

  // Stands for a picture: what's read must be exactly these bytes.
  final picture = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 0xFF, 0xD9]);

  List<int> be32(int n) => [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
  List<int> syncsafe(int n) => [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

  Future<String> write(String name, List<int> bytes) async {
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  test('an MP3 with an ID3v2.3 picture', () async {
    final title = [...ascii.encode('TIT2'), ...be32(6), 0, 0, 0, ...ascii.encode('Song!')];
    final apicBody = [0, ...ascii.encode('image/jpeg'), 0, 3, ...ascii.encode('Front'), 0, ...picture];
    final apic = [...ascii.encode('APIC'), ...be32(apicBody.length), 0, 0, ...apicBody];
    final frames = [...title, ...apic, ...List.filled(16, 0)];
    final path = await write('song.mp3', [
      ...ascii.encode('ID3'), 3, 0, 0, ...syncsafe(frames.length), ...frames,
      ...List.filled(64, 0xAA), // audio
    ]);
    expect(await AudioCover.find(path), picture);
  });

  test('an MP3 with an ID3v2.4 picture described in UTF-16', () async {
    final description = [0xFF, 0xFE, 0x41, 0x00, 0x00, 0x00]; // BOM, "A", end
    final apicBody = [1, ...ascii.encode('image/png'), 0, 3, ...description, ...picture];
    final apic = [...ascii.encode('APIC'), ...syncsafe(apicBody.length), 0, 0, ...apicBody];
    final path = await write('song4.mp3', [
      ...ascii.encode('ID3'), 4, 0, 0, ...syncsafe(apic.length), ...apic,
    ]);
    expect(await AudioCover.find(path), picture);
  });

  test('a FLAC picture block', () async {
    final streamInfo = [0x00, ...[0, 0, 34], ...List.filled(34, 0)];
    final mime = ascii.encode('image/jpeg');
    final block = [
      ...be32(3), ...be32(mime.length), ...mime, ...be32(0),
      ...be32(1), ...be32(1), ...be32(24), ...be32(0), ...be32(picture.length), ...picture,
    ];
    final pictureBlock = [0x80 | 6, (block.length >> 16) & 0xFF, (block.length >> 8) & 0xFF, block.length & 0xFF, ...block];
    final path = await write('song.flac', [...ascii.encode('fLaC'), ...streamInfo, ...pictureBlock]);
    expect(await AudioCover.find(path), picture);
  });

  test("an M4A's covr", () async {
    List<int> box(String type, List<int> content) => [...be32(content.length + 8), ...ascii.encode(type), ...content];
    final data = box('data', [...be32(13), ...be32(0), ...picture]);
    final moov = box('moov', [
      ...box('mvhd', List.filled(20, 0)),
      ...box('udta', box('meta', [0, 0, 0, 0, ...box('hdlr', List.filled(25, 0)), ...box('ilst', box('covr', data))])),
    ]);
    final path = await write('song.m4a', [
      ...box('ftyp', [...ascii.encode('M4A '), ...be32(0)]),
      ...box('mdat', List.filled(40, 0x55)),
      ...moov,
    ]);
    expect(await AudioCover.find(path), picture);
  });

  test('a cover image beside a song without one', () async {
    final path = await write('plain.mp3', List.filled(128, 0xAA));
    await write('Folder.JPG', picture);
    expect(await AudioCover.find(path), picture);
  });

  test('no cover at all', () async {
    final path = await write('plain.wav', [...ascii.encode('RIFF'), ...List.filled(60, 0)]);
    expect(await AudioCover.find(path), isNull);
  });

  test('a folder is added up, folders inside too', () async {
    await Directory(p.join(dir.path, 'a', 'b')).create(recursive: true);
    await File(p.join(dir.path, 'a', 'one.bin')).writeAsBytes(List.filled(1000, 1));
    await File(p.join(dir.path, 'a', 'b', 'two.bin')).writeAsBytes(List.filled(24, 1));
    final last = await FolderSize.measure([p.join(dir.path, 'a')]).last;
    expect(last.done, isTrue);
    expect(last.bytes, 1024);
    expect(last.files, 2);
    expect(last.folders, 1);
  });

  test('a link to a folder is not followed', () async {
    final target = Directory(p.join(dir.path, 'big'));
    await target.create();
    await File(p.join(target.path, 'x.bin')).writeAsBytes(List.filled(5000, 1));
    final measured = Directory(p.join(dir.path, 'measured'));
    await measured.create();
    await File(p.join(measured.path, 'y.bin')).writeAsBytes(List.filled(10, 1));
    try {
      await Link(p.join(measured.path, 'shortcut')).create(target.path);
    } on FileSystemException {
      markTestSkipped("This system doesn't let a test make links");
      return;
    }
    final last = await FolderSize.measure([measured.path]).last;
    expect(last.bytes, 10);
    expect(last.files, 1);
  });
}
