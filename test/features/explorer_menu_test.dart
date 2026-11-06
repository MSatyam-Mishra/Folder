import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// Submenus: they open when asked, and beside the menu.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a submenu goes on the side with room, never over the menu', () {
    const window = Size(1280, 800);
    // Room on the right: it grows from there, starting at the menu's edge.
    final right = ExplorerMenu.besideMenu(const Rect.fromLTRB(100, 300, 400, 336), window);
    expect(right.left, lessThan(right.right), reason: 'grows to the right');
    expect(right.left, 396);

    // In the right half with room: still on the right, though it's nearer that edge.
    final stillRight = ExplorerMenu.besideMenu(const Rect.fromLTRB(581, 700, 901, 736), window);
    expect(stillRight.left, lessThan(stillRight.right));
    expect(stillRight.left, 897);

    // No room: it grows to the left, from the menu's left edge.
    final left = ExplorerMenu.besideMenu(const Rect.fromLTRB(900, 300, 1220, 336), window);
    expect(left.left, greaterThan(left.right), reason: 'grows to the left');
    expect(window.width - left.right, 904, reason: 'its right edge is at the menu, not over it');
  });

  Future<void> openMenu(WidgetTester tester, Offset at) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(Scaffold(
      body: Builder(
        builder: (context) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: (details) => ExplorerMenu.showAt<String>(
            context,
            details.globalPosition,
            items: [
              ExplorerMenu.item<String>(context, value: 'first', label: 'First'),
              ExplorerMenu.submenu<String>(
                context,
                label: 'More',
                items: [ExplorerMenu.item<String>(context, value: 'inner', label: 'Inner')],
              ),
            ],
          ),
        ),
      ),
    )));
    await tester.tapAt(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets("a menu opening under a still mouse doesn't open its submenu", (tester) async {
    // Near the bottom right: the menu grows up and left, so the mouse is on its last row.
    await openMenu(tester, const Offset(1270, 790));
    expect(find.text('More'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Inner'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('moving the mouse onto the row opens it, beside the menu', (tester) async {
    await openMenu(tester, const Offset(300, 300));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.moveTo(tester.getCenter(find.text('More')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Inner'), findsOneWidget);
    final parent = tester.getRect(find.ancestor(of: find.text('More'), matching: find.byType(InkWell)).first);
    final child = tester.getRect(find.text('Inner'));
    expect(child.left, greaterThanOrEqualTo(parent.right - 4), reason: 'not over the menu');
    await tester.pumpWidget(const SizedBox());
  });
}
