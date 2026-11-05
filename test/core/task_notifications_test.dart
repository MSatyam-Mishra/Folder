import 'dart:io';

import 'package:explorer/core/services/background_tasks.dart';
import 'package:explorer/core/services/incoming_files.dart';
import 'package:explorer/core/services/task_notifications.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/features/network/screens/file_server_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// What goes on in the app, in the notification shade.
void main() {
  late List<(String, Map<String, Object?>)> sent;
  final tasks = BackgroundTasks.instance;
  final notices = TaskNotifications.instance;

  Iterable<Map<String, Object?>> shown() => sent.where((m) => m.$1 == 'show').map((m) => m.$2);
  Iterable<Object?> cancelled() => sent.where((m) => m.$1 == 'cancel').map((m) => m.$2['id']);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sent = [];
    tasks.reset();
    TaskNotifications.sender = (method, args) async => sent.add((method, args));
    TaskNotifications.inFrontOverride = true;
    notices.init();
  });

  tearDown(() {
    notices.reset();
    TaskNotifications.sender = null;
    TaskNotifications.inFrontOverride = null;
    tasks.reset();
  });

  testWidgets('a task over too quickly never shows', (tester) async {
    final task = tasks.start('Copying "a"');
    await tester.pump(const Duration(milliseconds: 1100));
    tasks.finish(task);
    await tester.pump(const Duration(seconds: 3));
    expect(shown(), isEmpty);
    expect(cancelled(), isEmpty);
  });

  testWidgets('a long one shows its headline, file, sizes and progress, and only when they change', (tester) async {
    final task = tasks.start('Copying 3 items', headline: 'Copy in progress', kind: TaskKind.copy, message: 'a.mp4');
    task.update(progress: 0.25, detail: '25.0 MB/100.0 MB');
    await tester.pump(const Duration(seconds: 2));
    expect(shown(), hasLength(1));
    expect(shown().single, containsPair('title', 'Copy in progress'));
    expect(shown().single, containsPair('name', 'a.mp4'));
    expect(shown().single, containsPair('detail', '25.0 MB/100.0 MB'));
    expect(shown().single, containsPair('progress', 0.25));
    expect(shown().single, containsPair('icon', 'copy'));
    expect(shown().single, containsPair('ongoing', true));

    await tester.pump(const Duration(seconds: 3));
    expect(shown(), hasLength(1), reason: 'nothing new to say');

    task.update(progress: 0.5);
    await tester.pump(const Duration(seconds: 1));
    expect(shown().last, containsPair('progress', 0.5));

    tasks.finish(task);
    await tester.pump(const Duration(seconds: 2));
    expect(cancelled(), hasLength(1));
    expect(shown().where((n) => n['ongoing'] == false), isEmpty, reason: "in front, the app's dock says it");
  });

  testWidgets("with the app in the background, it says how it ended", (tester) async {
    final done = tasks.start('Copying "a"', headline: 'Copy in progress', message: 'a');
    final failed = tasks.start('Converting 2 images', message: 'b');
    await tester.pump(const Duration(seconds: 2));
    TaskNotifications.inFrontOverride = false;
    tasks.finish(done, message: 'Done: Downloads');
    tasks.fail(failed, 'No room left');
    await tester.pump(const Duration(seconds: 2));

    final ended = shown().where((n) => n['ongoing'] == false).toList();
    expect(ended, hasLength(2));
    expect(ended.first, containsPair('title', 'Copy finished'));
    expect(ended.first, containsPair('name', 'Done: Downloads'));
    expect(ended.last, containsPair('title', 'Converting 2 images: failed'));
    expect(ended.last, containsPair('icon', 'failed'));
  });

  testWidgets('its Cancel button cancels the task', (tester) async {
    var asked = false;
    final task = tasks.start('Copying', onCancel: () => asked = true);
    await tester.pump(const Duration(seconds: 2));
    expect(shown().single, containsPair('action', 'Cancel'));
    notices.press(shown().single['id']! as int);
    expect(asked, isTrue);
    tasks.cancelled(task);
    await tester.pump(const Duration(seconds: 2));
    expect(shown().where((n) => n['ongoing'] == false), isEmpty);
  });

  test('the bars take their colours from the theme, once per change', () {
    notices.setTheme(Colors.blue);
    notices.setTheme(Colors.blue);
    final colors = sent.where((m) => m.$1 == 'colors');
    expect(colors, hasLength(1));
    expect(colors.single.$2['from'], Colors.blue.toARGB32());

    notices.setTheme(Colors.pink);
    expect(sent.where((m) => m.$1 == 'colors'), hasLength(2));
  });

  test('a gradient goes along the wheel from the theme, and a grey still has two ends', () {
    final blue = AppTheme.gradientOf(const Color(0xFF3B82F6));
    expect(blue.first, const Color(0xFF3B82F6));
    final hue = HSLColor.fromColor(blue.last).hue;
    expect(hue, inInclusiveRange(120, 160), reason: 'blue to green');

    final grey = AppTheme.gradientOf(const Color(0xFF111111));
    expect(grey.first, isNot(grey.last));
    final white = AppTheme.gradientOf(const Color(0xFFFAFAFA));
    expect(white.first, isNot(white.last));
  });

  group('Wi-Fi sharing', () {
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('explorer_notice');
    });

    tearDown(() => folder.delete(recursive: true));

    Future<void> untilShared(WidgetTester tester) async {
      for (var i = 0; i < 100 && shown().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('shows while on, leads back to its screen, and Stop stops it', (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      expect(FileServerScreen.showRunning(), isFalse, reason: 'nothing is being shared');

      await tester.pumpWidget(themedApp(FileServerScreen(initialFolder: folder.path, startNow: true)));
      await untilShared(tester);
      final notice = shown().single;
      expect(notice, containsPair('id', TaskNotifications.sharingId));
      expect(notice, containsPair('title', 'Sharing in the browser'));
      expect(notice['name'], startsWith('http://'));
      expect(notice, containsPair('route', IncomingRoute.fileServer));
      expect(notice, containsPair('bar', false));
      expect(notice, containsPair('action', 'Stop'));
      expect(FileServerScreen.showRunning(), isTrue);

      notices.press(TaskNotifications.sharingId);
      await tester.pump();
      expect(cancelled(), [TaskNotifications.sharingId]);
      expect(FileServerScreen.showRunning(), isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('leaves with the screen too', (tester) async {
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(themedApp(FileServerScreen(
        initialFolder: folder.path,
        protocol: ShareProtocol.ftp,
        startNow: true,
      )));
      await untilShared(tester);
      expect(shown().single, containsPair('title', 'Sharing over FTP'));
      await tester.pumpWidget(const SizedBox());
      expect(cancelled(), [TaskNotifications.sharingId]);
    });
  });
}
