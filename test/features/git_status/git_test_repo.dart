import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether git can be run here.
bool gitOnPath() {
  try {
    return Process.runSync('git', ['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Runs git in [repo] as a throwaway user, with no signing or hooks.
Future<ProcessResult> git(String repo, List<String> args, {bool allowFailure = false}) async {
  final result = await Process.run(
    'git',
    [
      '-c', 'user.name=Folders test',
      '-c', 'user.email=test@example.invalid',
      '-c', 'commit.gpgsign=false',
      '-c', 'core.hooksPath=${p.join(repo, '.no-hooks')}',
      '-c', 'core.autocrlf=false',
      ...args,
    ],
    workingDirectory: repo,
  );
  if (result.exitCode != 0 && !allowFailure) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result;
}

/// A new repo named [name] in [parent], on a branch called main.
Future<String> makeRepo(String parent, String name) async {
  final repo = p.join(parent, name);
  await Directory(repo).create(recursive: true);
  await git(repo, ['init', '-q', '-b', 'main']);
  return repo;
}

Future<void> writeFile(String repo, String relative, String content) async {
  final file = File(p.joinAll([repo, ...relative.split('/')]));
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

/// Deletes [dir]; git makes its objects read-only on Windows.
Future<void> deleteRepo(Directory dir) async {
  if (!dir.existsSync()) return;
  if (Platform.isWindows) {
    await Process.run('attrib', ['-R', '${dir.path}\\*', '/S', '/D']);
  }
  for (var i = 0; i < 5; i++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
