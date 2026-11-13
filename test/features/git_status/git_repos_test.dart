import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/features/git_status/git_porcelain.dart';
import 'package:folders/features/git_status/git_repos.dart';
import 'package:folders/features/git_status/git_status_controller.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'git_test_repo.dart';

/// Git status on real throwaway repos (skipped without git).
void main() {
  final hasGit = gitOnPath();
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GitStatusSettings.instance.reset();
    GitRepos.forget();
    temp = await Directory.systemTemp.createTemp('git_status_test');
  });

  tearDown(() async {
    GitRepos.forget();
    await deleteRepo(temp);
  });

  test('finds the work tree from any folder inside it, and nothing outside', () async {
    final repo = await makeRepo(temp.path, 'project');
    final deep = Directory(p.join(repo, 'src', 'deep'))..createSync(recursive: true);
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    expect(GitRepos.rootOf(deep.path), repo);
    expect(GitRepos.rootOf(repo), repo);
    expect(GitRepos.rootOf(outside.path), isNull);
    expect(GitRepos.rootOf(p.join(repo, '.git')), isNull, reason: "git's own folder");
    expect(GitRepos.rootOf('explorer://tag/Red'), isNull);
    expect(GitRepos.rootOf('explorer://remote/nas/x'), isNull);
  }, skip: hasGit ? false : 'git is not on the PATH');

  test("the answer is remembered: a folder that isn't in one costs no more checks", () async {
    final outside = Directory(p.join(temp.path, 'plain', 'a', 'b'))..createSync(recursive: true);
    expect(GitRepos.rootOf(outside.path), isNull);
    // A .git appearing now isn't seen until the remembered answer is old.
    Directory(p.join(temp.path, 'plain', '.git')).createSync();
    expect(GitRepos.rootOf(outside.path), isNull);
    GitRepos.forget();
    expect(GitRepos.rootOf(outside.path), p.join(temp.path, 'plain'));
  }, skip: hasGit ? false : 'git is not on the PATH');

  test('reads the branch and every kind of change from git itself', () async {
    final repo = await makeRepo(temp.path, 'project');
    await writeFile(repo, '.gitignore', 'build/\n*.log\n');
    await writeFile(repo, 'src/app.dart', 'v1');
    await writeFile(repo, 'src/keep.dart', 'v1');
    await writeFile(repo, 'README.md', 'hello');
    await writeFile(repo, 'conflict.txt', 'base\n');
    await git(repo, ['add', '.']);
    await git(repo, ['commit', '-m', 'first']);
    // A conflict: both branches change the same line.
    await git(repo, ['checkout', '-b', 'other']);
    await writeFile(repo, 'conflict.txt', 'theirs\n');
    await git(repo, ['commit', '-am', 'theirs']);
    await git(repo, ['checkout', 'main']);
    await writeFile(repo, 'conflict.txt', 'ours\n');
    await git(repo, ['commit', '-am', 'ours']);
    await git(repo, ['merge', 'other'], allowFailure: true);

    await writeFile(repo, 'src/app.dart', 'v2'); // Changed.
    await writeFile(repo, 'docs/new.md', 'new'); // New, staged.
    await git(repo, ['add', 'docs/new.md']);
    await writeFile(repo, 'notes with spaces.txt', 'x'); // Not tracked.
    await writeFile(repo, 'build/out.bin', 'x'); // Ignored folder.
    await writeFile(repo, 'debug.log', 'x'); // Ignored file.

    final status = (await GitRepos.load(repo))!;
    expect(status.branch, 'main');
    String path(String rel) => p.joinAll([repo, ...rel.split('/')]);
    expect(status.markFor(path('src/app.dart')), GitMark.modified);
    expect(status.markFor(path('src/keep.dart')), isNull);
    expect(status.markFor(path('docs/new.md')), GitMark.added);
    expect(status.markFor(path('notes with spaces.txt')), GitMark.untracked);
    expect(status.markFor(path('conflict.txt')), GitMark.conflicted);
    expect(status.markFor(path('build')), GitMark.ignored);
    expect(status.markFor(path('build/out.bin')), GitMark.ignored);
    expect(status.markFor(path('debug.log')), GitMark.ignored);
    expect(status.insideOf(path('src')), GitMark.modified);
    expect(status.insideOf(path('docs')), GitMark.added);
    expect(GitRepos.cached(repo), same(status));
  }, skip: hasGit ? false : 'git is not on the PATH');

  test('a run that takes too long is stopped, and the repo left alone a while', () async {
    final repo = await makeRepo(temp.path, 'slow');
    GitRepos.timeout = Duration.zero;
    addTearDown(() => GitRepos.timeout = const Duration(seconds: 5));
    expect(await GitRepos.load(repo), isNull);
    GitRepos.timeout = const Duration(seconds: 5);
    expect(await GitRepos.load(repo), isNull, reason: 'still resting');
  }, skip: hasGit ? false : 'git is not on the PATH');

  test('the controller follows the folder, and shows nothing outside a repo or when off', () async {
    final repo = await makeRepo(temp.path, 'project');
    await writeFile(repo, 'a.txt', 'x');
    final outside = Directory(p.join(temp.path, 'outside'))..createSync();
    GitStatusController.runInTests = true;
    addTearDown(() => GitStatusController.runInTests = false);
    final git = GitStatusController(debounce: const Duration(milliseconds: 10));
    addTearDown(git.close);

    Future<void> settle() async {
      for (var i = 0; i < 100 && git.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    git.show(repo);
    await settle();
    expect(git.value?.branch, 'main');
    expect(git.value?.markFor(p.join(repo, 'a.txt')), GitMark.untracked);

    git.show(outside.path);
    expect(git.value, isNull);

    git.show(repo);
    expect(git.value, isNotNull, reason: 'the last status shows at once');

    await GitStatusSettings.instance.set(false);
    expect(git.value, isNull, reason: 'turned off');
    git.show(repo);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(git.value, isNull);
    expect((await SharedPreferences.getInstance()).getBool('git_status'), isFalse);
  }, skip: hasGit ? false : 'git is not on the PATH');
}
