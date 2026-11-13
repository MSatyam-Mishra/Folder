import 'package:flutter_test/flutter_test.dart';
import 'package:folders/features/git_status/git_porcelain.dart';

/// `git status --porcelain=v2 -z --branch --ignored`, read.
void main() {
  // Records end in NUL; a rename's old path is a record of its own.
  final output = [
    '# branch.oid 1234567890abcdef1234567890abcdef12345678',
    '# branch.head feature/tags',
    '# branch.upstream origin/feature/tags',
    '# branch.ab +2 -1',
    '1 .M N... 100644 100644 100644 aaaa bbbb src/app.dart',
    '1 M. N... 100644 100644 100644 aaaa bbbb README.md',
    '1 A. N... 000000 100644 100644 0000 bbbb docs/new guide.md',
    '1 AM N... 000000 100644 100644 0000 bbbb docs/started.md',
    '1 .D N... 100644 100644 000000 aaaa aaaa old/gone.txt',
    '2 R. N... 100644 100644 100644 aaaa aaaa R100 lib/renamed name.dart',
    'lib/old name.dart',
    'u UU N... 100644 100644 100644 100644 aaaa bbbb cccc deep/a/b/conflict.txt',
    '? notes.txt',
    '? drafts/',
    '! build/',
    '! .env',
    '',
  ].join('\x00');

  GitStatus parse({bool caseSensitive = true, String root = '/repo'}) =>
      GitStatus.parse(output, root: root, caseSensitive: caseSensitive);

  test('the branch, its upstream and how far apart they are', () {
    final status = parse();
    expect(status.branch, 'feature/tags');
    expect(status.label, 'feature/tags');
    expect(status.commit, startsWith('1234567'));
    expect(status.upstream, 'origin/feature/tags');
    expect(status.ahead, 2);
    expect(status.behind, 1);
  });

  test("each item's own mark", () {
    final status = parse();
    expect(status.markFor('/repo/src/app.dart'), GitMark.modified);
    expect(status.markFor('/repo/README.md'), GitMark.staged);
    expect(status.markFor('/repo/docs/new guide.md'), GitMark.added, reason: 'spaces in the name');
    expect(status.markFor('/repo/docs/started.md'), GitMark.added, reason: 'new and staged, changed since');
    expect(status.markFor('/repo/lib/renamed name.dart'), GitMark.renamed);
    expect(status.markFor('/repo/deep/a/b/conflict.txt'), GitMark.conflicted);
    expect(status.markFor('/repo/notes.txt'), GitMark.untracked);
    expect(status.markFor('/repo/drafts'), GitMark.untracked, reason: 'a new folder');
    expect(status.markFor('/repo/drafts/idea.md'), GitMark.untracked, reason: 'inside a new folder');
    expect(status.markFor('/repo/build'), GitMark.ignored);
    expect(status.markFor('/repo/build/out/app.exe'), GitMark.ignored, reason: 'inside an ignored folder');
    expect(status.markFor('/repo/.env'), GitMark.ignored);
    expect(status.markFor('/repo/src/other.dart'), isNull, reason: 'unchanged');
    expect(status.markFor('/repo'), isNull, reason: 'the work tree itself');
    expect(status.markFor('/elsewhere/app.dart'), isNull);
    expect(status.markFor('/repository/src/app.dart'), isNull, reason: 'a folder starting with the same name');
    expect(status.changeCount, 9);
  });

  test('folders with changes inside get the weightiest one', () {
    final status = parse();
    expect(status.insideOf('/repo/src'), GitMark.modified);
    expect(status.insideOf('/repo/docs'), GitMark.added);
    expect(status.insideOf('/repo/old'), GitMark.modified, reason: 'a file deleted in it');
    expect(status.insideOf('/repo/lib'), GitMark.renamed);
    expect(status.insideOf('/repo/deep'), GitMark.conflicted);
    expect(status.insideOf('/repo/deep/a/b'), GitMark.conflicted);
    expect(status.insideOf('/repo/build'), isNull, reason: 'ignored things are no change');
    expect(status.insideOf('/repo/drafts'), isNull);
  });

  test("Windows paths, where case doesn't matter", () {
    final status = parse(caseSensitive: false, root: r'C:\Code\Repo');
    expect(status.markFor(r'C:\code\repo\SRC\App.dart'), GitMark.modified);
    expect(status.insideOf(r'C:\Code\Repo\deep\a'), GitMark.conflicted);
    expect(status.markFor(r'C:\Code\Repo\build\x.obj'), GitMark.ignored);
    expect(status.markFor(r'C:\Code\Repo\'), isNull);
  });

  test('a detached head shows its commit; a new repo has no commit yet', () {
    final detached = GitStatus.parse(
      '# branch.oid abcdef0123456789\x00# branch.head (detached)\x00',
      root: '/r',
      caseSensitive: true,
    );
    expect(detached.branch, isNull);
    expect(detached.label, 'abcdef0');
    final fresh = GitStatus.parse('# branch.oid (initial)\x00# branch.head main\x00? a.txt\x00', root: '/r', caseSensitive: true);
    expect(fresh.commit, isNull);
    expect(fresh.label, 'main');
    expect(fresh.markFor('/r/a.txt'), GitMark.untracked);
  });

  test('odd records are skipped', () {
    final status = GitStatus.parse('1 .M\x00?\x00# branch.head\x00garbage\x00', root: '/r', caseSensitive: true);
    expect(status.changeCount, 0);
    expect(status.branch, isNull);
  });
}
