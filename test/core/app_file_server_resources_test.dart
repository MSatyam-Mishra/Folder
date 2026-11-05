import 'dart:io';

import 'package:folder/core/services/file_server/app_file_server_resources.dart';
import 'package:folder/core/theme/app_color_theme.dart';
import 'package:folder/shared/file_icons/file_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('serves the app file icons as SVG', () async {
    final resources = AppFileServerResources(iconStyle: FileIconStyle.solid);
    final pdf = resources.iconFor('report.pdf', dark: false);
    expect(await resources.iconSvg(pdf), contains('<svg'));

    // No icon of its own: drawn as a label icon.
    final label = resources.iconFor('data.qwe', dark: false);
    final labelSvg = await resources.iconSvg(label);
    expect(labelSvg, contains('>QWE</text>'));

    expect(await resources.iconSvg(resources.folderIcon), contains('<svg'));
    expect(await resources.iconSvg('unknown'), isNull);
  });

  test('classic icons get a page underneath on dark pages', () async {
    final resources = AppFileServerResources(iconStyle: FileIconStyle.classic);
    final light = resources.iconFor('song.mp3', dark: false);
    final dark = resources.iconFor('song.mp3', dark: true);
    expect(dark, isNot(light));
    expect(await resources.iconSvg(dark), contains('#F5F7FA'));
    expect(await resources.iconSvg(light), isNot(contains('#F5F7FA')));
  });

  test('loads the page font', () async {
    final font = await AppFileServerResources(iconStyle: FileIconStyle.solid).font();
    expect(font, isNotNull);
    expect(font!.length, greaterThan(10000));
  });

  test('makes JPEG thumbnails keeping the aspect ratio', () async {
    final dir = await Directory.systemTemp.createTemp('thumbs');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'wide.png'))
      ..writeAsBytesSync(img.encodePng(img.Image(width: 800, height: 400)));
    final resources = AppFileServerResources(iconStyle: FileIconStyle.solid);

    final jpeg = await resources.thumbnail(file, 200);
    expect(jpeg, isNotNull);
    final decoded = img.decodeJpg(jpeg!)!;
    expect((decoded.width, decoded.height), (200, 100));

    final broken = File(p.join(dir.path, 'broken.jpg'))..writeAsStringSync('no');
    expect(await resources.thumbnail(broken, 200), isNull);
  });

  test('page colours follow the colour scheme', () {
    final theme = webThemeFor(AppColorThemes.byId('blue'));
    expect(theme.light['primary'], startsWith('#'));
    expect(theme.light['background'], isNot(theme.dark['background']));
  });
}
