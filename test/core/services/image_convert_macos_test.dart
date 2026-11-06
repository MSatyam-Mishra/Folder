@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folders/core/services/image_convert/image_converter.dart';
import 'package:folders/core/services/image_convert/image_formats.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// macOS reads and writes HEIC (and AVIF where it can) with sips, without
/// FFmpeg.
void main() {
  late Directory dir;
  late String logo;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('explorer_convert_mac_test');
    logo = p.join(dir.path, 'logo.png');
    final image = img.Image(width: 301, height: 121, numChannels: 4)..clear(img.ColorRgba8(0, 0, 0, 0));
    img.fillCircle(image, x: 60, y: 60, radius: 50, color: img.ColorRgba8(220, 40, 40, 255));
    await File(logo).writeAsBytes(img.encodePng(image));
  });

  tearDown(() => dir.delete(recursive: true));

  img.Image decode(String path) => img.decodeImage(File(path).readAsBytesSync())!;

  test('HEIC is written here, and read back with its transparency', () async {
    expect((await ImageConverter.support(ImageFormat.heic)).kind, SupportKind.ready);
    final heic = await ImageConverter.convertFile(logo, to: ImageFormat.heic);
    expect(p.basename(heic), 'logo.heic');
    final back = decode(await ImageConverter.convertFile(heic, to: ImageFormat.png));
    expect([back.width, back.height], [301, 121]);
    expect(back.getPixel(250, 100).a, 0, reason: 'transparent corner stays transparent');
    expect(back.getPixel(60, 60).r, greaterThan(180));
  });

  test('a turned photo comes out upright', () async {
    // 80×40 stored, left half red, a green square top-left; EXIF
    // orientation 6 shows it turned a quarter clockwise.
    final stored = img.Image(width: 80, height: 40);
    for (final px in stored) {
      px.setRgb(px.x < 40 ? 230 : 20, 20, px.x < 40 ? 20 : 230);
    }
    img.fillRect(stored, x1: 0, y1: 0, x2: 9, y2: 9, color: img.ColorRgb8(20, 230, 20));
    stored.exif.imageIfd.orientation = 6;
    final jpeg = p.join(dir.path, 'turned.jpg');
    await File(jpeg).writeAsBytes(img.encodeJpg(stored, quality: 95));
    // A HEIC that keeps the turn as a tag, as iPhone photos do.
    final heic = p.join(dir.path, 'turned.heic');
    final made = await Process.run('/usr/bin/sips', ['-s', 'format', 'heic', jpeg, '--out', heic]);
    expect(made.exitCode, 0, reason: '${made.stderr}');

    final upright = decode(await ImageConverter.convertFile(heic, to: ImageFormat.png));
    expect([upright.width, upright.height], [40, 80]);
    String colour(int x, int y) {
      final px = upright.getPixel(x, y);
      return px.g > 150 ? 'green' : px.r > 150 ? 'red' : 'blue';
    }

    expect([colour(2, 2), colour(37, 2), colour(37, 77)], ['red', 'green', 'blue']);
  });

  test('a HEIC is resized as HEIC', () async {
    final heic = await ImageConverter.convertFile(logo, to: ImageFormat.heic);
    final small = await ImageConverter.convertFile(heic, resize: const ResizeSpec.pixels(width: 150));
    expect(p.basename(small), 'logo (150×60).heic');
    final back = decode(await ImageConverter.convertFile(small, to: ImageFormat.png));
    expect([back.width, back.height], [150, 60]);
  });

  test('WebP needs an FFmpeg with libwebp, which Homebrew\'s ffmpeg lacks', () async {
    final fake = File(p.join(dir.path, 'ffmpeg'));
    await fake.writeAsString('#!/bin/sh\n'
        'echo " V....D libx265              libx265 H.265 / HEVC (codec hevc)"\n'
        'echo " V..... libsvtav1            SVT-AV1 encoder (codec av1)"\n');
    await Process.run('chmod', ['+x', fake.path]);
    ImageConverter.debugFfmpeg = fake.path;
    addTearDown(() => ImageConverter.debugFfmpeg = null);
    // The app's own FFmpeg (which has it) is offered instead.
    expect((await ImageConverter.support(ImageFormat.webp)).kind, SupportKind.needsFfmpeg);
  });

  test("a menu doesn't wait long for a slow FFmpeg", () async {
    final slow = File(p.join(dir.path, 'ffmpeg'));
    await slow.writeAsString('#!/bin/sh\nsleep 2\n'
        'echo " V....D libx265              libx265 H.265 / HEVC (codec hevc)"\n');
    await Process.run('chmod', ['+x', slow.path]);
    ImageConverter.debugFfmpeg = slow.path;
    addTearDown(() => ImageConverter.debugFfmpeg = null);
    final clock = Stopwatch()..start();
    final first = await ImageConverter.menuSupport([ImageFormat.jpeg, ImageFormat.webp]);
    expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
    expect(first[ImageFormat.webp]!.kind, SupportKind.ready, reason: 'offered until FFmpeg answers');
    // Chosen, it's asked in full: this FFmpeg has no libwebp.
    expect((await ImageConverter.support(ImageFormat.webp)).kind, SupportKind.needsFfmpeg);
    final later = await ImageConverter.menuSupport([ImageFormat.jpeg, ImageFormat.webp]);
    expect(later.map((f, s) => MapEntry(f, s.kind)),
        {ImageFormat.jpeg: SupportKind.ready, ImageFormat.webp: SupportKind.needsFfmpeg});
  });

  test('AVIF, where macOS writes it', () async {
    final probe = await Process.run('/usr/bin/sips', ['--formats']);
    if (!ImageConverter.parseSipsWritable('${probe.stdout}').contains('avif')) {
      markTestSkipped('This macOS has no AVIF encoder.');
      return;
    }
    expect((await ImageConverter.support(ImageFormat.avif)).kind, SupportKind.ready);
    final avif = await ImageConverter.convertFile(logo, to: ImageFormat.avif);
    final back = decode(await ImageConverter.convertFile(avif, to: ImageFormat.png));
    expect([back.width, back.height], [301, 121]);
    expect(back.getPixel(250, 100).a, 0);
  });
}
