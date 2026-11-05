import 'dart:convert';
import 'dart:io';

import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/platform/windows_default_app.dart';
import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/features/viewer_3d/screens/blend_viewer_screen.dart';
import 'package:explorer/features/viewer_3d/screens/three_d_viewer_screen.dart';
import 'package:explorer/features/viewer_archive/screens/archive_viewer_screen.dart';
import 'package:explorer/features/viewer_comic/screens/comic_viewer.dart';
import 'package:explorer/features/viewer_design/screens/design_preview_screen.dart';
import 'package:explorer/features/viewer_epub/screens/epub_viewer_screen.dart';
import 'package:explorer/features/viewer_font/screens/font_viewer_screen.dart';
import 'package:explorer/features/viewer_hex/screens/hex_viewer_screen.dart';
import 'package:explorer/features/viewer_html/screens/html_viewer_screen.dart';
import 'package:explorer/features/viewer_image/screens/viewer_image_screen.dart';
import 'package:explorer/features/viewer_media/screens/audio_player_screen.dart';
import 'package:explorer/features/video_player/video_player_page.dart';
import 'package:explorer/features/viewer_office/screens/ppt_viewer_screen.dart';
import 'package:explorer/features/viewer_office/screens/word_viewer_screen.dart';
import 'package:explorer/features/viewer_pdf/screens/viewer_pdf_screen.dart';
import 'package:explorer/features/viewer_sheets/screens/spreadsheet_screen.dart';
import 'package:explorer/features/viewer_text/screens/tabbed_text_editor.dart';
import 'package:explorer/features/viewer_text/text_document.dart';
import 'package:explorer/features/viewer_vector/screens/lottie_viewer_screen.dart';
import 'package:explorer/features/viewer_vector/screens/rive_viewer_screen.dart';
import 'package:explorer/features/viewer_vector/screens/svg_viewer_screen.dart';
import 'package:explorer/shared/ui/app_sheet.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Routes a file to the in-app viewer/editor for its type.
///
/// Returns true when the viewer changed the folder contents (e.g. saved a
/// copy) so the explorer should refresh.
class FileOpener {
  ///
  /// With [allowExternal] false (a file another app sent us), types without
  /// an in-app viewer are never handed to another app, which could be the
  /// sender and bounce the file straight back.
  static Future<bool?> open(
    BuildContext context,
    File file, {
    bool allowExternal = true,
  }) async {
    final kind = await _refineKind(file, FileTypes.kindOf(file.path));
    if (!context.mounted) return null;
    if (kind == FileKind.unknown ||
        (!allowExternal && _screenFor(file, kind) == null)) {
      return showOpenWith(context, file, allowExternal: allowExternal);
    }
    return openAs(context, file, kind, allowExternal: allowExternal);
  }

  /// Opens [file] with the viewer for [kind], regardless of its extension.
  static Future<bool?> openAs(
    BuildContext context,
    File file,
    FileKind kind, {
    bool allowExternal = true,
  }) async {
    final screen = _screenFor(file, kind);
    if (screen == null) {
      if (allowExternal) {
        await openExternally(context, file);
      } else if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Explorer can't open ${p.basename(file.path)}"),
        ));
      }
      return null;
    }
    return Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  static Widget? _screenFor(File file, FileKind kind) {
    return switch (kind) {
      FileKind.image || FileKind.rasterImage => ImageViewerScreen(imageFile: file),
      FileKind.svg => SvgViewerScreen(filePath: file.path),
      // Without its libmpv a Mac has no player here, and uses another app.
      FileKind.video when Platform.isMacOS && !Desktop.macMediaKit => null,
      FileKind.video => VideoPlayerPage(playlist: [file.path], withFolder: true),
      FileKind.audio => AudioPlayerScreen(audioFile: file),
      FileKind.pdf => PdfViewerScreen(pdfFile: file),
      FileKind.epub || FileKind.ebook => EpubViewerScreen(epubFile: file),
      FileKind.comic => ComicViewerScreen(comicFile: file),
      FileKind.word ||
      FileKind.legacyWord ||
      FileKind.richText ||
      FileKind.openDocumentText =>
        WordViewerScreen(file: file),
      FileKind.spreadsheet ||
      FileKind.legacySpreadsheet ||
      FileKind.delimited ||
      FileKind.openDocumentSpreadsheet =>
        SpreadsheetScreen(file: file),
      FileKind.presentation ||
      FileKind.legacyPresentation ||
      FileKind.openDocumentPresentation =>
        PptViewerScreen(file: file),
      FileKind.model3d => const {'blend', 'blend1'}.contains(
              FileTypes.extensionOf(file.path),
            )
          ? BlendViewerScreen(file: file)
          : ThreeDViewerScreen(file: file),
      FileKind.archive ||
      FileKind.diskImage =>
        ArchiveViewerScreen(archiveFile: file),
      FileKind.cameraRaw => ImageViewerScreen(imageFile: file),
      FileKind.design => DesignPreviewScreen(file: file),
      FileKind.html => HtmlViewerScreen(file: file),
      FileKind.lottie => LottieViewerScreen(file: file),
      FileKind.rive => RiveViewerScreen(riveFile: file),
      FileKind.font => FontViewerScreen(file: file),
      FileKind.markdown ||
      FileKind.json ||
      FileKind.code ||
      FileKind.text =>
        TabbedTextEditorScreen(initialFile: file),
      FileKind.package => null,
      FileKind.unknown => HexViewerScreen(file: file),
    };
  }

  /// Uses file contents to resolve ambiguous extensions.
  static Future<FileKind> _refineKind(File file, FileKind kind) async {
    final ext = FileTypes.extensionOf(file.path);
    final needsSniff =
        kind == FileKind.unknown || kind == FileKind.json || ext == 'ts';
    if (!needsSniff) return kind;
    try {
      final head = await readHead(file, 64 * 1024);
      if (ext == 'ts') {
        // MPEG transport streams sync on 0x47 every 188 bytes.
        final isVideo = head.length > 376 &&
            head[0] == 0x47 &&
            head[188] == 0x47 &&
            head[376] == 0x47;
        return isVideo ? FileKind.video : FileKind.code;
      }
      if (kind == FileKind.json) {
        final text = utf8.decode(head, allowMalformed: true);
        final isLottie = RegExp(r'"v"\s*:\s*"\d').hasMatch(text) &&
            text.contains('"layers"') &&
            text.contains('"fr"');
        return isLottie ? FileKind.lottie : FileKind.json;
      }
      return looksLikeText(head) ? FileKind.text : FileKind.unknown;
    } catch (_) {
      return kind;
    }
  }

  static Future<void> openExternally(BuildContext context, File file) async {
    // Windows: when Explorer is the type's default app, handing the file
    // over would start Explorer again; Windows asks for an app instead.
    if (Platform.isWindows && WindowsDefaultApp.isThisApp(file.path)) {
      await WindowsDefaultApp.chooseApp(file.path);
      return;
    }
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No app found to open ${p.basename(file.path)}')),
      );
    }
  }

  /// Lets the user pick how to open [file].
  static Future<bool?> showOpenWith(
    BuildContext context,
    File file, {
    bool allowExternal = true,
  }) async {
    final kind = FileTypes.kindOf(file.path);
    final options = <(IconData, String, FileKind?)>[
      if (kind != FileKind.unknown && _screenFor(file, kind) != null)
        (LucideIcons.sparkles, 'Default viewer (${FileTypes.describe(kind)})', kind),
      (LucideIcons.squarePen, 'Text editor', FileKind.text),
      (LucideIcons.binary, 'Hex viewer', FileKind.unknown),
      (LucideIcons.image, 'Image viewer', FileKind.image),
      (LucideIcons.box, '3D viewer', FileKind.model3d),
      (LucideIcons.archive, 'Archive viewer', FileKind.archive),
      (LucideIcons.play, 'Media player', FileKind.video),
      if (allowExternal) (LucideIcons.externalLink, 'Another app', null),
    ];
    Widget chooser(BuildContext sheetContext) => ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Open "${p.basename(file.path)}" with',
                style: Theme.of(sheetContext).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            for (final option in options)
              ListTile(
                leading: Icon(option.$1),
                title: Text(option.$2),
                onTap: () => Navigator.pop(sheetContext, option),
              ),
          ],
        );
    final choice = AppSheet.usesBottomSheet(context)
        ? await showModalBottomSheet<(IconData, String, FileKind?)>(
            context: context,
            showDragHandle: true,
            builder: (sheetContext) => SafeArea(child: chooser(sheetContext)),
          )
        : await AppSheet.showRaw<(IconData, String, FileKind?)>(context, builder: chooser);
    if (choice == null || !context.mounted) return null;
    final target = choice.$3;
    if (target == null) {
      await openExternally(context, file);
      return null;
    }
    return openAs(context, file, target, allowExternal: allowExternal);
  }
}
