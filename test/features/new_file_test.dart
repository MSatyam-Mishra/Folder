import 'dart:io';

import 'package:archive/archive.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/repositories/file_repository.dart';
import 'package:explorer/core/services/new_files.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/explorer_tabs/tabbed_explorer.dart';
import 'package:explorer/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:explorer/features/file_explorere/widgets/new_file_button.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
      expect(NewFiles.freeName(dir.path, text), 'New Text Document.txt');
      final path = p.join(dir.path, 'New Text Document.txt');
      await NewFiles.create(text, path);
      expect(NewFiles.freeName(dir.path, text), 'New Text Document (2).txt');

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

    testWidgets('offers Text and Word at first, and creates what is picked', (tester) async {
      await open(tester);
      await openMenu(tester);
      expect(find.text('New file'), findsOneWidget);
      expect(find.byIcon(LucideIcons.settings), findsOneWidget);
      expect(find.text('Text file (.txt)'), findsOneWidget);
      expect(find.text('Word document (.docx)'), findsOneWidget);
      expect(find.text('Excel workbook (.xlsx)'), findsNothing);

      await tester.tap(find.text('Word document (.docx)'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(find.widgetWithText(TextField, 'New Word Document.docx'), findsOneWidget);
      await tester.tap(find.text('Create'), kind: PointerDeviceKind.mouse);
      for (var i = 0; i < 40 && find.text('New Word Document.docx').evaluate().isEmpty; i++) {
        await settle(tester);
      }
      final made = File(p.join(root.path, 'New Word Document.docx'));
      expect(await tester.runAsync(made.exists), isTrue);
      expect(find.text('New Word Document.docx'), findsOneWidget, reason: 'it shows in the folder');
      await tester.pumpWidget(const SizedBox());
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
