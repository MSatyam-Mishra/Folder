import 'package:folders/shared/widgets/round_qr_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/screenshots.dart';

/// SCREENSHOTS=1 flutter test test/screenshots → build/screenshots/*.png
/// (decode them with a QR reader to check they scan).
void main() {
  const addresses = {
    'qr_http': 'http://192.168.1.20:8080/',
    'qr_ftp': 'ftp://explorer@192.168.29.123:2121',
    'qr_long': 'http://192.168.100.200:8089/Holiday%202026/Day%20one/IMG_2041.jpg?download=1',
  };

  for (final MapEntry(key: name, value: data) in addresses.entries) {
    testWidgets('round QR code $name', (tester) async {
      setScreenSize(tester, const Size(200, 200), pixelRatio: 2);
      await tester.pumpWidget(screenshotFrame(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Container(
            color: Colors.white,
            alignment: Alignment.center,
            child: RoundQrCode(data: data, size: 168),
          ),
        ),
      ));
      await saveScreenshot(tester, name);
    }, skip: !screenshotsEnabled);
  }
}
