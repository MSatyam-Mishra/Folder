import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/git_status/git_repos.dart';
import 'package:folders/features/git_status/git_status_controller.dart';
import 'package:folders/features/tags/tag_actions.dart';
import 'package:folders/features/tags/tag_color.dart';
import 'package:folders/features/tags/tag_paths.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:folders/features/tags/tags_sidebar.dart';
import 'package:folders/shared/widgets/main_drawer.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../features/git_status/git_test_repo.dart';
import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/tags_git_screens_test.dart
/// → build/screenshots/tags_*.png: tags' dots, Git's marks and branch, the
/// sidebar's Tags, the Tags menu, a tag's folder and the tag editor.
void main() {
  late Directory temp;
  late String repo;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    temp = await Directory.systemTemp.createTemp('tags_shots');
    repo = await makeRepo(temp.path, 'website');
    await writeFile(repo, '.gitignore', 'build/\n');
    for (final name in ['index.html', 'about.html', 'styles.css', 'logo.svg', 'README.md']) {
      await writeFile(repo, name, '<!-- $name -->');
    }
    await writeFile(repo, 'src/app.js', 'v1');
    await writeFile(repo, 'docs/guide.md', 'v1');
    await git(repo, ['add', '.']);
    await git(repo, ['commit', '-m', 'first']);
    await writeFile(repo, 'about.html', '<!-- about, changed -->');
    await writeFile(repo, 'src/app.js', 'v2');
    await writeFile(repo, 'contact.html', 'new');
    await git(repo, ['add', 'contact.html']);
    await writeFile(repo, 'notes.txt', 'draft');
    await writeFile(repo, 'build/site.zip', 'x');
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await deleteRepo(temp);
  });

  late TagStore store;

  setUp(() async {
    if (!screenshotsEnabled) return;
    SharedPreferences.setMockInitialValues({});
    GitRepos.forget();
    GitStatusSettings.instance.reset();
    GitStatusController.runInTests = true;
    ExplorerTabs.instance.reset();
    store = TagStore();
    TagStore.instance = store;
    await store.ensureLoaded();
    final clients = store.addTag('Clients', color: TagColor.blue);
    store.addTag('Ideas');
    store.setTag([p.join(repo, 'index.html'), p.join(repo, 'about.html')], 'Red', on: true);
    store.setTag([p.join(repo, 'about.html'), p.join(repo, 'docs')], clients.name, on: true);
    store.setTag([p.join(repo, 'logo.svg')], 'Green', on: true);
    store.setTag([p.join(repo, 'README.md')], 'Ideas', on: true);
    store.setTag([p.join(repo, 'contact.html')], 'Orange', on: true);
  });

  tearDown(() {
    if (!screenshotsEnabled) return;
    GitStatusController.runInTests = false;
    store.close();
    TagStore.instance = null;
  });

  Future<void> settle(WidgetTester tester, [int rounds = 4]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await settle(tester, 1);
    }
    await settle(tester, 3);
  }

  Future<FileExplorerBloc> open(WidgetTester tester, ThemeMode mode, {ViewMode view = ViewMode.list}) async {
    setScreenSize(tester, const Size(1280, 800), pixelRatio: 1.5);
    await tester.runAsync(() async {
      await FolderPrefsService().init();
      await FolderPrefsService().setViewMode(repo, view);
    });
    await tester.pumpWidget(screenshotFrame(themedApp(TabbedExplorer(startFolder: repo), themeMode: mode)));
    await until(tester, () => find.text('main').evaluate().isNotEmpty);
    await tester.scrollUntilVisible(
      find.byType(TagsSidebarSection),
      300,
      scrollable: find.descendant(of: find.byType(MainDrawerContent), matching: find.byType(Scrollable)).first,
    );
    await settle(tester);
    return BlocProvider.of<FileExplorerBloc>(tester.element(find.text('index.html')));
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('tags and git ${mode.name}', (tester) async {
      await open(tester, mode);
      await saveScreenshot(tester, 'tags_git_${mode.name}');
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('tags menu ${mode.name}', (tester) async {
      await open(tester, mode);
      await tester.tap(find.text('about.html'), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.text('Tags').last);
      await settle(tester);
      await saveScreenshot(tester, 'tags_menu_${mode.name}');
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    }, skip: !screenshotsEnabled);
  }

  testWidgets('tags grid', (tester) async {
    await open(tester, ThemeMode.light, view: ViewMode.grid);
    await saveScreenshot(tester, 'tags_grid_light');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }, skip: !screenshotsEnabled);

  testWidgets('tag folder', (tester) async {
    final bloc = await open(tester, ThemeMode.light);
    bloc.add(LoadDirectory(TagPaths.of('Clients')));
    await until(tester, () => find.text('guide.md').evaluate().isEmpty && find.text('docs').evaluate().isNotEmpty);
    await saveScreenshot(tester, 'tags_folder_light');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }, skip: !screenshotsEnabled);

  testWidgets('tag editor', (tester) async {
    await open(tester, ThemeMode.dark);
    TagActions.newTag(tester.element(find.text('index.html')));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Invoices');
    await tester.tap(find.byTooltip('Purple'));
    await settle(tester);
    await saveScreenshot(tester, 'tags_editor_dark');
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }, skip: !screenshotsEnabled);
}
