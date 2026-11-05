import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:folder/core/services/bookmark_service.dart';
import 'package:folder/core/services/local_content_server.dart';
import 'package:folder/features/viewer_epub/reader/reader_session.dart';
import 'package:folder/features/viewer_epub/reader/reader_settings.dart';
import 'package:folder/features/viewer_epub/screens/epub_viewer_screen.dart';
import 'package:folder/features/viewer_epub/widgets/reader_controls.dart';
import 'package:folder/features/viewer_epub/widgets/reader_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import 'doc_viewer_harness.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/epub_viewer_screens_test.dart
///
/// The page itself is a WebView, which the test engine can't show: the
/// reader screen is captured around it (loading page, contents, sheets),
/// and the floating controls are shown over a mock page in every theme.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File book;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    InAppWebViewPlatform.instance = _FakeWebViewPlatform();
    // Process-wide singletons must start outside a test's fake-async zone,
    // or later tests wait on futures of a finished zone.
    await ReaderSession.cacheDirectory();
    LocalContentServer.instance.unmount(
      await LocalContentServer.instance.mount((_) async => null),
    );
    dir = await sampleDir('epub');
    book = File(p.join(dir.path, 'The Lighthouse Keeper.epub'));
    await book.writeAsBytes(_sampleEpub());
  });

  tearDownAll(() async {
    if (screenshotsEnabled) await dir.delete(recursive: true);
  });

  for (final (mode, device, size) in shotVariants) {
    final tag = '${mode.name}_$device';
    final phone = device == 'phone';

    testWidgets('epub reader $tag', (tester) async {
      await pumpViewer(
        tester,
        EpubViewerScreen(epubFile: book),
        mode: mode,
        size: size,
        beforePush: () async {
          if ((await BookmarkService().getBookmarks(book.path)).isEmpty) {
            await BookmarkService().saveLastReadPosition(book.path, null);
            await BookmarkService().addBookmark(
              book.path,
              {'spine': 1, 'progress': 0.4},
              'The storm · 32%',
            );
          }
        },
      );
      await settleUntil(tester, find.byTooltip('Reading settings'));
      await saveScreenshot(tester, 'epub_loading_$tag');

      if (phone) {
        await tester.tap(find.byTooltip('Contents & bookmarks'));
        await settle(tester, rounds: 5);
      }
      await saveScreenshot(tester, 'epub_contents_$tag');
      await tester.tap(find.textContaining('Bookmarks').last);
      await settle(tester, rounds: 4);
      await saveScreenshot(tester, 'epub_bookmarks_$tag');
      if (phone) {
        Scaffold.of(tester.element(find.byType(Drawer))).closeDrawer();
        await settle(tester, rounds: 8);
      }

      await tester.tap(find.byTooltip('Reading settings'));
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'epub_settings_$tag');
      await dismissTop(tester);

      await tester.tap(find.byTooltip('Search in book'));
      await settle(tester, rounds: 4);
      await tester.enterText(find.byType(TextField).last, 'lamp');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester, rounds: 10);
      await saveScreenshot(tester, 'epub_search_$tag');
      await dismissTop(tester);
      await finish(tester);
    }, skip: !screenshotsEnabled);

    testWidgets('epub controls $tag', (tester) async {
      await pumpViewer(
        tester,
        const _ControlsPreview(),
        mode: mode,
        size: size,
      );
      await settle(tester, rounds: 3);
      await saveScreenshot(tester, 'epub_controls_$tag');
    }, skip: !screenshotsEnabled);
  }

  testWidgets('epub settings fixed layout + error', (tester) async {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      final broken = File(p.join(dir.path, 'Broken.epub'));
      await tester.runAsync(() => broken.writeAsBytes(utf8.encode('not a zip')));
      await pumpViewer(tester, EpubViewerScreen(epubFile: broken), mode: mode, size: const Size(390, 844));
      await settle(tester, rounds: 8);
      await saveScreenshot(tester, 'epub_error_${mode.name}_phone');
      final ctx = tester.element(find.byType(EpubViewerScreen));
      ReaderSettingsSheet.show(
        ctx,
        initial: const ReaderSettings(theme: ReaderTheme.sepia),
        onChanged: (_) {},
        fixedLayout: true,
      );
      await settle(tester, rounds: 6);
      await saveScreenshot(tester, 'epub_settings_fixed_${mode.name}_phone');
      await dismissTop(tester);
    }
    await finish(tester);
  }, skip: !screenshotsEnabled);
}

/// The floating reader controls and footer over a mock page, once per page
/// theme.
class _ControlsPreview extends StatelessWidget {
  const _ControlsPreview();

  @override
  Widget build(BuildContext context) {
    final themes = ReaderTheme.values
        .map((t) => t.resolve(Theme.of(context).brightness))
        .toList();
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 700;
            final pages = [
              for (final t in wide ? themes : themes.skip(1).take(3)) _page(t),
            ];
            return wide
                ? Row(children: [for (final pg in pages) Expanded(child: pg)])
                : Column(children: [for (final pg in pages) Expanded(child: pg)]);
          },
        ),
      ),
    );
  }

  Widget _page(ReaderTheme theme) {
    return ColoredBox(
      color: theme.background,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'The lamp had burned through the night, and by morning '
                    'the sea lay flat and grey under a low sky. ' * 6,
                    style: TextStyle(
                      color: theme.foreground,
                      fontSize: 15,
                      height: 1.5,
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: ReaderControlsPanel(
                    theme: theme,
                    title: 'Chapter 2 · The storm',
                    detail: 'Page 3 of 12 in this section · 32% of book',
                    value: 0.32,
                    labelFor: (v) => '${(v * 100).round()}%',
                    onChanged: (_) {},
                    onChangeEnd: (_) {},
                    onPrevChapter: () {},
                    onNextChapter: () {},
                  ),
                ),
              ],
            ),
          ),
          ReaderFooter(
            theme: theme,
            title: 'Chapter 2 · The storm',
            status: '3/12 · 32%',
          ),
        ],
      ),
    );
  }
}

/// The WebView plugin isn't available in tests: an empty view stands in.
class _FakeWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakeWebView(params);
}

class _FakeWebView extends PlatformInAppWebViewWidget {
  _FakeWebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

List<int> _sampleEpub() {
  final chapters = [
    ('Arrival', 'The lamp had burned through the night'),
    ('The storm', 'Wind found every gap in the old stone walls'),
    ('Ships in the dark', 'Three lights moved on the horizon'),
    ('Morning', 'By dawn the sea had forgotten everything'),
    ('The letter', 'A boat brought a letter and a sack of flour'),
  ];
  final archive = Archive();
  void add(String name, String text, {bool store = false}) {
    final bytes = utf8.encode(text);
    final file = ArchiveFile(name, bytes.length, bytes);
    if (store) file.compress = false;
    archive.addFile(file);
  }

  add('mimetype', 'application/epub+zip', store: true);
  add('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  final manifest = StringBuffer();
  final spine = StringBuffer();
  final nav = StringBuffer();
  for (var i = 0; i < chapters.length; i++) {
    final (title, line) = chapters[i];
    manifest.writeln('<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>');
    spine.writeln('<itemref idref="c$i"/>');
    nav.writeln('<li><a href="c$i.xhtml">Chapter ${i + 1} · $title</a>'
        '${i == 1 ? '<ol><li><a href="c$i.xhtml#s1">The first wave</a></li><li><a href="c$i.xhtml#s2">Keeping the lamp lit</a></li></ol>' : ''}</li>');
    add('OEBPS/c$i.xhtml', '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head>
<body><h1>Chapter ${i + 1}: $title</h1>
<p id="s1">$line, and the keeper climbed the stairs to trim the wick of the lamp.</p>
<p id="s2">${'The sea was loud against the rocks. ' * 20}</p>
</body></html>''');
  }
  manifest.writeln('<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>');
  add('OEBPS/nav.xhtml', '''<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>
$nav</ol></nav></body></html>''');
  add('OEBPS/content.opf', '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:uuid:12345678-1234-1234-1234-123456789abc</dc:identifier>
    <dc:title>The Lighthouse Keeper</dc:title>
    <dc:creator>Ada Marlowe</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine>
$spine  </spine>
</package>''');
  return ZipEncoder().encode(archive)!;
}
