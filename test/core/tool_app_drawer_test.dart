import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';

/// A tool in the app drawer is an entry of the Android manifest, so each tool
/// needs one, off until asked for, opening that tool, with its icons.
void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  const res = 'android/app/src/main/res';

  for (final tool in Tool.values) {
    test('${tool.title} can go in the app drawer', () {
      final name = tool.shortcut.id;
      final entry = RegExp('<activity-alias[^>]*android:name="\\.$name"[^>]*>(.*?)</activity-alias>', dotAll: true)
          .firstMatch(manifest);
      expect(entry, isNotNull, reason: 'its id names the manifest entry the app turns on');
      final text = entry!.group(0)!;
      expect(text, contains('android:enabled="false"'), reason: 'not in the drawer until the user asks');
      expect(text, contains('android:targetActivity=".MainActivity"'));
      expect(text, contains('android:label="${tool.title}"'));
      expect(text, contains('android.intent.category.LAUNCHER'));
      expect(text, contains('android:value="${tool.shortcut.route}"'), reason: 'opens this tool');

      final icon = 'ic_tool_${tool.id}';
      expect(text, contains('android:icon="@mipmap/$icon"'));
      expect(File('$res/mipmap-anydpi-v26/$icon.xml').existsSync(), isTrue);
      expect(File('$res/mipmap-xxxhdpi/$icon.png').existsSync(), isTrue);
      expect(File('$res/mipmap-xxxhdpi/${icon}_foreground.png').existsSync(), isTrue);
    });
  }

  test('the app opens from its own entry, declared first', () {
    expect(manifest.indexOf('android:name=".MainActivity"'), lessThan(manifest.indexOf('<activity-alias')));
  });
}
