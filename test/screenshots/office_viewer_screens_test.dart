import 'dart:io';

import 'package:folders/features/viewer_office/common/office_files.dart';
import 'package:folders/features/viewer_office/screens/ppt_viewer_screen.dart';
import 'package:folders/features/viewer_office/screens/word_viewer_screen.dart';
import 'package:folders/features/viewer_office/slides/widgets/slide_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'doc_viewer_harness.dart';
import 'office_samples.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/office_viewer_screens_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File docx;
  late File pptx;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    await loadDocumentFontAliases();
    dir = await sampleDir('office');
    docx = File(p.join(dir.path, 'Quarterly report.docx'));
    await docx.writeAsBytes(sampleDocx());
    pptx = File(p.join(dir.path, 'Quarterly review.pptx'));
    await pptx.writeAsBytes(samplePptx());
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await dir.delete(recursive: true);
  });

  for (final (mode, device, size) in shotVariants) {
    final tag = '${mode.name}_$device';
    final phone = device == 'phone';

    testWidgets('word $tag', (tester) async {
      await pumpViewer(tester, WordViewerScreen(file: docx), mode: mode, size: size);
      await settleUntil(tester, find.byTooltip('Edit'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'word_read_$tag');

      await tester.tap(find.byTooltip('More options'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'word_menu_$tag');
      await dismissTop(tester);

      await tester.tap(find.byTooltip('Find'));
      await settle(tester, rounds: 3);
      await tester.enterText(find.byType(TextField).first, 'revenue');
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'word_find_$tag');
      await tester.tap(find.byTooltip('Close search'));
      await settle(tester, rounds: 3);

      if (phone) {
        final state = tester.state(find.byType(WordViewerScreen));
        // Outline sheet and info sheet via the menu.
        await tester.tap(find.byTooltip('More options'));
        await settle(tester, rounds: 6);
        await tester.tap(find.text('Outline'));
        await settle(tester, rounds: 6);
        await saveScreenshot(tester, 'word_outline_$tag');
        await dismissTop(tester);
        await tester.tap(find.byTooltip('More options'));
        await settle(tester, rounds: 6);
        await tester.tap(find.text('Document info'));
        await settle(tester, rounds: 6);
        await saveScreenshot(tester, 'word_info_$tag');
        await dismissTop(tester);
        await tester.tap(find.byTooltip('More options'));
        await settle(tester, rounds: 6);
        await tester.tap(find.text('Dark page'));
        await settle(tester, rounds: 10);
        await saveScreenshot(tester, 'word_darkpage_$tag');
        await tester.tap(find.byTooltip('More options'));
        await settle(tester, rounds: 6);
        await tester.tap(find.text('Print layout'));
        await settle(tester, rounds: 10);
        await saveScreenshot(tester, 'word_reflow_$tag');
        askUnsavedChanges(state.context, saveLabel: 'Save');
        await settle(tester, rounds: 3);
        await saveScreenshot(tester, 'word_unsaved_$tag');
        await dismissTop(tester);
        showLinkSheet(state.context, 'https://example.com/annual-report');
        await settle(tester, rounds: 4);
        await saveScreenshot(tester, 'word_link_$tag');
        await dismissTop(tester);
      }

      await tester.tap(find.byTooltip('Edit'));
      await settle(tester, rounds: 8);
      await tester.tap(find.byType(QuillEditor).first);
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'word_edit_$tag');
      await finish(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('slides $tag', (tester) async {
      await pumpViewer(tester, PptViewerScreen(file: pptx), mode: mode, size: size);
      await settleUntil(tester, find.byTooltip('Present'));
      await settle(tester, rounds: 8);
      await saveScreenshot(tester, 'slides_read_$tag');

      await tester.tap(find.byTooltip('More options'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'slides_menu_$tag');
      await dismissTop(tester);

      await tester.tap(find.byTooltip('Show notes'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'slides_notes_$tag');
      await tester.tap(find.byTooltip('Hide notes'));
      await settle(tester, rounds: 3);

      await tester.tap(find.byTooltip('Edit'));
      await settleUntil(tester, find.byTooltip('Done'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'slides_edit_$tag');

      if (phone) {
        final ctx = tester.element(find.byType(PptViewerScreen));
        showShapeTextEditor(ctx, paragraphs: ['Revenue by region'], title: 'Edit title');
        await settle(tester, rounds: 4);
        await saveScreenshot(tester, 'slides_textedit_$tag');
        await dismissTop(tester);
        showGoToSlide(ctx, 5);
        await settle(tester, rounds: 4);
        await saveScreenshot(tester, 'slides_goto_$tag');
        await dismissTop(tester);
      }
      await finish(tester);
    }, skip: !screenshotsEnabled);
  }
}
