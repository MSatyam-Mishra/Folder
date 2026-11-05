import 'package:folder/core/files/file_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// macOS packages (folders Finder opens as one item) and installers.
void main() {
  test('apps and document packages are packages; frameworks are folders', () {
    for (final path in [
      '/Applications/Safari.app',
      '/Library/PreferencePanes/Java.prefPane',
      '/Users/me/Notes.rtfd',
      '/Users/me/Pictures/Photos Library.photoslibrary',
      '/Users/me/Dev/Runner.xcodeproj',
      '/Users/me/Downloads/Setup.PKG',
    ]) {
      expect(FileTypes.isMacPackage(path), isTrue, reason: path);
    }
    for (final path in [
      '/Library/Frameworks/Python.framework',
      '/Applications/Safari.app/Contents/Resources/en.lproj',
      '/Users/me/Documents',
      '/Users/me/my.app.backup',
    ]) {
      expect(FileTypes.isMacPackage(path), isFalse, reason: path);
    }
  });

  test('.pkg is a macOS installer but an unknown kind everywhere', () {
    expect(FileTypes.macInstaller, containsAll(['pkg', 'mpkg']));
    // Elsewhere a .pkg is often a game package: it keeps the Open with
    // chooser. On macOS the browser hands it to Installer instead.
    expect(FileTypes.kindOf('/Users/me/Downloads/Setup.pkg'), FileKind.unknown);
    expect(FileTypes.kindOf('/Users/me/Downloads/Bundle.mpkg'), FileKind.unknown);
    expect(FileTypes.kindOf('/Users/me/Downloads/App.dmg'), FileKind.package);
  });
}
