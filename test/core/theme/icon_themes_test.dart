import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/shared/file_icons/place_icon.dart';

/// The icon themes come from Linux icon packs, where some icons are symbolic
/// links. Copied without following them they become tiny text files holding
/// the target's name ("folder-video.svg"), which draw nothing: Dracula's
/// Videos, Home and Desktop were blank in the sidebar that way.
void main() {
  test('every place icon of every icon theme is a real SVG', () {
    for (final style in AppStyle.values) {
      final look = style.look(Brightness.dark);
      final pack = look.iconPack;
      if (pack == null) continue;
      final assets = [
        'assets/icon_themes/$pack/folder.svg',
        for (final place in Place.values) place.assetFor(look)!,
      ];
      for (final asset in assets) {
        final file = File(asset);
        expect(file.existsSync(), isTrue, reason: '$asset is missing');
        final svg = file.readAsStringSync();
        expect(svg.contains('<svg') && svg.contains('</svg>'), isTrue,
            reason: '$asset is not an SVG but "${svg.trim()}" (a copied link?)');
      }
    }
  });
}
