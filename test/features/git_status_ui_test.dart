import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/git_status/git_porcelain.dart';
import 'package:folders/features/git_status/git_repos.dart';
import 'package:folders/features/git_status/git_status_controller.dart';
import 'package:folders/features/git_status/git_widgets.dart';
import 'package:folders/features/tags/tag_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';
import 'git_status/git_test_repo.dart';

/// The branch chip and the items' Git marks, on a real repo.
void main() {
  final hasGit = gitOnPath();
  late Directory temp;
  late String repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GitStatusSettings.instance.reset();
    GitRepos.forget();
    GitStatusController.runInTests = true;
    TagStore.instance = TagStore();
    ExplorerTabs.instance.reset();
    temp = await Directory.systemTemp.createTemp('git_status_ui');
  });

  tearDown(() async {
    GitStatusController.runInTests = false;
    TagStore.instance.close();
    TagStore.instance = null;
    ExplorerTabs.instance.reset();
    GitRepos.forget();
    await deleteRepo(temp);
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
    await settle(tester, 2);
  }

  /// The mark shown on the row of [name].
  GitMarkBadge? badgeOf(WidgetTester tester, String name) {
    final row = find.ancestor(of: find.text(name), matching: find.byType(Row)).first;
    final badge = find.descendant(of: row, matching: find.byType(GitMarkBadge));
    return badge.evaluate().isEmpty ? null : tester.widget<GitMarkBadge>(badge);
  }

  double opacityOf(WidgetTester tester, String name) =>
      tester.widget<Opacity>(find.ancestor(of: find.text(name), matching: find.byType(Opacity)).first).opacity;

  testWidgets('the branch chip and each kind of mark, kept up to date', (tester) async {
    await tester.runAsync(() async {
      repo = await makeRepo(temp.path, 'project');
      await writeFile(repo, '.gitignore', 'build/\n');
      await writeFile(repo, 'changed.txt', 'v1');
      await writeFile(repo, 'same.txt', 'v1');
      await writeFile(repo, 'src/inner.dart', 'v1');
      await git(repo, ['add', '.']);
      await git(repo, ['commit', '-m', 'first']);
      await writeFile(repo, 'changed.txt', 'v2');
      await writeFile(repo, 'src/inner.dart', 'v2');
      await writeFile(repo, 'fresh.txt', 'new');
      await writeFile(repo, 'build/app.bin', 'x');
    });

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: repo)));
    await until(tester, () => find.text('main').evaluate().isNotEmpty);

    expect(find.byType(GitBranchChip), findsOneWidget);
    expect(find.text('main'), findsOneWidget, reason: 'the branch, in the header');
    expect(badgeOf(tester, 'changed.txt')?.mark, GitMark.modified);
    expect(find.text('M'), findsOneWidget);
    expect(badgeOf(tester, 'fresh.txt')?.mark, GitMark.untracked);
    expect(badgeOf(tester, 'same.txt'), isNull);
    expect(badgeOf(tester, 'src')?.inside, GitMark.modified, reason: 'a dot: changes inside');
    expect(opacityOf(tester, 'build'), 0.5, reason: 'ignored, so dimmed');
    expect(opacityOf(tester, 'same.txt'), 1);

    // A new file, and the folder read again (as its watcher does).
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.text('same.txt')));
    await tester.runAsync(() => writeFile(repo, 'later.txt', 'x'));
    bloc.add(LoadDirectory(repo));
    await until(tester, () => find.text('later.txt').evaluate().isNotEmpty && badgeOf(tester, 'later.txt') != null);
    expect(badgeOf(tester, 'later.txt')?.mark, GitMark.untracked);

    // Turned off from the chip: nothing shows.
    await tester.tap(find.byType(GitBranchChip));
    await settle(tester);
    await tester.tap(find.text('Turn off Git status'));
    await settle(tester);
    expect(find.text('main'), findsNothing);
    expect(badgeOf(tester, 'changed.txt'), isNull);
    expect(opacityOf(tester, 'build'), 1);
    expect(GitStatusSettings.instance.value, isFalse);

    // And on again from Options.
    await tester.tap(find.byTooltip('Options'));
    await settle(tester);
    final option = find.widgetWithText(SwitchListTile, 'Git status');
    await tester.ensureVisible(option);
    await tester.tap(option);
    await settle(tester);
    expect(GitStatusSettings.instance.value, isTrue);
    await tester.tapAt(const Offset(20, 400)); // Closes the side sheet.
    await until(tester, () => find.text('main').evaluate().isNotEmpty);
    expect(badgeOf(tester, 'changed.txt')?.mark, GitMark.modified);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }, skip: !hasGit); // Needs git on the PATH.

  testWidgets('outside a repo nothing shows and git never runs', (tester) async {
    final plain = Directory(p.join(temp.path, 'plain'))..createSync();
    File(p.join(plain.path, 'a.txt')).writeAsStringSync('a');
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: plain.path)));
    await until(tester, () => find.text('a.txt').evaluate().isNotEmpty);
    expect(find.byType(GitMarkBadge), findsNothing);
    expect(find.descendant(of: find.byType(GitBranchChip), matching: find.byType(Text)), findsNothing);
    expect(GitRepos.cached(plain.path), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
