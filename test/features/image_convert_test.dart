import 'dart:io';

import 'package:folder/core/services/background_tasks.dart';
import 'package:folder/core/services/image_convert/image_converter.dart';
import 'package:folder/core/services/image_convert/image_formats.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// The FFmpeg to test WebP and AVIF with: EXPLORER_FFMPEG, else the one
/// the app downloads on Windows, else the system's.
String? _ffmpeg() {
  final env = Platform.environment['EXPLORER_FFMPEG'];
  if (env != null && File(env).existsSync()) return env;
  final appData = Platform.environment['APPDATA'];
  if (appData != null) {
    final own = p.join(appData, 'MSatyam-Mishra', 'Folder', 'video_downloader', 'ffmpeg', 'bin', 'ffmpeg.exe');
    if (File(own).existsSync()) return own;
  }
  return null;
}

void main() {
  late Directory dir;
  late String photo;
  late String transparent;
  final ffmpeg = _ffmpeg();

  setUp(() async {
    ImageConverter.debugFfmpeg = ffmpeg;
    dir = await Directory.systemTemp.createTemp('explorer_convert_test');
    photo = p.join(dir.path, 'invoice.png');
    await File('test/fixtures/ocr_invoice.png').copy(photo);
    transparent = p.join(dir.path, 'logo.png');
    final logo = img.Image(width: 300, height: 120, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
    img.fillCircle(logo, x: 60, y: 60, radius: 50, color: img.ColorRgba8(220, 40, 40, 255));
    await File(transparent).writeAsBytes(img.encodePng(logo));
  });

  tearDown(() async {
    BackgroundTasks.instance.reset();
    await dir.delete(recursive: true);
  });

  test('targets: every format but the selected ones', () {
    final targets = ImageFormat.targetsFor(['a.JPG', 'b.jpeg', 'c.png']);
    expect(targets, isNot(contains(ImageFormat.jpeg)));
    expect(targets, isNot(contains(ImageFormat.png)));
    expect(targets, containsAll([ImageFormat.webp, ImageFormat.avif, ImageFormat.heic, ImageFormat.tiff,
        ImageFormat.bmp, ImageFormat.gif, ImageFormat.ico, ImageFormat.svg]));
    expect(ImageFormat.of('x.heif'), ImageFormat.heic);
    expect(ImageFormat.of('x.tif'), ImageFormat.tiff);
  });

  test('resize sizes: pixels and percent, aspect kept or not', () {
    expect(const ResizeSpec.pixels(width: 450).sizeFor(900, 360), (450, 180));
    expect(const ResizeSpec.pixels(height: 90).sizeFor(900, 360), (225, 90));
    expect(const ResizeSpec.pixels(width: 300, height: 300).sizeFor(900, 360), (300, 120), reason: 'fits inside');
    expect(const ResizeSpec.pixels(width: 300, height: 300, keepAspect: false).sizeFor(900, 360), (300, 300));
    expect(const ResizeSpec.percent(width: 50).sizeFor(900, 360), (450, 180));
    expect(const ResizeSpec.percent(width: 50, height: 200, keepAspect: false).sizeFor(900, 360), (450, 720));
    expect(const ResizeSpec.percent(width: 50).label, '50%');
  });

  for (final format in [ImageFormat.jpeg, ImageFormat.gif, ImageFormat.bmp, ImageFormat.tiff,
      ImageFormat.tga, ImageFormat.ico]) {
    test('converts to ${format.label}, readable, beside the original', () async {
      final out = await ImageConverter.convertFile(photo, to: format);
      expect(p.dirname(out), dir.path);
      expect(p.basename(out), 'invoice.${format.extension}');
      final decoded = img.decodeImage(await File(out).readAsBytes());
      expect(decoded, isNotNull, reason: format.label);
      if (format == ImageFormat.ico) {
        expect([decoded!.width, decoded.height], [256, 256]);
      } else {
        expect([decoded!.width, decoded.height], [900, 360]);
      }
    });
  }

  test('SVG holds the picture; names never clash', () async {
    final first = await ImageConverter.convertFile(transparent, to: ImageFormat.svg);
    final second = await ImageConverter.convertFile(transparent, to: ImageFormat.svg);
    expect(p.basename(first), 'logo.svg');
    expect(p.basename(second), 'logo (2).svg');
    final svg = await File(first).readAsString();
    expect(svg, startsWith('<svg'));
    expect(svg, contains('width="300" height="120"'));
    expect(svg, contains('data:image/png;base64,'));
  });

  test('resizes as a copy, or in place', () async {
    final copy = await ImageConverter.convertFile(photo, resize: const ResizeSpec.pixels(width: 450));
    expect(p.basename(copy), 'invoice (450×180).png');
    expect(img.decodePng(await File(copy).readAsBytes())!.width, 450);
    expect(img.decodePng(await File(photo).readAsBytes())!.width, 900, reason: 'original kept');

    final replaced = await ImageConverter.convertFile(photo, resize: const ResizeSpec.percent(width: 25), replace: true);
    expect(replaced, photo);
    expect(img.decodePng(await File(photo).readAsBytes())!.width, 225);
  });

  test('a background task converts several and keeps their outputs', () async {
    final task = ImageConverter.start([photo, transparent], to: ImageFormat.bmp);
    expect(BackgroundTasks.instance.running, contains(task));
    while (task.isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(task.status, TaskStatus.done);
    expect(task.outputs.map(p.basename), ['invoice.bmp', 'logo.bmp']);
  });

  group('with FFmpeg', () {
    test('WebP and AVIF, keeping transparency', () async {
      for (final format in [ImageFormat.webp, ImageFormat.avif]) {
        final out = await ImageConverter.convertFile(transparent, to: format);
        expect(await File(out).length(), greaterThan(100), reason: format.label);
        // Read back through the converter (FFmpeg decodes it).
        final back = await ImageConverter.convertFile(out, to: ImageFormat.png);
        final decoded = img.decodePng(await File(back).readAsBytes())!;
        expect([decoded.width, decoded.height], [300, 120], reason: format.label);
        await File(back).delete();
      }
      final webp = img.decodeWebP(await File(p.join(dir.path, 'logo.webp')).readAsBytes())!;
      expect(webp.getPixel(250, 100).a, 0, reason: 'transparent corner stays transparent');
      expect(webp.getPixel(60, 60).r, greaterThan(180));
    });
  }, skip: ffmpeg == null ? 'no FFmpeg' : false);

  test('HEIC (HEVC in our HEIF file), and back', () async {
    final support = await ImageConverter.support(ImageFormat.heic);
    if (support.kind != SupportKind.ready) {
      markTestSkipped('${support.reason ?? 'needs FFmpeg'}');
      return;
    }
    final heic = await ImageConverter.convertFile(photo, to: ImageFormat.heic);
    expect(p.basename(heic), 'invoice.heic');
    final keep = Platform.environment['EXPLORER_KEEP_HEIC'];
    if (keep != null) await File(heic).copy(keep);
    final back = await ImageConverter.convertFile(heic, to: ImageFormat.jpeg);
    final decoded = img.decodeJpg(await File(back).readAsBytes())!;
    expect([decoded.width, decoded.height], [900, 360]);
    // Dark text on white survives.
    expect(decoded.getPixel(10, 10).r, greaterThan(230));
  }, skip: ffmpeg == null ? 'no FFmpeg' : false);
}
