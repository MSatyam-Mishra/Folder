import 'dart:io';

import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/panes/dual_pane.dart';
import 'package:folders/features/panes/pane_settings.dart';
import 'package:folders/features/panes/preview_pane.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The preview pane, right of the files (computers, wide tablets).
void main() {
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PaneSettings.instance.reset();
    ExplorerTabs.instance.reset();
    root = await Directory.systemTemp.createTemp('explorer_preview');
    await Directory(p.join(root.path, 'Album')).create();
    await File(p.join(root.path, 'Album', 'one.txt')).writeAsString('1');
    await File(p.join(root.path, 'Album', 'two.txt')).writeAsString('2');
    await File(p.join(root.path, 'notes.txt')).writeAsString('First line of the notes\nSecond line\nThird line\n');
    await File(p.join(root.path, 'data.bin')).writeAsBytes(List.filled(2048, 7));
    await File(p.join(root.path, 'dot.png')).writeAsBytes(img.encodePng(img.Image(width: 4, height: 3)));
  });

  tearDown(() async {
    ExplorerTabs.instance.reset();
    PaneSettings.instance.reset();
    await root.delete(recursive: true);
  });

  /// Closes the window, and lets the settings' delayed save happen.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> settle(WidgetTester tester, {int times = 6}) async {
    for (var i = 0; i < times; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await settle(tester);
  }

  Future<DualPaneController> open(WidgetTester tester, {Size size = const Size(1400, 860)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    await waitFor(tester, () => find.text('notes.txt').evaluate().isNotEmpty);
    return DualPanes.read(tester.element(find.text('notes.txt')))!;
  }

  Future<void> altP(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await settle(tester);
  }

  Future<void> click(WidgetTester tester, Finder finder, {bool control = false}) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(finder, kind: PointerDeviceKind.mouse);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 320)));
    await settle(tester);
  }

  Finder inPreview(Finder finder) => find.descendant(of: find.byType(PreviewPane), matching: finder);

  testWidgets('Alt+P shows and hides it; with nothing selected it shows the folder', (tester) async {
    await open(tester);
    expect(find.byType(PreviewPane), findsNothing);
    await altP(tester);
    expect(find.byType(PreviewPane), findsOneWidget);
    expect(PaneSettings.instance.preview, isTrue);
    expect(inPreview(find.text('1 folder · 3 files')), findsOneWidget);
    expect(inPreview(find.text('Calculate')), findsOneWidget);
    await altP(tester);
    expect(find.byType(PreviewPane), findsNothing);
    expect(PaneSettings.instance.preview, isFalse);
    await finish(tester);
  });

  testWidgets('the header button switches it, and it is kept', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Preview pane (Alt+P)'), kind: PointerDeviceKind.mouse);
    await settle(tester);
    expect(find.byType(PreviewPane), findsOneWidget);
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getBool('preview_pane'), isTrue);
    await finish(tester);
  });

  testWidgets('a text file shows its first lines, details and actions', (tester) async {
    await open(tester);
    await altP(tester);
    await click(tester, find.text('notes.txt'));
    await waitFor(tester, () => inPreview(find.textContaining('First line of the notes')).evaluate().isNotEmpty);
    expect(inPreview(find.textContaining('First line of the notes')), findsOneWidget);
    expect(inPreview(find.text('Open')), findsOneWidget);
    expect(inPreview(find.text('Copy path')), findsOneWidget);
    expect(inPreview(find.text('Details')), findsOneWidget);
    expect(inPreview(find.text('Lines')), findsOneWidget);
    expect(inPreview(find.text('3')), findsOneWidget);
    expect(inPreview(find.text(root.path)), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a picture shows with its size in pixels', (tester) async {
    await open(tester);
    await altP(tester);
    await click(tester, find.text('dot.png'));
    await waitFor(tester, () => inPreview(find.text('4 × 3 pixels')).evaluate().isNotEmpty);
    expect(inPreview(find.text('4 × 3 pixels')), findsOneWidget);
    expect(inPreview(find.byType(Image)), findsWidgets);
    await finish(tester);
  });

  testWidgets('a folder shows how many items it holds, and its size when asked', (tester) async {
    await open(tester);
    await altP(tester);
    await click(tester, find.text('Album'));
    await waitFor(tester, () => inPreview(find.text('2 files')).evaluate().isNotEmpty);
    expect(inPreview(find.text('2 files')), findsOneWidget);
    await tester.tap(inPreview(find.text('Calculate')), kind: PointerDeviceKind.mouse);
    await waitFor(tester, () => inPreview(find.textContaining('2 B')).evaluate().isNotEmpty);
    expect(inPreview(find.text('2 B · 2 files')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('several items show how many and how big', (tester) async {
    await open(tester);
    await altP(tester);
    await click(tester, find.text('notes.txt'));
    await click(tester, find.text('data.bin'), control: true);
    await waitFor(tester, () => inPreview(find.text('2 items selected')).evaluate().isNotEmpty);
    expect(inPreview(find.text('2 items selected')), findsOneWidget);
    expect(inPreview(find.text('2 files')), findsOneWidget);
    expect(inPreview(find.text('Copy paths')), findsOneWidget);
    final total = EntityFormat.size(2048 + File(p.join(root.path, 'notes.txt')).lengthSync());
    await waitFor(tester, () => inPreview(find.text(total)).evaluate().isNotEmpty);
    expect(inPreview(find.text(total)), findsOneWidget);
    await finish(tester);
  });

  testWidgets('its border is dragged to resize it, and the width is kept', (tester) async {
    await open(tester);
    await altP(tester);
    final before = tester.getSize(find.byType(PreviewPane)).width;
    expect(before, PaneSettings.previewUsual);
    final edge = tester.getTopLeft(find.byType(PreviewPane)) + const Offset(0, 300);
    final mouse = await tester.startGesture(edge, kind: PointerDeviceKind.mouse);
    await mouse.moveBy(const Offset(-40, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(-40, 0));
    await tester.pump();
    await mouse.up();
    await settle(tester);
    expect(tester.getSize(find.byType(PreviewPane)).width, closeTo(before + 80, 1));
    // Kept a moment later.
    await tester.pump(const Duration(milliseconds: 500));
    await settle(tester);
    final prefs = await tester.runAsync(SharedPreferences.getInstance);
    expect(prefs!.getDouble('preview_pane_width'), closeTo(before + 80, 1));
    await finish(tester);
  });

  testWidgets('with two panes it follows the active one', (tester) async {
    final panes = await open(tester, size: const Size(1600, 900));
    await altP(tester);
    panes.open();
    await waitFor(tester, () => panes.second != null && find.text('notes.txt').evaluate().length >= 2);
    panes.second!.add(LoadDirectory(p.join(root.path, 'Album')));
    await waitFor(tester, () => find.text('one.txt').evaluate().isNotEmpty);
    await click(tester, find.text('notes.txt').first);
    await waitFor(tester, () => inPreview(find.text('notes.txt')).evaluate().isNotEmpty);
    expect(inPreview(find.text('notes.txt')), findsOneWidget);
    await click(tester, find.text('one.txt'));
    expect(panes.active, 1);
    await waitFor(tester, () => inPreview(find.text('one.txt')).evaluate().isNotEmpty);
    expect(inPreview(find.text('one.txt')), findsOneWidget);
    expect(inPreview(find.text('notes.txt')), findsNothing);
    // Tab back: the first pane's selection shows again.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester);
    expect(panes.active, 0);
    expect(inPreview(find.text('notes.txt')), findsOneWidget);
    await finish(tester);
  });

  testWidgets("a window too narrow for it doesn't show it", (tester) async {
    PaneSettings.instance.setPreview(true);
    // No room for 240 beside the page's 360.
    await open(tester, size: const Size(580, 800));
    expect(find.byType(PreviewPane), findsNothing);
    expect(find.byTooltip('Preview pane (Alt+P)'), findsNothing);
    await finish(tester);
  });
}
