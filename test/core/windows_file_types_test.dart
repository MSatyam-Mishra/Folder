import 'dart:io';

import 'package:explorer/core/files/file_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// packaging/windows/file-types.txt lists the types the Windows installer
/// and the MSIX register Explorer for (Open with, Default apps): all the
/// ones a viewer opens, less what Windows runs or keeps for itself.
void main() {
  test('the Windows file types are the ones Explorer opens', () {
    // Programs, scripts Windows runs, shortcuts and certificates: Windows
    // keeps these (an MSIX can't take them), and Explorer still turns up
    // for them through "Choose another app".
    const reserved = {
      'exe', 'msi', 'appx', 'bat', 'cmd', 'reg', 'vbs', 'ps1', 'js', 'url',
      'crt', 'pcd',
    };
    final expected = {
      for (final group in [
        FileTypes.image, FileTypes.rasterImage, FileTypes.svg,
        FileTypes.video, FileTypes.audio, FileTypes.pdf, FileTypes.epub,
        FileTypes.ebook, FileTypes.comic, FileTypes.word,
        FileTypes.legacyWord, FileTypes.richText, FileTypes.openDocumentText,
        FileTypes.spreadsheet, FileTypes.legacySpreadsheet,
        FileTypes.delimited, FileTypes.openDocumentSpreadsheet,
        FileTypes.presentation, FileTypes.legacyPresentation,
        FileTypes.openDocumentPresentation, FileTypes.model3d,
        FileTypes.archive, FileTypes.diskImage, FileTypes.cameraRaw,
        FileTypes.design, FileTypes.markdown, FileTypes.html, FileTypes.json,
        // Not FileTypes.package (.apk, .dmg...): Explorer has no viewer
        // for them and hands them to the default app, which with nothing
        // else for them would be Explorer again, without end.
        FileTypes.lottie, FileTypes.rive, FileTypes.font,
        FileTypes.code, FileTypes.text,
      ])
        ...group,
    }.difference(reserved).toList()
      ..sort();
    final listed = File('packaging/windows/file-types.txt')
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    expect(listed, expected,
        reason: 'packaging/windows/file-types.txt should list, one per line:\n${expected.join('\n')}');
    for (final type in listed) {
      expect(type, matches(RegExp(r'^[a-z0-9]+$')), reason: 'MSIX takes letters and digits');
    }
  });
}
