import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/formats/archive_open.dart';
import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/compress/compress_job.dart';
import 'package:folders/features/file_explorere/widgets/compress_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The Compress dialog, and compressing from it in the background.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('explorer_compress_dialog');
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    BackgroundTasks.instance.reset();
    root.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// A button that opens the dialog; what it chose lands in [chosen].
  Future<List<CompressChoice?>> open(WidgetTester tester, {Size size = const Size(1200, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final chosen = <CompressChoice?>[];
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () async => chosen.add(await CompressDialog.show(context, initialName: 'Holiday', count: 3)),
            child: const Text('Go'),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('Go'));
    await settle(tester);
    expect(find.text('Compress 3 items'), findsOneWidget);
    return chosen;
  }

  Future<void> pick(WidgetTester tester, String current, String choice) async {
    await tester.tap(find.text(current).last);
    await settle(tester);
    await tester.tap(find.text(choice).last);
    await settle(tester);
  }

  testWidgets('a 7z with a password, its names hidden, in parts of 100 MB', (tester) async {
    final chosen = await open(tester);
    expect(find.text('.zip'), findsOneWidget, reason: 'ZIP at first');
    await pick(tester, 'ZIP', '7z');
    expect(find.text('.7z'), findsOneWidget);
    await tester.tap(find.text('Best'));
    await tester.enterText(find.widgetWithText(TextField, 'None'), 'secret');
    await settle(tester);
    expect(find.text('Encrypt file names'), findsOneWidget);
    await pick(tester, "Don't split", '100 MB');
    await tester.tap(find.widgetWithText(FilledButton, 'Compress'));
    await settle(tester);

    final choice = chosen.single!;
    expect(choice.name, 'Holiday.7z');
    expect(choice.options.kind, ArchiveKind.sevenZip);
    expect(choice.options.level, CompressLevel.best);
    expect(choice.options.password, 'secret');
    expect(choice.options.encryptNames, isTrue);
    expect(choice.options.volumeSize, 100 * 1000 * 1000);
  });

  testWidgets('a TAR has no password and no levels; a custom part size is checked', (tester) async {
    final chosen = await open(tester);
    await pick(tester, 'ZIP', 'TAR');
    expect(find.text('Only ZIP and 7z can have a password.'), findsOneWidget);
    expect(find.text('Normal'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField).at(1)).enabled, isFalse);

    await pick(tester, "Don't split", 'Other size…');
    await tester.enterText(find.widgetWithText(TextField, 'Each part'), '0.00001');
    await settle(tester);
    expect(find.text('Parts must be at least 64 KB'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Compress')).onPressed, isNull);
    await tester.enterText(find.widgetWithText(TextField, 'Each part'), '2');
    await tester.tap(find.text('MB'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Compress'));
    await settle(tester);
    expect(chosen.single!.name, 'Holiday.tar');
    expect(chosen.single!.options.volumeSize, 2 * 1000 * 1000);
    expect(chosen.single!.options.password, isNull);
  });

  testWidgets('works as a sheet on a phone', (tester) async {
    await open(tester, size: const Size(390, 844));
    expect(find.text('Compression'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Compress makes the archive in the background, folders and all', (tester) async {
    await tester.runAsync(() async {
      File(p.join(root.path, 'Trip', 'day 1.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('the beach ' * 500);
      File(p.join(root.path, 'Trip', 'Photos', 'sea.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.generate(5000, (i) => i * 7 & 0xFF));
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var done = false;
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => FilledButton(
          onPressed: () => CompressActions.compressWith(
            context,
            [p.join(root.path, 'Trip')],
            root.path,
            onDone: () => done = true,
          ),
          child: const Text('Go'),
        ),
      ),
    )));
    await tester.tap(find.text('Go'));
    await settle(tester);
    expect(find.text('Compress'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Compress'));
    await settle(tester);
    expect(find.textContaining('in the background'), findsOneWidget);
    for (var i = 0; i < 100 && !done; i++) {
      await settle(tester);
    }
    expect(done, isTrue);
    final task = BackgroundTasks.instance.all.single;
    expect(task.status, TaskStatus.done);
    final archive = p.join(root.path, 'Trip.zip');
    expect(task.outputs, [archive]);
    await tester.runAsync(() async {
      final opened = await openArchive(archive);
      final names = opened.backend.entries.map((e) => e.path.replaceAll(r'\', '/')).toSet();
      await opened.backend.close();
      expect(names, containsAll(['Trip/day 1.txt', 'Trip/Photos/sea.jpg']));
    });
  });
}
