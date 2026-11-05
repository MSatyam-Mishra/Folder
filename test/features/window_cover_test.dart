import 'dart:io';

import 'package:folder/features/explorer_tabs/explorer_tabs.dart';
import 'package:folder/features/explorer_tabs/tabbed_explorer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show ShadAppBuilder;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// What paints a colour behind [element], window-side first, with the widget
/// each layer sits under (a [Material] paints through its PhysicalModel, so
/// that isn't counted again).
List<String> paintedBehind(Element element) {
  final layers = <String>[];
  String? pending;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    // The root's own: main.dart clears it while a window effect is on.
    if (widget is ShadAppBuilder) {
      layers.removeLast();
      return false;
    }
    if (pending != null) {
      layers.add('$pending under ${widget.runtimeType}');
      pending = null;
    }
    Color? color;
    if (widget is Material && widget.type != MaterialType.transparency) {
      color = widget.color ?? Theme.of(ancestor).canvasColor;
    } else if (widget is ColoredBox) {
      color = widget.color;
    }
    if (color != null && color.a > 0) {
      pending = '${widget.runtimeType} ${color.toARGB32().toRadixString(16)}';
    }
    return true;
  });
  return layers.reversed.toList();
}

/// With a window effect on, the app's backgrounds are see-through as set in
/// Options. Each one painted twice shows less than the setting says: at 75%,
/// four layers left 30% of what's behind the window.
void main() {
  testWidgets('one background behind a file and behind the sidebar', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final root = (await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('explorer_cover');
      await File(p.join(dir.path, 'notes.txt')).writeAsString('notes');
      return dir;
    }))!;
    addTearDown(() => tester.runAsync(() => root.delete(recursive: true)));
    ExplorerTabs.instance.reset();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: root.path)));
    for (var i = 0; i < 60 && find.text('notes.txt').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 300));

    final file = paintedBehind(find.text('notes.txt').first.evaluate().first);
    final sidebar = paintedBehind(find.text('Downloads').first.evaluate().first);
    expect(file, hasLength(1), reason: file.join('\n'));
    expect(sidebar, hasLength(1), reason: sidebar.join('\n'));
    await tester.pumpWidget(const SizedBox());
  });
}
