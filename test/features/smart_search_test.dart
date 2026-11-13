import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:folders/core/services/search/search_places.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/file_explorere/widgets/search_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The search box's options, what Smart search understood as chips, and
/// words found inside files shown in context.
void main() {
  late Directory root;
  late Directory elsewhere;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('smart_search_test');
    elsewhere = await Directory.systemTemp.createTemp('smart_search_elsewhere');
    await File(p.join(root.path, 'minutes.txt')).writeAsString('Minutes. We agreed the quarterly budget at last.');
    await File(p.join(root.path, 'other.txt')).writeAsString('Nothing here');
    await File(p.join(root.path, 'march-report.txt')).writeAsString('report');
    final lastWeek = DateTime.now().subtract(const Duration(days: 7));
    await (await File(p.join(root.path, 'Camera', 'beach.jpg')).create(recursive: true)).setLastModified(lastWeek);
    await File(p.join(root.path, 'Camera', 'old.jpg')).writeAsString('x');
    await File(p.join(root.path, 'Camera', 'old.jpg')).setLastModified(DateTime(2020, 1, 1));
    await File(p.join(elsewhere.path, 'budget-2026.xlsx')).writeAsString('x');
    ExplorerPaths.startFolder = root.path;
    SearchPlaces.everywhereOverride = () async => [root.path, elsewhere.path];
  });

  tearDown(() async {
    ExplorerPaths.startFolder = null;
    SearchPlaces.everywhereOverride = null;
    PhotoTextIndex.override = null;
    await root.delete(recursive: true);
    await elsewhere.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, [int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<FileExplorerBloc> open(WidgetTester tester, {Size size = const Size(1280, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester);
    }
    bloc.add(OpenSearch());
    await settle(tester);
    return bloc;
  }

  FileExplorerLoaded stateOf(FileExplorerBloc bloc) => bloc.state as FileExplorerLoaded;

  Future<void> search(WidgetTester tester, FileExplorerBloc bloc, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await settle(tester);
    for (var i = 0; i < 40 && stateOf(bloc).searching; i++) {
      await settle(tester);
    }
  }

  /// [text] among the search's options and chips.
  Finder chip(String text) => find.descendant(of: find.byType(SearchPanel), matching: find.text(text));

  List<String> found(FileExplorerBloc bloc) => [for (final e in stateOf(bloc).searchResults) p.basename(e.path)];

  testWidgets('Inside files finds words in text and shows them in context', (tester) async {
    final bloc = await open(tester);
    for (final label in ['Smart search', 'Inside files', 'Everywhere']) {
      expect(chip(label), findsOneWidget, reason: label);
    }
    await search(tester, bloc, 'budget');
    expect(found(bloc), isEmpty);
    expect(find.text('Nothing matches “budget”'), findsOneWidget);
    expect(find.textContaining('Try Inside files or Everywhere above'), findsOneWidget);

    await tester.tap(chip('Inside files'));
    await settle(tester);
    for (var i = 0; i < 40 && stateOf(bloc).searching; i++) {
      await settle(tester);
    }
    expect(stateOf(bloc).search.options.insideFiles, isTrue);
    expect(found(bloc), ['minutes.txt']);
    final snippet = tester.widget<SearchSnippetText>(find.byType(SearchSnippetText));
    expect(snippet.snippet.text, contains('quarterly budget'));
    // The word in bold.
    final rich = tester.widget<RichText>(
      find.descendant(of: find.byType(SearchSnippetText), matching: find.byType(RichText)),
    );
    final bold = <String>[];
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text != null && span.style?.fontWeight == FontWeight.w700) bold.add(span.text!);
      return true;
    });
    expect(bold, ['budget']);
    // Remembered.
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getBool('search_inside_files'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Smart search shows what it understood; a chip taken off searches again', (tester) async {
    final bloc = await open(tester);
    await search(tester, bloc, 'photos from last week');
    expect(found(bloc), ['beach.jpg']);
    expect(chip('Photos'), findsOneWidget);
    expect(chip('Last week'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove “Last week”'));
    await settle(tester);
    for (var i = 0; i < 40 && stateOf(bloc).searching; i++) {
      await settle(tester);
    }
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'photos');
    expect(found(bloc), unorderedEquals(['beach.jpg', 'old.jpg']));
    expect(chip('Last week'), findsNothing);

    // Words understood still match names: "march" is a month, and a name.
    await search(tester, bloc, 'march');
    expect(found(bloc), contains('march-report.txt'));
    expect(chip('March ${DateTime(DateTime.now().year, 3).isAfter(DateTime.now()) ? DateTime.now().year - 1 : DateTime.now().year}'),
        findsOneWidget);

    // Off: names only, as typed.
    await tester.tap(chip('Smart search'));
    await settle(tester);
    await search(tester, bloc, 'photos from last week');
    expect(found(bloc), isEmpty);
    expect(chip('Photos'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Everywhere looks beyond this folder and shows where', (tester) async {
    final bloc = await open(tester);
    await search(tester, bloc, 'budget');
    expect(found(bloc), isEmpty);
    await tester.tap(find.text('Search everywhere'));
    await settle(tester);
    for (var i = 0; i < 40 && stateOf(bloc).searching; i++) {
      await settle(tester);
    }
    expect(stateOf(bloc).search.options.everywhere, isTrue);
    expect(found(bloc), ['budget-2026.xlsx']);
    expect(find.text('in ${elsewhere.path}'), findsOneWidget, reason: 'outside this folder: its whole path');

    // Not remembered: a new search starts in this folder.
    bloc.add(CloseSearch());
    await settle(tester);
    bloc.add(OpenSearch());
    await settle(tester);
    expect(stateOf(bloc).search.options.everywhere, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets("photos' text: the progress shows, and what's found", (tester) async {
    PhotoTextIndex.override = PhotoTextIndex(
      folder: () async => p.join(root.path, '.index'),
      ocr: (path) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return p.basename(path) == 'beach.jpg' ? 'ICE CREAM RECEIPT 3.50' : null;
      },
    );
    final bloc = await open(tester);
    await tester.enterText(find.byType(TextField), 'receipt last week');
    var sawProgress = false;
    for (var i = 0; i < 60; i++) {
      await settle(tester, 1);
      if (find.textContaining('Reading text in').evaluate().isNotEmpty) sawProgress = true;
      if (!stateOf(bloc).searching && i > 4) break;
    }
    expect(sawProgress, isTrue);
    expect(found(bloc), ['beach.jpg']);
    expect(find.textContaining('ICE CREAM RECEIPT'), findsOneWidget);
    expect(chip('Text: receipt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone too', (tester) async {
    final bloc = await open(tester, size: const Size(400, 800));
    expect(find.byType(SearchPanel), findsOneWidget);
    await search(tester, bloc, 'videos in march');
    expect(chip('Videos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
