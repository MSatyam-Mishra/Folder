import 'package:folder/shared/widgets/round_qr_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart' show QrCode, QrErrorCorrectLevel, QrImage;

void main() {
  test('alignment markers are where every QR version has them', () {
    for (var version = 1; version <= 40; version++) {
      final code = QrCode(version, QrErrorCorrectLevel.Q)..addData('x');
      final image = QrImage(code);
      final n = image.moduleCount;
      final centers = qrAlignmentCenters(version, n);
      final count = version < 2 ? 0 : (version ~/ 7 + 2) * (version ~/ 7 + 2) - 3;
      expect(centers, hasLength(count), reason: 'version $version');
      for (final (r, c) in centers) {
        // Dark centre, light ring, dark ring.
        expect(image.isDark(r, c), isTrue, reason: 'v$version ($r, $c)');
        expect(image.isDark(r - 1, c) || image.isDark(r, c + 1), isFalse, reason: 'v$version ($r, $c)');
        expect(image.isDark(r - 2, c) && image.isDark(r + 2, c + 2), isTrue, reason: 'v$version ($r, $c)');
      }
    }
  });
}
