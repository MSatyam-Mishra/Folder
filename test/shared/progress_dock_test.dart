import 'package:folders/shared/widgets/progress_dock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The dock of running tasks: the small hide button tucks the tiles into a
/// ring, hovering over the ring shows them, tapping it brings them back.
void main() {
  final task = ValueNotifier<DockTask?>(null);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> show(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    task.value = null;
    await tester.pumpWidget(
      themedApp(
        Scaffold(
          body: ValueListenableBuilder(
            valueListenable: task,
            builder: (context, value, _) =>
                Stack(children: [ProgressDock(fileTask: value)]),
          ),
        ),
      ),
    );
    task.value = const DockTask(
      title: 'Copying 3 items',
      message: 'photo.jpg',
      progress: 0.4,
    );
    await tester.pump();
  }

  Finder hideButton() => find.byTooltip('Hide');
  Finder ring() => find.byTooltip('1 task running');

  testWidgets('hide tucks the tiles into a ring with the progress', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Copying 3 items'), findsOneWidget);
    expect(ring(), findsNothing);

    await tester.tap(hideButton());
    await tester.pump();
    expect(find.text('Copying 3 items'), findsNothing);
    expect(ring(), findsOneWidget);
    expect(find.text('40'), findsOneWidget);
  });

  testWidgets('hovering over the ring shows the tiles', (tester) async {
    await show(tester);
    await tester.tap(hideButton());
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(ring()));
    await tester.pump();
    expect(find.text('Copying 3 items'), findsOneWidget);
    expect(ring(), findsOneWidget);
    expect(hideButton(), findsNothing);

    // Up onto the tile: still shown.
    await mouse.moveTo(tester.getCenter(find.text('Copying 3 items')));
    await tester.pump();
    expect(find.text('Copying 3 items'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(find.text('Copying 3 items'), findsNothing);
    expect(ring(), findsOneWidget);
  });

  testWidgets('tapping the ring brings the tiles back', (tester) async {
    await show(tester);
    await tester.tap(hideButton());
    await tester.pump();

    await tester.tap(ring());
    await tester.pump();
    expect(find.text('Copying 3 items'), findsOneWidget);
    expect(ring(), findsNothing);
    expect(hideButton(), findsOneWidget);
  });

  testWidgets('the next task shows its tile again', (tester) async {
    await show(tester);
    await tester.tap(hideButton());
    await tester.pump();

    task.value = null;
    await tester.pump();
    expect(ring(), findsNothing);

    task.value = const DockTask(title: 'Moving 1 item', message: 'a.txt');
    await tester.pump();
    expect(find.text('Moving 1 item'), findsOneWidget);
    expect(ring(), findsNothing);
  });
}
