import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:flutter_test/flutter_test.dart';

/// Icons for macOS packages (apps, installers, document packages), which
/// show as files rather than folders.
void main() {
  String? label(FileIconSpec spec) =>
      spec is LabelFileIcon ? spec.label : null;

  test('apps and installers get labelled pages, Xcode projects its logo', () {
    for (final style in FileIconStyle.values) {
      expect(label(FileIcons.forPackage('/Applications/Safari.app', style)), 'APP');
      expect(label(FileIcons.forPackage('/Users/me/Downloads/Setup.PKG', style)), 'PKG');
      expect(label(FileIcons.forPackage('/Users/me/Downloads/Suite.mpkg', style)), 'MPKG');
      final xcode = FileIcons.forPackage('/Users/me/Dev/Runner.xcodeproj', style);
      expect(xcode, isA<AssetFileIcon>());
      expect((xcode as AssetFileIcon).asset, contains('/programming/xcode'));
    }
  });

  test('document packages take their kind of document', () {
    const style = FileIconStyle.outline;
    // Not the key logo .key files get: a Keynote deck, coloured like slides.
    final keynote = FileIcons.forPackage('/Users/me/Deck.key', style) as LabelFileIcon;
    final odp = FileIcons.forFile('/Users/me/deck.odp', style) as LabelFileIcon;
    expect(keynote.label, 'KEY');
    expect(keynote.color, odp.color);
    expect(FileIcons.forFile('/Users/me/id.key', style), isA<AssetFileIcon>(),
        reason: 'a .key file still gets the key logo');

    final photos = FileIcons.forPackage('/Users/me/Pictures/Photos Library.photoslibrary', style);
    expect((photos as AssetFileIcon).asset, contains('File Type=Image'));
    final plugin = FileIcons.forPackage('/Library/Thing.bundle', style);
    expect((plugin as AssetFileIcon).asset, contains('File Type=Documents'),
        reason: 'long extensions get the generic page, not the bundler logo');
  });
}
