import 'dart:io';

import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/clipboard/bloc/clipboard_bloc.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folder/features/tasks/bloc/task_progress_bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/screenshots.dart';
import '../support/themed_app.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
void main() {
  late Directory root;
  late Directory sample;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    // The folder and its parents show in the title and breadcrumbs, so
    // they get names like on a phone.
    root = Directory(p.join(Directory.systemTemp.path, 'Phone'));
    if (await root.exists()) await root.delete(recursive: true);
    sample = await Directory(
      p.join(root.path, 'Internal storage', 'My files'),
    ).create(recursive: true);
    for (final d in ['Documents', 'Pictures', 'Music', 'Projects']) {
      await Directory(p.join(sample.path, d)).create();
    }
    await File(p.join(sample.path, 'Documents', 'Report draft.docx'))
        .writeAsBytes(List.filled(48 * 1024, 120));
    // Varied sizes (KB) and dates so the metadata looks realistic.
    const files = {
      'Quarterly report.pdf': 184, 'Meeting notes.docx': 32,
      'Budget 2026.xlsx': 46, 'Pitch deck.pptx': 1240, 'Holiday.jpg': 870,
      'Song.mp3': 2100, 'Trailer.mp4': 3900, 'Backup.zip': 640,
      'Novel.epub': 512, 'main.dart': 6, 'README.md': 3, 'data.json': 2,
      'Model.glb': 960, 'Photos.rar': 1500,
    };
    var i = 0;
    for (final MapEntry(key: name, value: kb) in files.entries) {
      final file = File(p.join(sample.path, name));
      await file.writeAsBytes(List.filled(kb * 1024, 120));
      await file.setLastModified(
        DateTime.now().subtract(Duration(hours: 5 + i * i * 13)),
      );
      i++;
    }
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await root.delete(recursive: true);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final (device, size) in [
      ('phone', const Size(390, 844)),
      ('tablet', const Size(1280, 800)),
    ]) {
      final tag = '${mode.name}_$device';
      testWidgets('explorer $tag', (tester) async {
        SharedPreferences.setMockInitialValues({});
        setScreenSize(tester, size);
        // Tests draw elevation shadows as solid outlines; show real ones.
        debugDisableShadows = false;
        await tester.pumpWidget(
          screenshotFrame(themedApp(const FileExplorerScreen(), themeMode: mode)),
        );
        await settle(tester);
        final context = tester.element(find.byType(Scaffold).first);
        final bloc = BlocProvider.of<FileExplorerBloc>(context);

        Future<void> open(String path) async {
          bloc.add(LoadDirectory(path));
          await settleUntil(tester, () {
            final s = bloc.state;
            return (s is FileExplorerLoaded && s.path == path) ||
                (s is FileExplorerError && s.path == path);
          });
        }

        Future<void> view(ViewMode m) async {
          bloc.add(ChangeViewMode(m));
          await settle(tester);
        }

        Future<void> dismiss() async {
          final nav = Navigator.of(
            tester.element(find.byType(Scaffold).first),
          );
          nav.pop();
          await settle(tester);
        }

        await open(sample.path);
        await saveScreenshot(tester, 'explorer_list_$tag');

        await view(ViewMode.grid);
        await saveScreenshot(tester, 'explorer_grid_$tag');
        await view(ViewMode.compact);
        await saveScreenshot(tester, 'explorer_compact_$tag');
        await view(ViewMode.gallery);
        await saveScreenshot(tester, 'explorer_gallery_$tag');
        await view(ViewMode.list);

        // Selection mode with a few items picked.
        final loaded = bloc.state as FileExplorerLoaded;
        bloc.add(ToggleSelectionMode(enable: true));
        for (final e in loaded.entities.skip(3).take(3)) {
          bloc.add(SelectItem(e));
        }
        await settle(tester);
        await saveScreenshot(tester, 'explorer_selection_$tag');
        bloc.add(ToggleSelectionMode(enable: false));
        await settle(tester);

        if (device == 'phone') {
          await tester.tap(find.byTooltip('Open menu').first);
          await settle(tester);
          await saveScreenshot(tester, 'drawer_$tag');
          Navigator.of(tester.element(find.byType(Drawer))).pop();
          await settle(tester);
        }

        final options = find.byTooltip('Options');
        if (options.evaluate().isNotEmpty) {
          await tester.tap(options.first);
          await settle(tester);
          await saveScreenshot(tester, 'options_$tag');
          await dismiss();
        }

        final pdf = loaded.entities.firstWhere(
          (e) => e.path.endsWith('.pdf'),
        );
        fileActionsService.showFileOptionsMenu(context, pdf);
        await settle(tester);
        await saveScreenshot(tester, 'file_actions_$tag');
        await dismiss();

        fileActionsService.showInfoSheet(pdf, context);
        await settle(tester);
        await saveScreenshot(tester, 'properties_$tag');
        await dismiss();

        fileActionsService.showDeleteConfirmationDialog(context, pdf);
        await settle(tester);
        await saveScreenshot(tester, 'delete_dialog_$tag');
        await dismiss();

        fileActionsService.showRenameDialog(context, pdf);
        await settle(tester);
        await saveScreenshot(tester, 'rename_dialog_$tag');
        await dismiss();

        // Something on the clipboard, then a running copy.
        final clipboard = BlocProvider.of<ClipboardBloc>(context);
        clipboard.add(CopyToClipboard([pdf]));
        await settle(tester);
        await saveScreenshot(tester, 'explorer_paste_$tag');
        final tasks = BlocProvider.of<TaskProgressBloc>(context);
        tasks
          ..add(TaskStarted(
            title: 'Copying',
            initialMessage: 'Copying "Quarterly report.pdf"',
          ))
          ..add(TaskProgressUpdated(
            progress: 0.42,
            message: 'Copying "Quarterly report.pdf"',
          ));
        await settle(tester);
        await saveScreenshot(tester, 'explorer_progress_$tag');
        tasks.add(TaskEnded());
        clipboard.add(ClearClipboard());
        await settle(tester);

        await open(p.join(sample.path, 'Projects'));
        await saveScreenshot(tester, 'explorer_empty_$tag');

        await open(p.join(sample.path, 'Missing folder'));
        await saveScreenshot(tester, 'explorer_error_$tag');
        // Grouped by type, and searching.
        await open(sample.path);
        await view(ViewMode.list);
        bloc.add(ChangeGroupBy(GroupBy.type));
        await settle(tester);
        await saveScreenshot(tester, 'explorer_grouped_$tag');
        bloc.add(ChangeGroupBy(GroupBy.none));
        bloc.add(OpenSearch());
        await settle(tester);
        await tester.enterText(find.byType(TextField), 'report');
        await settleUntil(tester, () {
          final s = bloc.state;
          return s is FileExplorerLoaded && !s.searching;
        });
        await saveScreenshot(tester, 'explorer_search_$tag');
        bloc.add(CloseSearch());
        await settle(tester);

        debugDisableShadows = true;
      }, skip: !screenshotsEnabled);
    }
  }
}

/// Lets real I/O finish and animations run.
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Settles until [done], then a few more frames for follow-up I/O (stats).
Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 40 && !done(); i++) {
    await settle(tester, frames: 1);
  }
  await settle(tester, frames: 4);
}

