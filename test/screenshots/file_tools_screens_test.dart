import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/trash/spec_trash.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/file_explorere/widgets/batch_rename_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// Back and Forward, the Trash, the batch rename and checksums.
/// SCREENSHOTS=1 flutter test test/screenshots/file_tools_screens_test.dart
void main() {
  late Directory root;
  late Directory trashDir;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
  });

  setUp(() async {
    if (!screenshotsEnabled) return;
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('Holiday');
    trashDir = await Directory.systemTemp.createTemp('file_tools_trash');
    await Directory(p.join(root.path, 'Beach')).create();
    for (final name in ['IMG_2041.jpg', 'IMG_2042.jpg', 'IMG_2043.jpg', 'notes.txt', 'Trip 03.jpg', 'Itinerary.pdf']) {
      await File(p.join(root.path, name)).writeAsString('$name ' * 400);
    }
    await File(p.join(root.path, 'SHA256SUMS.txt')).writeAsString('');
    ExplorerPaths.startFolder = root.path;
    Trash.instance = SpecTrash.inFolder(trashDir.path);
  });

  tearDown(() async {
    if (!screenshotsEnabled) return;
    Trash.instance = const NoTrash();
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
    await trashDir.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, {int frames = 6}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<FileExplorerBloc> open(WidgetTester tester, Size size, ThemeMode mode) async {
    setScreenSize(tester, size);
    debugDisableShadows = false;
    await tester.pumpWidget(screenshotFrame(themedApp(const FileExplorerScreen(), themeMode: mode)));
    await settle(tester);
    final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
    await settle(tester, frames: 10);
    return bloc;
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('file tools ${mode.name}', (tester) async {
      final bloc = await open(tester, const Size(1280, 800), mode);
      // Some history: Back and Forward both lead somewhere.
      bloc.add(LoadDirectory(p.join(root.path, 'Beach')));
      await settle(tester);
      bloc.add(LoadDirectory(root.path));
      await settle(tester);
      bloc.history.back();
      bloc.add(LoadDirectory(p.join(root.path, 'Beach'), step: HistoryStep.keep));
      await settle(tester);
      bloc.history.forward();
      bloc.add(LoadDirectory(root.path, step: HistoryStep.keep));
      await settle(tester, frames: 8);
      await saveScreenshot(tester, 'file_tools_header_${mode.name}');

      // The batch rename.
      final state = bloc.state as FileExplorerLoaded;
      final photos = [for (final e in state.displayEntities) if (e.path.endsWith('.jpg') && !e.path.contains('Trip')) e];
      bloc.add(SetSelection(photos.toSet(), selectionMode: true));
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('batch-pattern')), 'Trip {n}');
      await tester.pump();
      await settle(tester, frames: 2);
      await saveScreenshot(tester, 'file_tools_batch_rename_${mode.name}');
      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await settle(tester);
      expect(find.byType(BatchRenameDialog), findsNothing);

      // Checksums in Properties.
      final notes = state.displayEntities.firstWhere((e) => e.path.endsWith('notes.txt'));
      bloc.add(SetSelection({notes}));
      await settle(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await settle(tester);
      await tester.tap(find.text('Calculate'));
      for (var i = 0; i < 40 && find.text('SHA-512').evaluate().isEmpty; i++) {
        await settle(tester, frames: 1);
      }
      await settle(tester);
      await saveScreenshot(tester, 'file_tools_checksums_${mode.name}');
      Navigator.of(tester.element(find.text('SHA-512'))).pop();
      await settle(tester);

      // The Trash.
      await tester.runAsync(() => Trash.instance.moveToTrash([
            p.join(root.path, 'Itinerary.pdf'),
            p.join(root.path, 'notes.txt'),
            p.join(root.path, 'Beach'),
          ]));
      bloc.add(LoadDirectory(ExplorerPaths.trash));
      await settle(tester, frames: 10);
      await saveScreenshot(tester, 'file_tools_trash_${mode.name}');
      debugDisableShadows = true;
    }, skip: !screenshotsEnabled);

    testWidgets('trash phone ${mode.name}', (tester) async {
      await tester.runAsync(() => Trash.instance.moveToTrash([
            p.join(root.path, 'Itinerary.pdf'),
            p.join(root.path, 'IMG_2041.jpg'),
          ]));
      final bloc = await open(tester, const Size(390, 844), mode);
      bloc.add(LoadDirectory(ExplorerPaths.trash));
      await settle(tester, frames: 10);
      await saveScreenshot(tester, 'file_tools_trash_phone_${mode.name}');
      debugDisableShadows = true;
    }, skip: !screenshotsEnabled);
  }
}
