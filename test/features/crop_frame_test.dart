import 'dart:io';

import 'package:folder/features/viewer_image/screens/image_editor_screen.dart';
import 'package:folder/features/viewer_image/widgets/crop_frame.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/themed_app.dart';

/// The crop frame: every edge and corner, by mouse and by finger.
void main() {
  const minimum = Size(0.1, 0.1);
  const middle = Rect.fromLTRB(0.2, 0.2, 0.8, 0.8);

  void expectRect(Rect actual, Rect expected) {
    expect(actual.left, moreOrLessEquals(expected.left, epsilon: 1e-6), reason: '$actual');
    expect(actual.top, moreOrLessEquals(expected.top, epsilon: 1e-6), reason: '$actual');
    expect(actual.right, moreOrLessEquals(expected.right, epsilon: 1e-6), reason: '$actual');
    expect(actual.bottom, moreOrLessEquals(expected.bottom, epsilon: 1e-6), reason: '$actual');
  }

  group('what a pointer has hold of', () {
    const frame = Rect.fromLTRB(100, 100, 500, 400);

    test('corners, edges, the inside and the rest', () {
      for (final (point, zone) in [
        (const Offset(100, 100), CropZone.topLeft),
        (const Offset(500, 100), CropZone.topRight),
        (const Offset(100, 400), CropZone.bottomLeft),
        (const Offset(500, 400), CropZone.bottomRight),
        (const Offset(300, 100), CropZone.top),
        (const Offset(300, 400), CropZone.bottom),
        (const Offset(100, 250), CropZone.left),
        (const Offset(500, 250), CropZone.right),
        (const Offset(300, 250), CropZone.inside),
        (const Offset(20, 20), CropZone.outside),
      ]) {
        expect(CropGeometry.zoneAt(point, frame, 12), zone, reason: '$point');
      }
    });

    test('an edge can be taken from either side of it, and corners from outside', () {
      expect(CropGeometry.zoneAt(const Offset(90, 250), frame, 12), CropZone.left);
      expect(CropGeometry.zoneAt(const Offset(110, 250), frame, 12), CropZone.left);
      expect(CropGeometry.zoneAt(const Offset(92, 92), frame, 12), CropZone.topLeft);
    });

    test("a small frame still has an inside, whatever a finger's reach", () {
      const small = Rect.fromLTRB(100, 100, 160, 160);
      expect(CropGeometry.zoneAt(small.center, small, 30), CropZone.inside);
      expect(CropGeometry.zoneAt(small.topLeft, small, 30), CropZone.topLeft);
    });
  });

  group('dragging, free', () {
    test('each edge moves only itself', () {
      const by = Offset(0.1, 0.1);
      expectRect(CropGeometry.dragged(CropZone.left, middle, by, minimum: minimum), const Rect.fromLTRB(0.3, 0.2, 0.8, 0.8));
      expectRect(CropGeometry.dragged(CropZone.right, middle, by, minimum: minimum), const Rect.fromLTRB(0.2, 0.2, 0.9, 0.8));
      expectRect(CropGeometry.dragged(CropZone.top, middle, by, minimum: minimum), const Rect.fromLTRB(0.2, 0.3, 0.8, 0.8));
      expectRect(CropGeometry.dragged(CropZone.bottom, middle, by, minimum: minimum), const Rect.fromLTRB(0.2, 0.2, 0.8, 0.9));
    });

    test('a corner moves its two edges', () {
      expectRect(
        CropGeometry.dragged(CropZone.topRight, middle, const Offset(0.1, -0.1), minimum: minimum),
        const Rect.fromLTRB(0.2, 0.1, 0.9, 0.8),
      );
    });

    test('stops at the image, and at its least size', () {
      expectRect(
        CropGeometry.dragged(CropZone.topLeft, middle, const Offset(-5, -5), minimum: minimum),
        const Rect.fromLTRB(0, 0, 0.8, 0.8),
      );
      expectRect(
        CropGeometry.dragged(CropZone.left, middle, const Offset(5, 0), minimum: minimum),
        const Rect.fromLTRB(0.7, 0.2, 0.8, 0.8),
      );
    });

    test('the inside moves it whole, as far as the image goes', () {
      expectRect(CropGeometry.dragged(CropZone.inside, middle, const Offset(0.1, -0.1), minimum: minimum),
          const Rect.fromLTRB(0.3, 0.1, 0.9, 0.7));
      expectRect(CropGeometry.dragged(CropZone.inside, middle, const Offset(5, 5), minimum: minimum),
          const Rect.fromLTRB(0.4, 0.4, 1, 1));
    });

    test('a new frame can be drawn, either way, once it is big enough', () {
      final drawn = CropGeometry.drawn(const Offset(0.8, 0.9), const Offset(0.2, 0.1), middle, minimum: minimum);
      expectRect(drawn, const Rect.fromLTRB(0.2, 0.1, 0.8, 0.9));
      expect(CropGeometry.drawn(const Offset(0.5, 0.5), const Offset(0.52, 0.9), middle, minimum: minimum), middle);
      expect(CropGeometry.drawn(const Offset(0.5, 0.5), const Offset(5, 5), middle, minimum: minimum).right, 1);
    });
  });

  group('dragging, keeping a ratio', () {
    const square = Rect.fromLTRB(0.3, 0.3, 0.6, 0.6);

    void expectRatio(Rect rect, double aspect) {
      expect(rect.width / rect.height, moreOrLessEquals(aspect, epsilon: 1e-6), reason: '$rect');
      expect(rect.left, greaterThanOrEqualTo(-1e-9), reason: '$rect');
      expect(rect.top, greaterThanOrEqualTo(-1e-9), reason: '$rect');
      expect(rect.right, lessThanOrEqualTo(1 + 1e-9), reason: '$rect');
      expect(rect.bottom, lessThanOrEqualTo(1 + 1e-9), reason: '$rect');
    }

    test('whichever corner or edge, and however far: never out of shape or off the image', () {
      for (final aspect in [1.0, 16 / 9, 9 / 16, 2.5]) {
        for (final zone in CropZone.values) {
          if (zone == CropZone.outside || zone == CropZone.inside) continue;
          for (final delta in const [Offset(0.1, 0.05), Offset(-0.1, -0.2), Offset(5, 5), Offset(-5, -5), Offset(5, -5)]) {
            expectRatio(CropGeometry.dragged(zone, square, delta, aspect: aspect, minimum: minimum), aspect);
          }
        }
      }
    });

    test('a corner keeps the opposite one still', () {
      final dragged = CropGeometry.dragged(CropZone.bottomRight, square, const Offset(0.1, 0.1), aspect: 1, minimum: minimum);
      expect(dragged.topLeft, square.topLeft);
      expect(dragged.width, moreOrLessEquals(0.4));
    });

    test('an edge keeps the opposite one still, and stays centred along it', () {
      final dragged = CropGeometry.dragged(CropZone.right, square, const Offset(0.1, 0), aspect: 1, minimum: minimum);
      expect(dragged.left, moreOrLessEquals(square.left));
      expect(dragged.center.dy, moreOrLessEquals(square.center.dy));
      expect(dragged.width, moreOrLessEquals(0.4));
    });
  });

  group('the frame on screen', () {
    const image = Rect.fromLTRB(100, 100, 500, 500);

    Future<List<Rect>> pump(WidgetTester tester, {double? aspect, Rect start = const Rect.fromLTWH(0, 0, 1, 1)}) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final changes = <Rect>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CropFrame(
            imageRect: image,
            rect: start,
            pixelSize: const Size(1000, 1000),
            aspect: aspect,
            onChanged: changes.add,
          ),
        ),
      ));
      return changes;
    }

    Future<void> mouseDrag(WidgetTester tester, Offset from, Offset by) async {
      final mouse = await tester.startGesture(from, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await tester.pump();
      await mouse.moveBy(by);
      await tester.pump();
      await mouse.up();
      await tester.pump();
    }

    for (final (name, grab, by, expected) in [
      ('its top left corner', image.topLeft, const Offset(40, 80), const Rect.fromLTRB(0.1, 0.2, 1, 1)),
      ('its bottom right corner', image.bottomRight, const Offset(-40, -80), const Rect.fromLTRB(0, 0, 0.9, 0.8)),
      ('its left edge', image.centerLeft, const Offset(40, 0), const Rect.fromLTRB(0.1, 0, 1, 1)),
      ('its right edge', image.centerRight, const Offset(-40, 0), const Rect.fromLTRB(0, 0, 0.9, 1)),
      ('its top edge', image.topCenter, const Offset(0, 40), const Rect.fromLTRB(0, 0.1, 1, 1)),
      ('its bottom edge', image.bottomCenter, const Offset(0, -40), const Rect.fromLTRB(0, 0, 1, 0.9)),
      // Just outside the image, where half the old corner dots couldn't be clicked.
      ('a corner from just outside the image', image.topLeft - const Offset(8, 8), const Offset(40, 40), const Rect.fromLTRB(0.1, 0.1, 1, 1)),
    ]) {
      testWidgets('a mouse takes $name of an image not cropped yet', (tester) async {
        final changes = await pump(tester);
        await mouseDrag(tester, grab, by);
        expect(changes, hasLength(1), reason: 'once, at the end');
        expectRect(changes.single, expected);
      });
    }

    testWidgets('a finger reaches further than a mouse', (tester) async {
      final changes = await pump(tester);
      final finger = await tester.startGesture(image.centerLeft + const Offset(25, 0));
      await finger.moveBy(const Offset(40, 0));
      await finger.up();
      await tester.pump();
      expectRect(changes.single, const Rect.fromLTRB(0.1, 0, 1, 1));
    });

    testWidgets('it follows at once, with nothing outside it rebuilt, and tells only at the end', (tester) async {
      final changes = await pump(tester);
      final mouse = await tester.startGesture(image.centerRight, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await mouse.moveBy(const Offset(-40, 0));
      await mouse.moveBy(const Offset(-40, 0));
      expect(changes, isEmpty);
      await mouse.up();
      expectRect(changes.single, const Rect.fromLTRB(0, 0, 0.8, 1));
    });

    testWidgets('a drag on the image outside the frame draws a new one, when free', (tester) async {
      final changes = await pump(tester, start: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6));
      await mouseDrag(tester, image.topLeft + const Offset(40, 40), const Offset(80, 80));
      expectRect(changes.single, const Rect.fromLTRB(0.1, 0.1, 0.3, 0.3));
    });

    testWidgets('not when keeping a ratio', (tester) async {
      final changes = await pump(tester, aspect: 1, start: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6));
      await mouseDrag(tester, image.topLeft + const Offset(40, 40), const Offset(80, 80));
      expect(changes, isEmpty);
    });

    testWidgets('a click changes nothing', (tester) async {
      final changes = await pump(tester);
      await mouseDrag(tester, image.center, Offset.zero);
      expect(changes, isEmpty);
    });

    testWidgets('the right mouse button does nothing', (tester) async {
      final changes = await pump(tester);
      final mouse = await tester.startGesture(image.centerRight, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await mouse.moveBy(const Offset(-40, 0));
      await mouse.up();
      expect(changes, isEmpty);
    });

    testWidgets('its own ratio buttons move it from outside', (tester) async {
      final changes = await pump(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CropFrame(
            imageRect: image,
            rect: const Rect.fromLTRB(0.4, 0.4, 0.6, 0.6),
            pixelSize: const Size(1000, 1000),
            onChanged: changes.add,
          ),
        ),
      ));
      // Dragged by where it is now, not where it was.
      await mouseDrag(tester, const Offset(260, 300), const Offset(-40, 0));
      expectRect(changes.single, const Rect.fromLTRB(0.3, 0.4, 0.6, 0.6));
    });
  });

  group('the editor', () {
    late Directory root;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('explorer_crop');
    });

    tearDown(() => root.delete(recursive: true));

    testWidgets('dragging an edge with a mouse reaches what will be saved', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final file = (await tester.runAsync(() async {
        final picture = img.Image(width: 400, height: 200);
        img.fill(picture, color: img.ColorRgb8(30, 120, 220));
        return File(p.join(root.path, 'Photo.png')).writeAsBytes(img.encodePng(picture));
      }))!;
      await tester.pumpWidget(themedApp(ImageEditorScreen(file: file)));
      for (var i = 0; i < 60 && find.byType(CropFrame).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      final frame = tester.widget<CropFrame>(find.byType(CropFrame));
      final area = tester.getTopLeft(find.byType(CropFrame));
      final image = frame.imageRect.shift(area);

      // The right edge to the middle of the image: half the width.
      final mouse = await tester.startGesture(image.centerRight, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton);
      await tester.pump();
      await mouse.moveBy(Offset(-image.width / 2, 0));
      await tester.pump();
      await mouse.up();
      await tester.pump();

      expect(tester.widget<CropFrame>(find.byType(CropFrame)).rect.right, moreOrLessEquals(0.5, epsilon: 0.01));

      await tester.pumpWidget(const SizedBox());
    });
  });
}
