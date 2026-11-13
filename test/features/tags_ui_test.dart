import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/tags/tag_actions.dart';
import 'package:folders/features/tags/tag_color.dart';
import 'package:folders/features/tags/tag_dot.dart';
import 'package:folders/features/tags/tag_folder_bar.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:folders/features/tags/tags_sidebar.dart';
import 'package:folders/shared/widgets/main_drawer.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Tagging from the menus, the dots on items, and the sidebar's Tags.
void main() {
  late Directory root;
  late TagStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_tags');
    for (final name in ['notes.txt', 'plan.txt', 'zebra.txt']) {
      await File(p.join(root.path, name)).writeAsString(name);
    }
    store = TagStore();
    TagStore.instance = store;
    ExplorerTabs.instance.reset();
  });

  tearDown(() async {
    store.close();
    TagStore.instance = null;
    ExplorerTabs.instance.reset();
    await root.delete(recursive: true);
  });

  String path(String name) => p.join(root.path, name);

  Future<void> settle(WidgetTester tester, [int rounds = 6]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await settle(tester, 2);
    }
    await settle(tester, 2);
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    await until(tester, () => find.text('notes.txt').evaluate().isNotEmpty);
    return BlocProvider.of<FileExplorerBloc>(tester.element(find.text('notes.txt')));
  }

  /// Scrolls the sidebar down to its Tags (it's built as it's scrolled to).
  Future<void> showSidebarTags(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byType(TagsSidebarSection),
      200,
      scrollable: find.descendant(of: find.byType(MainDrawerContent), matching: find.byType(Scrollable)).first,
    );
    await tester.pump();
  }

  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await settle(tester);
  }

  /// The menu's Tags ▸ (the sidebar has a Tags heading too; the menu is
  /// drawn last).
  Finder tagsRow() => find.text('Tags').last;

  /// The menu's row with [label] (not the same words elsewhere on screen).
  Finder menuRow(String label) => find.descendant(of: find.byType(PopupMenuItem<Object>), matching: find.text(label));

  testWidgets('right-click > Tags > Red puts a red dot on the file, and Red in the sidebar', (tester) async {
    await open(tester);
    await showSidebarTags(tester);
    expect(find.byType(TagDots), findsNothing);
    expect(find.byType(TagSidebarItem), findsNothing, reason: "Finder's colours show once something has them");
    expect(find.text('Right-click a file to tag it.'), findsOneWidget);

    await rightClick(tester, find.text('notes.txt'));
    await tester.tap(tagsRow());
    await settle(tester);
    // Every colour is offered, with New tag….
    for (final name in ['Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Purple', 'Grey', 'New tag…']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    await tester.tap(find.text('Red'));
    await settle(tester);

    expect(store.tagsOf(path('notes.txt')).map((t) => t.name), ['Red']);
    final dots = tester.widget<TagDots>(find.byType(TagDots));
    expect(dots.tags.single.color, TagColor.red);
    expect(find.widgetWithText(TagSidebarItem, 'Red'), findsOneWidget);

    // Again: the tick is there, and picking it takes the tag off.
    await rightClick(tester, find.text('notes.txt'));
    await tester.tap(tagsRow());
    await settle(tester);
    expect(find.descendant(of: find.widgetWithText(PopupMenuItem<Object>, 'Red'), matching: find.byIcon(LucideIcons.check)),
        findsOneWidget);
    expect(menuRow('Remove all tags'), findsOneWidget);
    await tester.tap(menuRow('Red'));
    await settle(tester);
    expect(store.tagsOf(path('notes.txt')), isEmpty);
    expect(find.byType(TagDots), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a selection gets a new tag, made with its colour, from its menu', (tester) async {
    final bloc = await open(tester);
    bloc.add(SetSelection({File(path('notes.txt')), File(path('plan.txt'))}, selectionMode: true));
    await settle(tester);

    await rightClick(tester, find.text('plan.txt'));
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(tagsRow());
    await settle(tester);
    await tester.tap(find.text('New tag…'));
    await settle(tester);

    expect(find.text('New tag'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await settle(tester);
    expect(find.text('Type a name.'), findsOneWidget, reason: 'a name is needed');
    await tester.enterText(find.byType(TextField), 'red');
    await tester.tap(find.text('Create'));
    await settle(tester);
    expect(find.text('There is a tag with this name already.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Clients');
    await tester.tap(find.byTooltip('Blue'));
    await tester.tap(find.text('Create'));
    await settle(tester);

    expect(store.tagNamed('Clients'), const TagDef('Clients', TagColor.blue));
    expect(store.stateOf([path('notes.txt'), path('plan.txt')], 'Clients'), TagState.all);
    expect(store.tagsOf(path('zebra.txt')), isEmpty);
    expect(find.byType(TagDots), findsNWidgets(2));
    await showSidebarTags(tester);
    expect(find.widgetWithText(TagSidebarItem, 'Clients'), findsOneWidget, reason: 'tags made by hand always show');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets("a tag in the sidebar opens its folder, which can rename and delete it", (tester) async {
    final notes = path('notes.txt');
    await store.ensureLoaded();
    store.setTag([notes, path('zebra.txt')], 'Green', on: true);
    final bloc = await open(tester);
    await showSidebarTags(tester);

    await tester.tap(find.widgetWithText(TagSidebarItem, 'Green'));
    await until(tester, () => (bloc.state as dynamic).path == TagPaths.of('Green') && bloc.state is FileExplorerLoaded);
    expect(find.byType(TagFolderBar), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('zebra.txt'), findsOneWidget);
    expect(find.text('plan.txt'), findsNothing);
    expect(find.text('in ${p.basename(root.path)}'), findsNWidgets(2), reason: 'where each one is');

    // Taking the tag off one item takes it out of the folder.
    store.setTag([path('zebra.txt')], 'Green', on: false);
    await until(tester, () => find.text('zebra.txt').evaluate().isEmpty);
    expect(find.text('zebra.txt'), findsNothing);

    // Rename it from the bar: the folder follows.
    await tester.tap(find.byTooltip('Rename or change colour'));
    await settle(tester);
    expect(find.text('Edit tag'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Done');
    await tester.tap(find.byTooltip('Purple'));
    await tester.tap(find.text('Save'));
    await until(tester, () => bloc.state is FileExplorerLoaded && (bloc.state as FileExplorerLoaded).path == TagPaths.of('Done'));
    expect(store.tagsOf(notes).single, const TagDef('Done', TagColor.purple));
    expect(find.text('notes.txt'), findsOneWidget);

    // Delete it: asked first, then home.
    await tester.tap(find.byTooltip('Delete tag'));
    await settle(tester);
    expect(find.text('Delete the tag "Done"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(store.tagNamed('Done'), isNull);
    expect(store.tagsOf(notes), isEmpty);
    final now = bloc.state;
    expect(now is FileExplorerLoaded ? now.path : (now as FileExplorerLoading).path, ExplorerPaths.homePath);
    expect(File(notes).existsSync(), isTrue, reason: 'the file stays');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('right-click on a tag in the sidebar recolours it', (tester) async {
    await store.ensureLoaded();
    store.setTag([path('plan.txt')], 'Blue', on: true);
    await open(tester);
    await showSidebarTags(tester);
    await rightClick(tester, find.widgetWithText(TagSidebarItem, 'Blue'));
    expect(find.text('Rename…'), findsOneWidget);
    expect(find.text('Delete tag'), findsOneWidget);
    await tester.tap(find.text('Colour'));
    await settle(tester);
    await tester.tap(find.text('Orange'));
    await settle(tester);
    expect(store.tagNamed('Blue')!.color, TagColor.orange);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('files dropped on a tag in the sidebar get it, and it says so', (tester) async {
    await store.ensureLoaded();
    final a = path('notes.txt'), b = path('plan.txt');
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => tagDropped(context, store.tagNamed('Yellow')!, [a, b]),
            child: const Text('Drop'),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('Drop'));
    await settle(tester);
    expect(store.stateOf([a, b], 'Yellow'), TagState.all);
    expect(find.text('Tagged 2 items "Yellow"'), findsOneWidget);
  });

  testWidgets('the picker (phones, Tags…) ticks tags on and off at once', (tester) async {
    await store.ensureLoaded();
    final a = path('notes.txt'), b = path('plan.txt');
    store.setTag([a], 'Red', on: true);
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(onPressed: () => TagActions.showPicker(context, [a, b]), child: const Text('Pick')),
        ),
      ),
    )));
    await tester.tap(find.text('Pick'));
    await settle(tester);
    expect(find.text('2 items'), findsOneWidget);
    Checkbox box(String name) => tester.widget<Checkbox>(
        find.descendant(of: find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first, matching: find.byType(Checkbox)));
    expect(box('Red').value, isNull, reason: 'one of the two has it');
    expect(box('Green').value, isFalse);

    await tester.tap(find.text('Red'));
    await settle(tester);
    expect(box('Red').value, isTrue);
    expect(store.stateOf([a, b], 'Red'), TagState.all);
    await tester.tap(find.text('Green'));
    await settle(tester);
    expect(store.stateOf([a, b], 'Green'), TagState.all);
    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.byType(TagPicker), findsNothing);
  });
}
