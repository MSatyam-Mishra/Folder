import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:folders/features/viewer_archive/screens/archive_viewer_screen.dart';
import 'package:folders/features/viewer_comic/screens/comic_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'viewer_shot_helpers.dart';

List<int> _page(int n) {
  final image = img.Image(width: 600, height: 900);
  img.fill(image, color: img.ColorRgb8(250, 246, 236));
  // Panels.
  for (final (x, y, w, h) in [
    (30, 30, 540, 380),
    (30, 440, 255, 420),
    (315, 440, 255, 420),
  ]) {
    img.fillRect(image,
        x1: x, y1: y, x2: x + w, y2: y + h,
        color: img.ColorRgb8(60 + n * 40 % 160, 120, 200 - n * 30 % 120));
    img.drawRect(image,
        x1: x, y1: y, x2: x + w, y2: y + h,
        color: img.ColorRgb8(20, 20, 20), thickness: 6);
  }
  return img.encodePng(image);
}

void main() {
  late Directory dir;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    dir = await Directory.systemTemp.createTemp('viewer_archive_shots_');
    final zip = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      zip.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('Project/README.md', '# Project\n' * 40);
    add('Project/src/main.dart', 'void main() {}\n' * 200);
    add('Project/src/app.dart', 'class App {}\n' * 120);
    add('Project/assets/logo.svg', '<svg/>' * 50);
    add('Project/pubspec.yaml', 'name: project\n' * 10);
    add('Photos/IMG_0001.jpg', 'x' * 40000);
    add('Photos/IMG_0002.jpg', 'x' * 52000);
    add('Budget 2026.xlsx', 'x' * 18000);
    add('Notes.txt', 'Remember the milk.\n' * 30);
    add('Slides.pptx', 'x' * 90000);
    await File(p.join(dir.path, 'Backup.zip'))
        .writeAsBytes(ZipEncoder().encode(zip)!);

    final cbz = Archive();
    for (var i = 1; i <= 6; i++) {
      final bytes = _page(i);
      cbz.addFile(ArchiveFile('page${i.toString().padLeft(2, '0')}.png',
          bytes.length, bytes));
    }
    await File(p.join(dir.path, 'Adventure #1.cbz'))
        .writeAsBytes(ZipEncoder().encode(cbz)!);
  });

  tearDownAll(() async {
    // The archive reader may still hold the file open.
    if (screenshotsEnabled) await dir.delete(recursive: true).catchError((_) => dir);
  });

  viewerShots('archive viewer', (tester, shot) async {
    await shot.open(
      ArchiveViewerScreen(archiveFile: File(p.join(dir.path, 'Backup.zip'))),
    );
    await settle(tester, rounds: 12);
    await shot.shot('archive_root');

    await tester.tap(find.text('Project'));
    await settle(tester);
    await tester.longPress(find.text('README.md'));
    await settle(tester);
    await shot.shot('archive_selection');
    await tester.tap(find.byTooltip('Clear selection'));
    await settle(tester);

    await tester.tap(find.byTooltip('Extract all'));
    await settle(tester, rounds: 10);
    await shot.shot('archive_extract_sheet');
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    await tester.tap(find.byTooltip('Search in archive'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'dart');
    await settle(tester);
    await shot.shot('archive_search');
  });

  viewerShots('comic viewer', (tester, shot) async {
    await shot.open(
      ComicViewerScreen(comicFile: File(p.join(dir.path, 'Adventure #1.cbz'))),
    );
    await settle(tester, rounds: 14);
    await shot.shot('comic');
  });
}
