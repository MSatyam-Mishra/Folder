import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:explorer/core/services/thumbnails/thumbnails.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// On a device: `flutter test integration_test/thumbnails_test.dart -d DEVICE`
/// Pictures for the file list: images, TIFF, a PDF's first page, an Office
/// file's preview, and (with ffmpeg on the PATH) a video frame.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  setUpAll(() async => dir = await Directory.systemTemp.createTemp('explorer_thumbs'));
  tearDownAll(() async => dir.delete(recursive: true));

  img.Image picture() {
    final image = img.Image(width: 400, height: 300);
    img.fill(image, color: img.ColorRgb8(30, 120, 220));
    img.fillRect(image, x1: 50, y1: 50, x2: 250, y2: 200, color: img.ColorRgb8(250, 200, 40));
    return image;
  }

  Future<(int, int)> size(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return (frame.image.width, frame.image.height);
  }

  Future<void> expectPicture(String path) async {
    final bytes = await Thumbnails.load(path, 96);
    expect(bytes, isNotNull, reason: '${p.basename(path)}: no picture');
    final (w, h) = await size(bytes!);
    expect(w > 8 && h > 8, isTrue, reason: '${p.basename(path)}: $w×$h');
  }

  testWidgets('pictures of images, TIFF, PDF and Office files', (tester) async {
    await tester.runAsync(() async {
      final png = p.join(dir.path, 'photo.png');
      await File(png).writeAsBytes(img.encodePng(picture()));
      final tiff = p.join(dir.path, 'scan.tif');
      await File(tiff).writeAsBytes(img.encodeTiff(picture()));
      final pdf = p.join(dir.path, 'page.pdf');
      await File(pdf).writeAsBytes(_onePagePdf());
      final docx = p.join(dir.path, 'report.docx');
      final zip = Archive()
        ..addFile(ArchiveFile.string('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'))
        ..addFile(ArchiveFile.noCompress('docProps/thumbnail.jpeg', 0, img.encodeJpg(picture())));
      await File(docx).writeAsBytes(ZipEncoder().encode(zip)!);

      if (Platform.isWindows) await expectPicture(png); // others draw it themselves
      await expectPicture(tiff);
      await expectPicture(pdf);
      await expectPicture(docx);
      expect(await Thumbnails.load(p.join(dir.path, 'missing.pdf'), 96), isNull);
    });
  });

  testWidgets('a video frame (Windows, ffmpeg on the PATH to make the video)', (tester) async {
    await tester.runAsync(() async {
      final video = p.join(dir.path, 'clip.mp4');
      final made = await Process.run('ffmpeg', [
        '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10', '-t', '2',
        '-pix_fmt', 'yuv420p', video,
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      await expectPicture(video);
    });
  }, skip: !Platform.isWindows);
}

/// A one-page PDF with a filled rectangle.
List<int> _onePagePdf() {
  const content = '0.2 0.5 0.9 rg 50 50 200 300 re f';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (final (i, body) in objects.indexed) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n$body\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return latin1.encode(out.toString());
}
