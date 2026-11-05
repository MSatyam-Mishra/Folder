import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:folder/core/services/local_content_server.dart';
import 'package:folder/features/viewer_3d/screens/three_d_viewer_screen.dart';
import 'package:folder/features/viewer_3d/services/three_d_viewer_controller.dart';
import 'package:folder/features/viewer_3d/widgets/model_info_panel.dart';
import 'package:folder/features/viewer_design/screens/design_preview_screen.dart';
import 'package:folder/features/viewer_font/screens/font_viewer_screen.dart';
import 'package:folder/features/viewer_html/screens/html_viewer_screen.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/features/viewer_vector/screens/lottie_viewer_screen.dart';
import 'package:folder/features/viewer_vector/screens/svg_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'viewer_shot_helpers.dart';

const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">
  <circle cx="100" cy="100" r="80" fill="#2563eb"/>
  <path d="M60 110 L90 140 L145 75" stroke="#fff" stroke-width="16"
    fill="none" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
''';

const _lottie = '''
{"v":"5.7.4","fr":30,"ip":0,"op":60,"w":200,"h":200,"nm":"dot","ddd":0,
 "assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"circle","sr":1,
 "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[100,100,0]},
 "a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,
 "shapes":[{"ty":"el","p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[120,120]},"nm":"e"},
 {"ty":"fl","c":{"a":0,"k":[0.92,0.35,0.2,1]},"o":{"a":0,"k":100},"nm":"f"}],
 "ip":0,"op":60,"st":0,"bm":0}]}
''';

List<int> _poster() {
  final image = img.Image(width: 900, height: 1200);
  img.fill(image, color: img.ColorRgb8(245, 240, 230));
  img.fillRect(image, x1: 80, y1: 80, x2: 820, y2: 760, color: img.ColorRgb8(230, 90, 60));
  img.fillCircle(image, x: 450, y: 420, radius: 220, color: img.ColorRgb8(250, 210, 90));
  img.fillRect(image, x1: 80, y1: 840, x2: 820, y2: 900, color: img.ColorRgb8(30, 30, 30));
  img.fillRect(image, x1: 80, y1: 940, x2: 600, y2: 970, color: img.ColorRgb8(120, 120, 120));
  return img.encodePng(image);
}

void main() {
  late Directory dir;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    FakeWebViewPlatform.install();
    dir = await Directory.systemTemp.createTemp('viewer_tools_shots_');
    // Start the loopback server outside the tests' fake-async zones: its
    // socket timers would otherwise outlive the first test that starts it.
    final base = await LocalContentServer.instance.mountDirectory(dir.path);
    LocalContentServer.instance.unmount(base);
    final font = await rootBundle.load('packages/shadcn_ui/fonts/Geist[wght].ttf');
    await File(p.join(dir.path, 'Geist.ttf'))
        .writeAsBytes(font.buffer.asUint8List());
    await File(p.join(dir.path, 'badge.svg')).writeAsString(_svg);
    await File(p.join(dir.path, 'dot.json')).writeAsString(_lottie);
    await File(p.join(dir.path, 'index.html')).writeAsString(
      '<html><body><h1>Hello</h1><script>alert(1)</script></body></html>',
    );
    await File(p.join(dir.path, 'Model.glb')).writeAsBytes(List.filled(2048, 1));
    await File(p.join(dir.path, 'Plan.dwg')).writeAsBytes(
      [...ascii.encode('AC1032'), ...List.filled(4096, 0)],
    );
    final ora = Archive();
    void add(String name, List<int> bytes) =>
        ora.addFile(ArchiveFile(name, bytes.length, bytes));
    add('mimetype', ascii.encode('image/openraster'));
    add('stack.xml', utf8.encode('<image w="900" h="1200"><stack/></image>'));
    add('mergedimage.png', _poster());
    await File(p.join(dir.path, 'Poster.ora'))
        .writeAsBytes(ZipEncoder().encode(ora)!);
  });

  tearDownAll(() async {
    if (screenshotsEnabled) {
      await dir.delete(recursive: true).catchError((_) => dir);
    }
  });

  viewerShots('font viewer', (tester, shot) async {
    await shot.open(FontViewerScreen(file: File(p.join(dir.path, 'Geist.ttf'))));
    await settle(tester, rounds: 10);
    await shot.shot('font');
  });

  viewerShots('html viewer', (tester, shot) async {
    await shot.open(HtmlViewerScreen(file: File(p.join(dir.path, 'index.html'))));
    await settle(tester, rounds: 8);
    await shot.shot('html_page');
    await tester.tap(find.byTooltip('Source'));
    await settle(tester, rounds: 8);
    await shot.shot('html_source');
  });

  viewerShots('design preview', (tester, shot) async {
    await shot.open(DesignPreviewScreen(file: File(p.join(dir.path, 'Poster.ora'))));
    await settle(tester, rounds: 12);
    await shot.shot('design');
    await shot.open(DesignPreviewScreen(file: File(p.join(dir.path, 'Plan.dwg'))));
    await settle(tester, rounds: 12);
    await shot.shot('design_empty');
  });

  viewerShots('vector viewers', (tester, shot) async {
    await shot.open(SvgViewerScreen(filePath: p.join(dir.path, 'badge.svg')));
    await settle(tester);
    await shot.shot('svg');
    await shot.open(LottieViewerScreen(file: File(p.join(dir.path, 'dot.json'))));
    await settle(tester, rounds: 10);
    await shot.shot('lottie');
  });

  viewerShots('3d viewer', (tester, shot) async {
    await shot.open(ThreeDViewerScreen(file: File(p.join(dir.path, 'Model.glb'))));
    await settle(tester, rounds: 8);
    await shot.shot('viewer3d_loading');
  });

  viewerShots('3d info panel', (tester, shot) async {
    final controller = ThreeDViewerController()
      ..handleMessage({
        'type': 'loaded',
        'stats': {
          'format': 'glTF binary',
          'meshes': 12,
          'vertices': 48210,
          'triangles': 90311,
          'materials': 6,
          'textures': 4,
          'animations': 2,
          'size': {'x': 1.82, 'y': 2.4, 'z': 0.96},
        },
        'warnings': ['Texture "wood.png" could not be found.'],
        'animations': [
          {'index': 0, 'name': 'Idle', 'duration': 2.5},
          {'index': 1, 'name': 'Walk', 'duration': 1.2},
        ],
        'animationIndex': 0,
        'animationPlaying': true,
        'state': {'grid': true, 'autoRotate': false, 'background': 'dark'},
      });
    await shot.open(
      Scaffold(
        body: SafeArea(
          child: Center(
            child: SizedBox(
              width: 360,
              child: AppPanel(
                margin: const EdgeInsets.all(12),
                child: ModelInfoPanel(
                  controller: controller,
                  fileName: 'Robot.glb',
                  fileSize: 2400000,
                  onScreenshot: () {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await shot.shot('viewer3d_panel');
  }, devices: const ['phone']);
}
