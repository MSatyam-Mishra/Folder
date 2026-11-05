import 'dart:io';

import 'package:archive/archive.dart';
import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/repositories/file_repository.dart';
import 'package:folder/core/services/new_files.dart';
import 'package:folder/features/explorer_tabs/explorer_tabs.dart';
import 'package:folder/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/widgets/new_file_button.dart';
import 'package:folder/features/viewer_office/document/document_loader.dart';
import 'package:folder/features/viewer_office/screens/ppt_viewer_screen.dart';
import 'package:folder/features/viewer_office/screens/word_viewer_screen.dart';
import 'package:folder/features/viewer_office/slides/pptx_parser.dart';
import 'package:folder/features/viewer_sheets/screens/spreadsheet_screen.dart';
import 'package:folder/features/viewer_text/screens/tabbed_text_editor.dart';
import 'package:folder/features/viewer_text/screens/text_editor_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The + next to New folder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('blank files', () {
    NewFileKind kind(String extension) => NewFiles.kinds.firstWhere((k) => k.extension == extension);

    test('each kind has its own extension and blank contents', () async {
      expect(NewFiles.kinds.map((k) => k.extension).toSet(), hasLength(NewFiles.kinds.length));
      for (final k in NewFiles.kinds) {
        await NewFiles.contents(k);
      }
    });

    test('Office files are the packages they should be', () async {
      Archive unzip(List<int> bytes) => ZipDecoder().decodeBytes(bytes);
      expect(unzip(await NewFiles.contents(kind('docx'))).findFile('word/document.xml'), isNotNull);
      expect(unzip(await NewFiles.contents(kind('xlsx'))).findFile('xl/worksheets/sheet1.xml'), isNotNull);
      expect(unzip(await NewFiles.contents(kind('pptx'))).findFile('ppt/presentation.xml'), isNotNull);
      // An old Excel file is a compound document.
      expect((await NewFiles.contents(kind('xls'))).take(4), [0xD0, 0xCF, 0x11, 0xE0]);
    });

    test('OpenDocument files start with their type, uncompressed', () async {
      for (final (extension, type) in [('odt', 'text'), ('ods', 'spreadsheet'), ('odp', 'presentation')]) {
        final bytes = await NewFiles.contents(kind(extension));
        expect(String.fromCharCodes(bytes.sublist(30, 38)), 'mimetype');
        final mime = 'application/vnd.oasis.opendocument.$type';
        expect(String.fromCharCodes(bytes.sublist(38, 38 + mime.length)), mime);
      }
    });

    test('a PDF table points at its objects', () async {
      final text = String.fromCharCodes(await NewFiles.contents(kind('pdf')));
      final start = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!);
      expect(text.substring(start, start + 4), 'xref');
      for (final match in RegExp(r'(\d{10}) 00000 n').allMatches(text).indexed) {
        final offset = int.parse(match.$2.group(1)!);
        expect(text.substring(offset).startsWith('${match.$1 + 1} 0 obj'), isTrue);
      }
    });

    test('a taken name gets a number; an existing file is never overwritten', () async {
      final dir = await Directory.systemTemp.createTemp('explorer_new_file');
      addTearDown(() => dir.delete(recursive: true));
      final text = kind('txt');
      expect(NewFiles.freeName(dir.path, text.baseName, 'txt'), 'New Text Document.txt');
      final path = p.join(dir.path, 'New Text Document.txt');
      await NewFiles.create(text, path);
      expect(NewFiles.freeName(dir.path, text.baseName, 'txt'), 'New Text Document (2).txt');

      await File(path).writeAsString('keep me');
      await expectLater(NewFiles.create(text, path), throwsA(isA<FileSystemException>()));
      expect(await File(path).readAsString(), 'keep me');
    });
  });

  group('the button', () {
    late Directory root;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('explorer_new_file');
      await File(p.join(root.path, 'notes.txt')).writeAsString('notes');
      ExplorerTabs.instance.reset();
    });

    tearDown(() async {
      ExplorerTabs.instance.reset();
      // Windows' thumbnailer may still be reading a new document.
      for (var tries = 0; tries < 20; tries++) {
        try {
          await root.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// What [file] holds once it's [expected], or the last seen if it never is:
    /// a save takes longer than a settle on a busy machine.
    Future<String?> savedAs(WidgetTester tester, File file, String expected) async {
      String? seen;
      for (var i = 0; i < 50 && seen != expected; i++) {
        seen = await tester.runAsync<String?>(() async {
          if (!await file.exists()) return null;
          return file.readAsString();
        });
        if (seen != expected) await settle(tester);
      }
      return seen;
    }

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
      for (var i = 0; i < 60 && find.text('notes.txt').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byType(NewFileButton), kind: PointerDeviceKind.mouse);
      await settle(tester);
    }

    Future<void> pickText(WidgetTester tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Text file (.txt)'), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 40 && find.byType(TabbedTextEditorScreen).evaluate().isEmpty; i++) {
        await settle(tester);
      }
      await settle(tester);
      expect(find.byType(TabbedTextEditorScreen), findsOneWidget);
    }

    bool inFolder(String name) => File(p.join(root.path, name)).existsSync();

    testWidgets('offers Text and Word at first', (tester) async {
      await open(tester);
      await openMenu(tester);
      expect(find.text('New file'), findsOneWidget);
      expect(find.byIcon(LucideIcons.settings), findsOneWidget);
      expect(find.text('Text file (.txt)'), findsOneWidget);
      expect(find.text('Word document (.docx)'), findsOneWidget);
      expect(find.text('Excel workbook (.xlsx)'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opens in its editor, and gets its name when saved', (tester) async {
      await open(tester);
      await pickText(tester);
      expect(inFolder('New Text Document.txt'), isFalse, reason: 'nothing is made until it is saved');

      await tester.enterText(find.byType(TextField).last, 'hello');
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);

      // The name is asked now.
      expect(find.text('Save as'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'New Text Document.txt'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'New Text Document.txt'), 'notes for later');
      await settle(tester);
      await tester.tap(find.text('Save').last, kind: PointerDeviceKind.mouse);
      await settle(tester);

      final made = File(p.join(root.path, 'notes for later.txt'));
      expect(await savedAs(tester, made, 'hello'), 'hello', reason: 'the extension was added');
      expect(find.byType(TabbedTextEditorScreen), findsOneWidget, reason: 'still editing');

      // Saving again goes to that file, without asking.
      await tester.enterText(find.byType(TextField).last, 'hello again');
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(find.text('Save as'), findsNothing);
      expect(await savedAs(tester, made, 'hello again'), 'hello again');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves nothing behind if it is never saved', (tester) async {
      await open(tester);
      final before = root.listSync().length;
      await pickText(tester);
      final pane = tester.state<TextEditorPaneState>(find.byType(TextEditorPane));
      final untitled = (pane.widget.file);
      expect(UntitledFiles.isUntitled(untitled), isTrue);
      await tester.pageBack();
      for (var i = 0; i < 20 && find.byType(TabbedTextEditorScreen).evaluate().isNotEmpty; i++) {
        await settle(tester);
      }
      await settle(tester);
      expect(find.byType(TabbedTextEditorScreen), findsNothing);
      expect(root.listSync(), hasLength(before));
      expect(UntitledFiles.isUntitled(untitled), isFalse);
      expect(await tester.runAsync(untitled.exists), isFalse, reason: 'the temporary file goes too');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("cancelling the name doesn't save", (tester) async {
      await open(tester);
      await pickText(tester);
      await tester.enterText(find.byType(TextField).last, 'hello');
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.tap(find.text('Cancel').last, kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(inFolder('New Text Document.txt'), isFalse);
      expect(find.byType(TabbedTextEditorScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    // Each editor: nothing in the folder until Save, which asks for the name.
    for (final (label, name, ext, screen) in [
      ('Word document (.docx)', 'Word', 'docx', WordViewerScreen),
      ('Excel workbook (.xlsx)', 'Excel', 'xlsx', SpreadsheetScreen),
      ('PowerPoint presentation (.pptx)', 'PowerPoint', 'pptx', PptViewerScreen),
    ]) {
      testWidgets('$name: opens to edit, and Save asks for the name', (tester) async {
        SharedPreferences.setMockInitialValues({'new_file_kinds': [ext]});
        await open(tester);
        await openMenu(tester);
        await tester.tap(find.text(label), kind: PointerDeviceKind.mouse);
        for (var i = 0; i < 40 && find.byType(screen).evaluate().isEmpty; i++) {
          await settle(tester);
        }
        final save = find.byTooltip('Save');
        for (var i = 0; i < 80 && save.evaluate().isEmpty; i++) {
          await settle(tester);
        }
        expect(save, findsWidgets, reason: 'in edit mode, with Save showing');
        expect(root.listSync().map((e) => p.basename(e.path)), ['notes.txt'], reason: 'nothing made yet');

        await tester.tap(save.first, kind: PointerDeviceKind.mouse);
        await settle(tester);
        // PowerPoint's Save is a menu.
        if (find.text('Save as').evaluate().isEmpty) {
          await tester.tap(find.text('Save').last, kind: PointerDeviceKind.mouse);
          await settle(tester);
        }
        expect(find.text('Save as'), findsOneWidget);
        await tester.enterText(find.byType(TextField).last, 'My $name file');
        await settle(tester);
        await tester.tap(find.text('Save').last, kind: PointerDeviceKind.mouse);

        final made = File(p.join(root.path, 'My $name file.$ext'));
        for (var i = 0; i < 80 && !made.existsSync(); i++) {
          await settle(tester);
        }
        expect(made.existsSync(), isTrue);
        expect(find.byType(screen), findsOneWidget, reason: 'still editing');
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
      });
    }

    test("the blank files open in the app's own readers", () async {
      Future<List<int>> blank(String extension) =>
          NewFiles.contents(NewFiles.kinds.firstWhere((k) => k.extension == extension));
      for (final extension in ['docx', 'doc', 'rtf', 'odt']) {
        final model = await parseDocumentInBackground(Uint8List.fromList(await blank(extension)), extension);
        expect(model.warnings, isNot(contains('plainText')), reason: extension);
      }
      expect(parsePptxBytes(Uint8List.fromList(await blank('pptx'))).slides, hasLength(1));
    });

    testWidgets('the settings row chooses what the menu has', (tester) async {
      await open(tester);
      await openMenu(tester);
      await tester.tap(find.text('New file'), kind: PointerDeviceKind.mouse);
      await settle(tester);

      // Every kind is listed, with the usual two ticked.
      expect(find.text('File types'), findsOneWidget);
      await tester.tap(find.text('Text file (.txt)'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await tester.tap(find.text('Excel workbook (.xlsx)'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await tester.tapAt(const Offset(20, 400), kind: PointerDeviceKind.mouse);
      await settle(tester);

      await openMenu(tester);
      expect(find.text('Text file (.txt)'), findsNothing, reason: 'unticked');
      expect(find.text('Word document (.docx)'), findsOneWidget);
      expect(find.text('Excel workbook (.xlsx)'), findsOneWidget, reason: 'ticked');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("isn't offered in a category", (tester) async {
      final real = LocalFileRepository.categoryFiles;
      addTearDown(() => LocalFileRepository.categoryFiles = real);
      LocalFileRepository.categoryFiles = (_) async => root.listSync();
      await open(tester);
      expect(find.byType(NewFileButton), findsOneWidget);

      BlocProvider.of<FileExplorerBloc>(tester.element(find.text('notes.txt')))
          .add(LoadDirectory(ExplorerPaths.categoryPath('Documents')));
      await settle(tester);
      expect(find.byType(NewFileButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
