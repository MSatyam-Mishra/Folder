import 'dart:io';

import 'package:folder/core/platform/explorer_paths.dart';
import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folder/features/file_explorere/explorer_zoom.dart';
import 'package:folder/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folder/features/file_explorere/widgets/file_grid_item.dart';
import 'package:folder/features/file_explorere/widgets/file_list_item.dart';
import 'package:folder/shared/file_icons/file_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Zooming the file list: icons grow with their rows and tiles.
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('explorer_zoom_test');
    await Directory(p.join(root.path, 'Docs')).create();
    await File(p.join(root.path, 'notes.txt')).writeAsString('notes');
    ExplorerPaths.startFolder = root.path;
  });

  tearDown(() async {
    ExplorerPaths.startFolder = null;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// To [zoom], past the moment it's saved.
  Future<void> zoomTo(WidgetTester tester, double zoom) async {
    ExplorerZoom.instance.set(zoom);
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
  }

  for (final (mode, itemType) in [
    (ViewMode.list, FileListItem),
    (ViewMode.compact, FileListItem),
    (ViewMode.grid, FileGridItem),
    (ViewMode.gallery, FileGridItem),
  ]) {
    testWidgets('${mode.name}: the folder icon grows with its item', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(const FileExplorerScreen()));
      await settle(tester);
      final bloc = BlocProvider.of<FileExplorerBloc>(tester.element(find.byType(Scaffold).first));
      for (var i = 0; i < 40 && bloc.state is! FileExplorerLoaded; i++) {
        await settle(tester);
      }
      bloc.add(ChangeViewMode(mode));
      await settle(tester);

      final folder = find.descendant(of: find.byType(itemType), matching: find.byType(FolderIcon)).first;
      final item = find.ancestor(of: find.text('Docs'), matching: find.byType(itemType)).first;
      final usualIcon = tester.getSize(folder).width;
      final usualItem = tester.getSize(item).height;

      await zoomTo(tester, 2);
      final bigIcon = tester.getSize(folder).width;
      expect(bigIcon, greaterThanOrEqualTo(usualIcon * 1.9), reason: 'the icon itself grows');
      expect(tester.getSize(item).height, greaterThan(usualItem));
      expect(bigIcon / tester.getSize(item).height, greaterThanOrEqualTo(usualIcon / usualItem * 0.95),
          reason: 'the icon keeps its share of the item');

      // Further still, a bigger icon again.
      await zoomTo(tester, 3);
      expect(tester.getSize(folder).width, greaterThan(bigIcon));

      await zoomTo(tester, 0.75);
      expect(tester.getSize(folder).width, lessThan(usualIcon));
      await zoomTo(tester, 1);
      expect(tester.getSize(folder).width, moreOrLessEquals(usualIcon, epsilon: 0.01));
      expect(tester.takeException(), isNull);
    });
  }

  group('ZoomedGridDelegate', () {
    SliverConstraints across(double width) => SliverConstraints(
          axisDirection: AxisDirection.down,
          growthDirection: GrowthDirection.forward,
          userScrollDirection: ScrollDirection.idle,
          scrollOffset: 0,
          precedingScrollExtent: 0,
          overlap: 0,
          remainingPaintExtent: 800,
          crossAxisExtent: width,
          crossAxisDirection: AxisDirection.right,
          viewportMainAxisExtent: 800,
          remainingCacheExtent: 800,
          cacheOrigin: 0,
        );

    SliverGridRegularTileLayout layout(double width, double zoom, {double maxTile = 144}) =>
        ZoomedGridDelegate(maxTile: maxTile, aspectRatio: 0.84, spacing: 12, zoom: zoom).getLayout(across(width))
            as SliverGridRegularTileLayout;

    test('at 100% it is the usual grid, at any width', () {
      for (final width in [320.0, 358.0, 700.0, 950.0, 951.5, 1600.0, 2560.0]) {
        final usual = const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 144,
          childAspectRatio: 0.84,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ).getLayout(across(width)) as SliverGridRegularTileLayout;
        final zoomed = layout(width, 1);
        expect(zoomed.crossAxisCount, usual.crossAxisCount, reason: '$width wide');
        expect(zoomed.childCrossAxisExtent, moreOrLessEquals(usual.childCrossAxisExtent), reason: '$width wide');
        expect(zoomed.crossAxisStride, moreOrLessEquals(usual.crossAxisStride), reason: '$width wide');
      }
    });

    test('tiles fill the row at any zoom and width, with no gap at its end', () {
      for (final width in [358.0, 392.0, 700.0, 950.0, 1600.0]) {
        var before = 0.0;
        for (var zoom = 0.75; zoom <= 3; zoom *= 1.15) {
          final grid = layout(width, zoom);
          expect(grid.childCrossAxisExtent, greaterThanOrEqualTo(before), reason: 'never smaller on zooming in');
          before = grid.childCrossAxisExtent;
          expect(grid.crossAxisStride, moreOrLessEquals(grid.childCrossAxisExtent + 12), reason: 'zoom $zoom');
          final end = grid.crossAxisStride * (grid.crossAxisCount - 1) + grid.childCrossAxisExtent;
          expect(end, moreOrLessEquals(width), reason: '$width wide at zoom $zoom');
        }
      }
    });

    test('zooming changes how many fit in a row', () {
      expect(layout(950, 0.75).crossAxisCount, greaterThan(layout(950, 1).crossAxisCount));
      expect(layout(950, 2).crossAxisCount, lessThan(layout(950, 1).crossAxisCount));
    });

    test('a tile is never wider than the window', () {
      final grid = layout(300, 3);
      expect(grid.crossAxisCount, 1);
      expect(grid.childCrossAxisExtent, lessThanOrEqualTo(300));
    });
  });
}
