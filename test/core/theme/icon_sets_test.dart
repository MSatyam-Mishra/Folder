import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/core/theme/icon_strokes.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The icon sets of the styles (IconStrokes): a font each, under Lucide's
/// code points, picked once at the start.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// How much ink [icon] takes, drawn 100 px tall from [family], and where.
  Future<List<int>> ink(IconData icon, String family) async {
    final recorder = ui.PictureRecorder();
    TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontFamily: family, fontSize: 100, height: 1, color: Colors.black),
      ),
      textDirection: TextDirection.ltr,
    )
      ..layout()
      ..paint(Canvas(recorder), Offset.zero);
    final image = await recorder.endRecording().toImage(100, 100);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    // Ink in each quarter, so two glyphs with as much ink still differ.
    final quarters = List.filled(4, 0);
    for (var i = 3; i < bytes.lengthInBytes; i += 4) {
      final pixel = i ~/ 4;
      quarters[(pixel % 100 < 50 ? 0 : 1) + (pixel ~/ 100 < 50 ? 0 : 2)] += bytes.getUint8(i);
    }
    return quarters;
  }

  Future<void> load(String family, String asset) async {
    final loader = FontLoader(family)..addFont(rootBundle.load(asset));
    await loader.load();
  }

  test('a font family loaded once stays: a second font under its name draws nothing', () async {
    // If Flutter ever lets a family be replaced, the styles' icons could
    // change at once instead of after a restart (IconStrokes).
    const icon = LucideIcons.settings;
    await load('SwapProbe', IconSet.lucide.asset);
    final first = await ink(icon, 'SwapProbe');
    await load('SwapProbeMaterial', IconSet.material.asset);
    final material = await ink(icon, 'SwapProbeMaterial');
    expect(material, isNot(first), reason: 'the two sets draw this icon differently');
    await load('SwapProbe', IconSet.material.asset);
    expect(await ink(icon, 'SwapProbe'), first, reason: 'the first font loaded keeps drawing');
  });

  test('each style\'s set: Material and CupertinoIcons glyphs where mapped, Lucide\'s light ones elsewhere', () async {
    await load('SetLucide', IconSet.lucide.asset);
    await load('SetMaterial', IconSet.material.asset);
    await load('SetCupertino', IconSet.cupertino.asset);
    await load('SetLight', 'packages/lucide_icons_flutter/assets/build_font/LucideVariable-w300.ttf');
    for (final icon in [LucideIcons.folder, LucideIcons.search, LucideIcons.trash2, LucideIcons.share2, LucideIcons.copy]) {
      final lucide = await ink(icon, 'SetLight');
      expect(await ink(icon, 'SetMaterial'), isNot(lucide), reason: '${icon.codePoint}: Material');
      expect(await ink(icon, 'SetCupertino'), isNot(lucide), reason: '${icon.codePoint}: Cupertino');
      expect((await ink(icon, 'SetMaterial')).reduce((a, b) => a + b), greaterThan(0));
      expect((await ink(icon, 'SetCupertino')).reduce((a, b) => a + b), greaterThan(0));
    }
    // Nothing close in either: Lucide's light glyph.
    for (final icon in [LucideIcons.betweenHorizontalEnd, LucideIcons.fileX]) {
      final light = await ink(icon, 'SetLight');
      expect(await ink(icon, 'SetMaterial'), light);
      expect(await ink(icon, 'SetCupertino'), light);
    }
  });

  test('the styles\' sets, and when a style needs a restart for its icons', () async {
    expect(AppStyle.android.iconSet, IconSet.material);
    expect(AppStyle.ios.iconSet, IconSet.cupertino);
    for (final style in [AppStyle.standard, AppStyle.macos, AppStyle.windows, AppStyle.sweet, AppStyle.dracula]) {
      expect(style.iconSet, IconSet.lucide);
    }
    for (final set in IconSet.values) {
      expect(File(set.asset).existsSync(), isTrue, reason: set.asset);
    }
    await IconStrokes.use(IconSet.lucide);
    // Only the first counts.
    await IconStrokes.use(IconSet.material);
    expect(IconStrokes.loaded, IconSet.lucide);
    expect(IconStrokes.needsRestartFor(AppStyle.android), isTrue);
    expect(IconStrokes.needsRestartFor(AppStyle.ios), isTrue);
    expect(IconStrokes.needsRestartFor(AppStyle.macos), isFalse);
  });
}
