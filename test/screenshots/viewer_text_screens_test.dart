import 'dart:io';

import 'package:folder/features/viewer_hex/screens/hex_viewer_screen.dart';
import 'package:folder/features/viewer_text/screens/tabbed_text_editor.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'viewer_shot_helpers.dart';

const _dart = '''
import 'dart:math' as math;

/// A point in 2D space.
class Point {
  const Point(this.x, this.y);

  final double x;
  final double y;

  // Distance to [other], in the same units.
  double distanceTo(Point other) {
    final dx = x - other.x, dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  String toString() => 'Point(\$x, \$y)';
}

void main() {
  const origin = Point(0, 0);
  final points = [for (var i = 0; i < 10; i++) Point(i * 1.5, i * 0.5)];
  for (final point in points) {
    print('\${point} is \${point.distanceTo(origin)} away');
  }
  if (points.isEmpty) throw StateError("no points");
}
''';

const _markdown = '''
# Release notes

Version **1.0.1** brings a *smaller* download and an optional video
downloader. See [the changelog](CHANGELOG.md).

## Highlights

- Split APKs per ABI
- `yt-dlp` updates in the background
- Faster archive listing

> Tip: long-press a file to select it.

```dart
void main() => print('hello');
```
''';

/// Picks [file] when the editor asks for another file.
class _FakePicker extends FilePicker {
  _FakePicker(this.file);

  final File file;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([
        PlatformFile(
          path: file.path,
          name: p.basename(file.path),
          size: file.lengthSync(),
        ),
      ]);
}

void main() {
  late Directory dir;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    dir = await Directory.systemTemp.createTemp('viewer_text_shots_');
    await File(p.join(dir.path, 'point.dart')).writeAsString(_dart);
    await File(p.join(dir.path, 'RELEASE.md')).writeAsString(_markdown);
    await File(p.join(dir.path, 'settings.json')).writeAsString(
      '{"theme": "dark", "fontSize": 14, "tabs": [1, 2, 3], "wrap": true}',
    );
    final big = StringBuffer();
    for (var i = 0; i < 9000; i++) {
      big.writeln('2026-10-21 12:${(i ~/ 60 % 60).toString().padLeft(2, '0')}:'
          '${(i % 60).toString().padLeft(2, '0')} INFO request $i served in '
          '${(i * 7) % 300} ms');
    }
    await File(p.join(dir.path, 'server.log')).writeAsString(big.toString());
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await dir.delete(recursive: true);
  });

  viewerShots('code editor', (tester, shot) async {
    FilePicker.platform = _FakePicker(File(p.join(dir.path, 'settings.json')));
    await shot.open(TabbedTextEditorScreen(
      initialFile: File(p.join(dir.path, 'point.dart')),
    ));
    await settle(tester);
    // Put the cursor on a line (current-line highlight).
    await tester.tapAt(tester.getTopLeft(find.byType(EditableText)) +
        const Offset(120, 200));
    await settle(tester);
    await shot.shot('editor_code');

    await tester.tap(find.byTooltip('Find and replace'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), 'point');
    await settle(tester);
    await shot.shot('editor_find');

    await tester.tap(find.byTooltip('Open another file'));
    await settle(tester, rounds: 12);
    await shot.shot('editor_tabs');
  });

  viewerShots('markdown editor', (tester, shot) async {
    await shot.open(TabbedTextEditorScreen(
      initialFile: File(p.join(dir.path, 'RELEASE.md')),
    ));
    await settle(tester);
    await shot.shot('editor_markdown');
  });

  viewerShots('large text', (tester, shot) async {
    await shot.open(TabbedTextEditorScreen(
      initialFile: File(p.join(dir.path, 'server.log')),
    ));
    await settle(tester, rounds: 10);
    await shot.shot('editor_large');
  });

  viewerShots('hex viewer', (tester, shot) async {
    await shot.open(HexViewerScreen(file: File(p.join(dir.path, 'point.dart'))));
    await settle(tester);
    await shot.shot('hex');
  });
}
