@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folder/features/viewer_text/screens/tabbed_text_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Find and replace shortcuts in the text editor on macOS.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('text_editor_keys');
    await File(p.join(dir.path, 'notes.txt')).writeAsString('hello\nworld\n');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    List<LogicalKeyboardKey> modifiers = const [],
  }) async {
    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await settle(tester);
  }

  testWidgets('Cmd+F finds and Cmd+Option+F replaces', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(themedApp(
      TabbedTextEditorScreen(initialFile: File(p.join(dir.path, 'notes.txt'))),
    ));
    await settle(tester);
    await tester.tap(find.byType(EditableText).first);
    await settle(tester);

    final findField = find.widgetWithText(TextField, 'Find');
    final replaceField = find.widgetWithText(TextField, 'Replace with');
    expect(findField, findsNothing);

    // Ctrl+F moves the cursor on macOS; it doesn't open find.
    await press(
      tester,
      LogicalKeyboardKey.keyF,
      modifiers: [LogicalKeyboardKey.controlLeft],
    );
    expect(findField, findsNothing);

    await press(
      tester,
      LogicalKeyboardKey.keyF,
      modifiers: [LogicalKeyboardKey.metaLeft],
    );
    expect(findField, findsOneWidget);
    expect(replaceField, findsNothing);

    await press(
      tester,
      LogicalKeyboardKey.keyF,
      modifiers: [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.altLeft],
    );
    expect(findField, findsOneWidget);
    expect(replaceField, findsOneWidget);
  });
}
