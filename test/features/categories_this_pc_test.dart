import 'dart:io';

import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/repositories/file_repository.dart';
import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:folder/shared/layout/sidebar_width.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Ctrl, or Cmd on macOS.
final commandKey = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

/// Categories as folders, This PC, the search box and the sidebar's width.
void main() {
  late Directory root;
  late Directory clips;
  final video = ExplorerPaths.categoryPath('Video');
  final realCategoryFiles = LocalFileRepository.categoryFiles;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_category_test');
    clips = await Directory(p.join(root.path, 'Clips')).create();
    for (final name in ['alpha.mp4', 'beta.mp4']) {
      await File(p.join(clips.path, name)).writeAsString(name);
    }
    LocalFileRepository.categoryFiles = (name) async => [
          if (name == 'Video')
            for (final e in clips.listSync()) e,
        ];
    ExplorerPaths.startFolder = root.path;
  });

  tearDown(() async {
    LocalFileRepository.categoryFiles = realCategoryFiles;
    ExplorerPaths.startFolder = null;
    SidebarWidth.instance.value = SidebarWidth.usual;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<FileExplorerBloc> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(const FileExplorerScreen()));
    await settle(tester);
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
      await settle(tester);
    }
    await settle(tester);
    return bloc;
  }

  Future<void> load(WidgetTester tester, FileExplorerBloc bloc, String path) async {
    bloc.add(LoadDirectory(path));
    bool ready() {
      final state = bloc.state;
      return state is FileExplorerLoaded && state.path == path;
    }

    for (var i = 0; i < 60 && !ready(); i++) {
      await settle(tester);
    }
    await settle(tester);
  }

  testWidgets('a category lists its files like a folder, without New folder', (tester) async {
    final bloc = await open(tester);
    await load(tester, bloc, video);
    final state = bloc.state as FileExplorerLoaded;
    expect(state.entities.map((e) => p.basename(e.path)), unorderedEquals(['alpha.mp4', 'beta.mp4']));
    expect(state.sortOption, SortOption.date, reason: 'newest first until changed');
    expect(state.sortOrder, SortOrder.descending);
    expect(find.text('Video'), findsWidgets);
    expect(find.text('New folder'), findsNothing);

    // The same right-click menu as a folder, plus where it really is.
    await tester.tap(find.text('alpha.mp4'), kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    // Two frames: the menu's opening animation starts on the first.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final item in ['Copy', 'Cut', 'Rename', 'Delete', 'Show in folder']) {
      expect(find.text(item), findsWidgets, reason: item);
    }
    await tester.tap(find.text('Show in folder'));
    await tester.pump(const Duration(milliseconds: 400));
    String? shown() {
      final state = bloc.state;
      return state is FileExplorerLoaded ? state.path : null;
    }

    for (var i = 0; i < 60 && shown() != clips.path; i++) {
      await settle(tester);
    }
    expect(shown(), clips.path);

    // Up from a category goes home.
    expect(ExplorerPaths.parentOf(video), ExplorerPaths.homePath);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing is pasted into a category; search looks only at its files', (tester) async {
    final bloc = await open(tester);
    await load(tester, bloc, video);
    await tester.sendKeyDownEvent(commandKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(commandKey);
    await settle(tester);
    expect((bloc.state as FileExplorerLoaded).path, video);

    bloc.add(OpenSearch());
    await settle(tester);
    bloc.add(SearchChanged('beta'));
    await settle(tester);
    final state = bloc.state as FileExplorerLoaded;
    expect(state.displayEntities.map((e) => p.basename(e.path)), ['beta.mp4']);
    expect(state.searching, isFalse, reason: 'no folder to search through');
    expect(tester.takeException(), isNull);
  });

  testWidgets('search opens ready to type, on the keyboard', (tester) async {
    final bloc = await open(tester);
    await tester.sendKeyDownEvent(commandKey);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(commandKey);
    await settle(tester);
    expect((bloc.state as FileExplorerLoaded).searchOpen, isTrue);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasPrimaryFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the sidebar is resized by dragging its border', (tester) async {
    await open(tester);
    double width() => tester.getSize(find.byType(DockedSidebar)).width;
    expect(width(), SidebarWidth.usual);
    await tester.dragFrom(const Offset(SidebarWidth.usual + 1, 400), const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    expect(width(), SidebarWidth.usual + 60);

    // Only so far either way.
    await tester.dragFrom(Offset(width() + 1, 400), const Offset(-500, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(width(), SidebarWidth.min);
    await tester.dragFrom(Offset(width() + 1, 400), const Offset(900, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(width(), SidebarWidth.max);

    // And kept.
    await tester.runAsync(() async {
      expect((await SharedPreferences.getInstance()).getDouble('sidebar_width'), SidebarWidth.max);
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('This PC: libraries and drives apart; nothing to delete there', (tester) async {
    final bloc = await open(tester);
    await load(tester, bloc, ExplorerPaths.windowsRoots);
    final state = bloc.state as FileExplorerLoaded;
    expect(state.entities, isNotEmpty);
    expect(find.text('Devices and drives'), findsOneWidget);
    expect(find.text('Libraries'), findsWidgets);
    expect(find.text('New folder'), findsNothing);

    final drive = state.entities.firstWhere((e) => ExplorerPaths.isDriveRoot(e.path));
    final name = state.labelFor(drive);
    await tester.tap(find.text(name).last, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open'), findsOneWidget);
    for (final item in ['Delete', 'Cut', 'Rename']) {
      expect(find.text(item), findsNothing, reason: item);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 400));

    // The Delete key does nothing here either.
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
