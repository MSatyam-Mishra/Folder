import 'dart:async';

import 'package:folders/core/platform/system_bars.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Leaving a full-screen page must bring the bars back, and a page arriving
/// while the last one leaves must still end up hiding them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) calls.add('${call.arguments}');
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('showing them asks for every overlay before edge to edge', () async {
    await SystemBars.show();
    expect(calls, [contains('SystemUiOverlay.top'), 'SystemUiMode.edgeToEdge']);
  });

  test('a hide right after a show comes last', () async {
    unawaited(SystemBars.show());
    await SystemBars.hide();
    expect(calls.last, 'SystemUiMode.immersiveSticky');
  });

  test('a call that fails does not stop the next', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => throw PlatformException(code: 'no'),
    );
    await SystemBars.hide();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add('${call.arguments}');
        return null;
      },
    );
    await SystemBars.hide();
    expect(calls, ['SystemUiMode.immersiveSticky']);
  });
}
