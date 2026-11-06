@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/bloc/folder_search.dart';
import 'package:folders/features/file_explorere/bloc/grouping.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// On macOS packages (apps, installers, document packages) look, sort and
/// search like files, as in Finder.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('explorer_packages_test');
  });

  tearDown(() => root.delete(recursive: true));

  Future<File> file(String relative) async =>
      File(p.join(root.path, relative)).create(recursive: true);
  Future<Directory> folder(String relative) async =>
      Directory(p.join(root.path, relative)).create(recursive: true);
  List<String> names(Iterable<FileSystemEntity> entities) =>
      [for (final e in entities) p.basename(e.path)];

  test('kind says what a package is', () {
    expect(EntityFormat.kind(Directory('/Applications/Safari.app')), 'Application');
    expect(EntityFormat.kind(Directory('/Volumes/Setup/Setup.mpkg')), 'Installer package');
    expect(EntityFormat.kind(File('/Users/me/Downloads/Setup.pkg')), 'Installer package',
        reason: 'flat installers are files');
    expect(EntityFormat.kind(Directory('/Users/me/Dev/Runner.xcodeproj')), 'Xcode project');
    expect(EntityFormat.kind(Directory('/Users/me/Docs/Swift.docset')), 'Documentation set');
    expect(EntityFormat.kind(Directory('/Users/me/Music/Song.band')), 'GarageBand project');
    expect(EntityFormat.kind(Directory('/Library/Frameworks/Python.framework')), 'Folder');
    expect(EntityFormat.kind(File('/Users/me/report.pdf')), 'PDF document');
    expect(EntityFormat.isPackage(File('/Users/me/notes.app')), isFalse);
  });

  test('every package type has a name, not just "Package"', () {
    for (final ext in {...FileTypes.macPackage, ...FileTypes.macInstaller}) {
      expect(EntityFormat.kind(Directory('/Users/me/Thing.$ext')), isNot('Package'), reason: ext);
    }
  });

  test('packages sort among the files, folders first', () async {
    SharedPreferences.setMockInitialValues({});
    await folder('alpha');
    await folder('Zeta.app/Contents');
    await folder('Mid.pkg');
    await folder('Notes.rtfd');
    await file('beta.txt');
    await (await file('gamma.pdf')).writeAsString('pdf');
    final bloc = FileExplorerBloc(watchFolders: false);
    addTearDown(bloc.close);

    bloc.add(LoadDirectory(root.path));
    final loaded = await bloc.stream.firstWhere((s) => s is FileExplorerLoaded) as FileExplorerLoaded;
    expect(names(loaded.entities), ['alpha', 'beta.txt', 'gamma.pdf', 'Mid.pkg', 'Notes.rtfd', 'Zeta.app']);

    bloc.add(ChangeSortOrder(SortOption.type, SortOrder.ascending));
    final byType = await bloc.stream.firstWhere(
      (s) => s is FileExplorerLoaded && s.sortOption == SortOption.type,
    ) as FileExplorerLoaded;
    expect(names(byType.entities), ['alpha', 'Zeta.app', 'gamma.pdf', 'Mid.pkg', 'Notes.rtfd', 'beta.txt']);

    // Packages' size isn't known: they sort as smaller than empty files.
    const packages = {'Mid.pkg', 'Notes.rtfd', 'Zeta.app'};
    bloc.add(ChangeSortOrder(SortOption.size, SortOrder.ascending));
    final bySize = names((await bloc.stream.firstWhere(
      (s) => s is FileExplorerLoaded && s.sortOption == SortOption.size,
    ) as FileExplorerLoaded).entities);
    expect(bySize.first, 'alpha');
    expect(bySize.sublist(1, 4).toSet(), packages);
    expect(bySize.sublist(4), ['beta.txt', 'gamma.pdf']);

    bloc.add(ChangeSortOrder(SortOption.size, SortOrder.descending));
    final bySizeDown = names((await bloc.stream.firstWhere(
      (s) => s is FileExplorerLoaded && s.sortOrder == SortOrder.descending,
    ) as FileExplorerLoaded).entities);
    expect(bySizeDown.sublist(0, 3), ['alpha', 'gamma.pdf', 'beta.txt']);
    expect(bySizeDown.sublist(3).toSet(), packages);
  });

  test('grouped, packages get their own headings after folders', () async {
    final entities = <FileSystemEntity>[
      await folder('Music'),
      await folder('Safari.app'),
      await folder('Setup.pkg'),
      await file('notes.txt'),
    ];
    final groups = await groupEntities(entities, GroupBy.type, stat: (e) => e.stat());
    expect({for (final g in groups) g.label: names(g.entities)}, {
      'Folder': ['Music'],
      'Application': ['Safari.app'],
      'Installer package': ['Setup.pkg'],
      'Text': ['notes.txt'],
    });
    expect(groups.first.label, 'Folder');

    final bySize = await groupEntities(entities, GroupBy.size, stat: (e) => e.stat());
    expect({for (final g in bySize) g.label: names(g.entities)}, {
      'Folders': ['Music'],
      'Size not known': ['Safari.app', 'Setup.pkg'],
      'Empty': ['notes.txt'],
    });
    expect([for (final g in bySize) g.label], ['Folders', 'Size not known', 'Empty']);
  });

  test('search lists packages but not what is inside them', () async {
    await file('Apps/Safari.app/Contents/MacOS/Safari');
    await file('Apps/Safari.app/Contents/Info.plist');
    await file('Docs/report.rtfd/TXT.rtf');
    await file('Docs/2025/report.txt');
    await file('Top.app/Contents/report.log');

    Future<List<String>> search(String query) async => [
          await for (final batch in searchSubfolders(root.path, query))
            for (final e in batch) p.relative(e.path, from: root.path),
        ];
    expect(await search('safari'), ['Apps/Safari.app']);
    expect(await search('info'), isEmpty);
    expect(await search('report'), ['Docs/report.rtfd', 'Docs/2025/report.txt'],
        reason: "packages in the searched folder itself aren't searched either");

    final found = [
      await for (final batch in searchSubfolders(root.path, 'safari')) ...batch,
    ];
    expect(found.single, isA<Directory>(), reason: 'still a folder, shown as a package');
  });

  test('the Documents walk skips what is inside packages', () async {
    await file('Docs/a.pdf');
    await file('Docs/Deep/b.pdf');
    await file('Tools/Helper.app/Contents/Resources/manual.pdf');
    await file('Docs/Notes.rtfd/TXT.txt');
    final found = DeviceFiles.walk([root.path], {'pdf', 'txt'});
    expect(found.map((f) => f.name).toSet(), {'a.pdf', 'b.pdf'});
  });

  testWidgets('an app gets a file icon; a framework stays a folder', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(themedApp(Column(children: [
      EntityIcon(entity: Directory('/Applications/Safari.app')),
      EntityIcon(entity: File('/Users/me/Downloads/Setup.pkg')),
      EntityIcon(entity: Directory('/Library/Frameworks/Python.framework')),
    ])));
    final icons = tester.widgetList<FileIcon>(find.byType(FileIcon)).toList();
    expect([for (final i in icons) (i.isDirectory, i.isPackage)], [
      (false, true),
      (false, true),
      (true, false),
    ]);
    expect(find.byType(FolderIcon), findsOneWidget);
  });
}
