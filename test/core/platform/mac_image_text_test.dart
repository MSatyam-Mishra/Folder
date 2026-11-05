@TestOn('mac-os')
library;

import 'dart:io';

import 'package:folder/core/services/image_text.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("macOS reads text in images through the runner's Vision channel", () async {
    const channel = MethodChannel('explorer/image_text');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final asked = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add((call.arguments as Map)['path'] as String);
      return {
        'w': 360,
        'h': 900,
        'lines': [
          {
            't': 'Invoice 2041',
            'words': [
              {'t': 'Invoice', 'x': 266.0, 'y': 46.0, 'w': 36.0, 'h': 162.0},
              {'t': '2041', 'x': 266.0, 'y': 212.5, 'w': 36.0, 'h': 105.5},
            ],
          },
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final dir = await Directory.systemTemp.createTemp('explorer_mac_ocr');
    addTearDown(() => dir.delete(recursive: true));
    final image = await File(p.join(dir.path, 'scan.jpg')).writeAsBytes([1, 2, 3]);

    expect(ImageTextReader.supported, isTrue);
    final text = (await ImageTextReader.read(image))!;
    expect(asked, [image.path]);
    expect(text.size, const Size(360, 900));
    expect(text.text, 'Invoice 2041');
    expect(text.lines.single.box, const Rect.fromLTRB(266, 46, 302, 318));
  });
}
