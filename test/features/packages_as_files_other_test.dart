@TestOn('!mac-os')
library;

import 'dart:io';

import 'package:folder/core/services/device_files.dart';
import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/bloc/folder_search.dart';
import 'package:folder/features/file_explorere/bloc/grouping.dart';
import 'package:folder/features/file_explorere/widgets/entity_meta.dart';
import 'package:folder/shared/file_icons/file_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Off macOS a folder named like a macOS package (Safari.app, Notes.rtfd)
/// is an ordinary folder: it looks, sorts and is searched like one.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('explorer_packages_other_test');
  });

  tearDown(() => root.delete(recursive: true));

  String path(String relative) => p.joinAll([root.path, ...relative.split('/')]);
  Future<File> file(String relative) async => File(path(relative)).create(recursive: true);
  Future<Directory> folder(String relative) async =>
      Directory(path(relative)).create(recursive: true);
  List<String> names(Iterable<FileSystemEntity> entities) =>
      [for (final e in entities) p.basename(e.path)];

  test('kind says Folder', () {
    final app = Directory(p.join('apps', 'Safari.app'));
    expect(EntityFormat.isPackage(app), isFalse);
    expect(EntityFormat.kind(app), 'Folder');
    expect(EntityFormat.kind(Directory(p.join('docs', 'Notes.rtfd'))), 'Folder');
    expect(EntityFormat.kind(File(p.join('downloads', 'Setup.pkg'))), isNot('Installer package'));
  });

  test('sorts and groups with the folders', () async {
    SharedPreferences.setMockInitialValues({});
    await folder('alpha');
    await folder('Safari.app/Contents');
    await folder('Notes.rtfd');
    await file('beta.txt');
    final bloc = FileExplorerBloc(watchFolders: false);
    addTearDown(bloc.close);

    bloc.add(LoadDirectory(root.path));
    final loaded = await bloc.stream.firstWhere((s) => s is FileExplorerLoaded) as FileExplorerLoaded;
    expect(names(loaded.entities), ['alpha', 'Notes.rtfd', 'Safari.app', 'beta.txt']);

    final entities = [Directory(path('Safari.app')), File(path('beta.txt'))];
    final byType = await groupEntities(entities, GroupBy.type, stat: (e) => e.stat());
    expect({for (final g in byType) g.label: names(g.entities)}['Folder'], ['Safari.app']);
    final bySize = await groupEntities(entities, GroupBy.size, stat: (e) => e.stat());
    expect({for (final g in bySize) g.label: names(g.entities)}['Folders'], ['Safari.app']);
  });

  test('search and the Documents walk look inside', () async {
    await file('Apps/Safari.app/Contents/Info.plist');
    await file('Tools/Helper.app/Contents/Resources/manual.pdf');

    final found = [
      await for (final batch in searchSubfolders(root.path, 'info'))
        for (final e in batch) p.relative(e.path, from: root.path),
    ];
    expect(found, [p.join('Apps', 'Safari.app', 'Contents', 'Info.plist')]);

    final walked = DeviceFiles.walk([root.path], {'pdf'});
    expect(walked.map((f) => f.name), ['manual.pdf']);
  });

  testWidgets('a folder named like an app keeps the folder icon', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(themedApp(EntityIcon(entity: Directory(p.join('apps', 'Safari.app')))));
    final icon = tester.widget<FileIcon>(find.byType(FileIcon));
    expect((icon.isDirectory, icon.isPackage), (true, false));
    expect(find.byType(FolderIcon), findsOneWidget);
  });
}
