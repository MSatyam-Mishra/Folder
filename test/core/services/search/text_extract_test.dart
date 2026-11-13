import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:folders/core/services/search/text_extract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Reading files' text for "Search inside files", with small files made
/// here: each format's XML zipped by hand.
void main() {
  late Directory root;

  setUp(() async => root = await Directory.systemTemp.createTemp('search_text_test'));
  tearDown(() => root.delete(recursive: true));

  String write(String name, List<int> bytes) {
    final file = File(p.join(root.path, name))..writeAsBytesSync(bytes);
    return file.path;
  }

  String zip(String name, Map<String, String> parts) {
    final archive = Archive();
    for (final MapEntry(:key, :value) in parts.entries) {
      final bytes = utf8.encode(value);
      archive.addFile(ArchiveFile(key, bytes.length, bytes));
    }
    return write(name, ZipEncoder().encode(archive)!);
  }

  String? read(String path) => TextExtract.read(path, TextExtract.formatOf(path)!);

  group('plain text', () {
    test('UTF-8, with or without a byte order mark', () {
      expect(read(write('a.txt', utf8.encode('Grüße aus Köln'))), 'Grüße aus Köln');
      expect(read(write('b.md', [0xEF, 0xBB, 0xBF, ...utf8.encode('# Café')])), '# Café');
    });

    test('UTF-16 with a byte order mark, both ways round', () {
      final text = 'Rechnung über 12 €';
      final little = <int>[0xFF, 0xFE];
      final big = <int>[0xFE, 0xFF];
      for (final unit in text.codeUnits) {
        little.addAll([unit & 0xFF, unit >> 8]);
        big.addAll([unit >> 8, unit & 0xFF]);
      }
      expect(read(write('le.txt', little)), text);
      expect(read(write('be.csv', big)), text);
    });

    test('UTF-16 without a mark, as Windows tools write logs', () {
      final bytes = <int>[];
      for (final unit in 'error: disk full on drive D, retrying'.codeUnits) {
        bytes.addAll([unit, 0]);
      }
      expect(read(write('setup.log', bytes)), 'error: disk full on drive D, retrying');
    });

    test('Latin-1 when it isn\'t UTF-8', () {
      expect(read(write('old.txt', latin1.encode('café crème'))), 'café crème');
    });

    test('binary files are not text', () {
      expect(read(write('README', [0x7F, 0x45, 0x4C, 0x46, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])), isNull);
    });

    test('code, data and files without a type', () {
      expect(TextExtract.formatOf('main.dart'), ContentFormat.text);
      expect(TextExtract.formatOf('data.json'), ContentFormat.text);
      expect(TextExtract.formatOf('Makefile'), ContentFormat.text);
      expect(TextExtract.formatOf('photo.jpg'), isNull);
      expect(TextExtract.formatOf('movie.mkv'), isNull);
      expect(TextExtract.formatOf('archive.zip'), isNull);
      expect(TextExtract.formatOf('blob.bin'), isNull);
      expect(TextExtract.formatOf('report.pdf'), ContentFormat.pdf);
    });

    test('too big to read', () {
      final path = write('big', List.filled(TextExtract.maxUnknownBytes + 1, 0x61));
      expect(TextExtract.read(path, ContentFormat.text), isNull, reason: 'a file of no type: 1 MB at most');
      expect(TextExtract.read(path, ContentFormat.text, size: 5 << 30), isNull, reason: 'never a 5 GB file');
    });
  });

  test('web pages without their tags, scripts and styles', () {
    final path = write('page.html', utf8.encode('<html><head><title>T</title><style>p{color:red}</style></head>'
        '<body><script>var secret = 1;</script><p>Fish &amp; chips</p><p>caf&eacute; &#8364;5</p></body></html>'));
    final text = read(path)!;
    expect(text, contains('Fish & chips'));
    expect(text, contains('café €5'));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('color')));
    expect(text, isNot(contains('<p>')));
  });

  test('Word: the document, headers and footers', () {
    final path = zip('letter.docx', {
      '[Content_Types].xml': '<Types/>',
      'word/document.xml': '<w:document><w:body><w:p><w:r><w:t>Dear Ms</w:t></w:r><w:r><w:t xml:space="preserve"> Smith,</w:t></w:r></w:p>'
          '<w:p><w:r><w:t>Your order &amp; invoice</w:t><w:tab/><w:t>#42</w:t></w:r></w:p></w:body></w:document>',
      'word/footer1.xml': '<w:ftr><w:p><w:r><w:t>Acme Ltd</w:t></w:r></w:p></w:ftr>',
      'word/styles.xml': '<w:styles><w:style w:styleId="Heading"/></w:styles>',
    });
    final text = read(path)!;
    expect(text, contains('Dear Ms Smith,'));
    expect(text, contains('Your order & invoice #42'));
    expect(text, contains('Acme Ltd'));
    expect(text.indexOf('Dear'), lessThan(text.indexOf('Acme')), reason: 'the document first');
  });

  test('Excel: shared and inline strings', () {
    final path = zip('budget.xlsx', {
      'xl/sharedStrings.xml': '<sst><si><t>Rent</t></si><si><r><t>Elec</t></r><r><t>tricity</t></r></si></sst>',
      'xl/worksheets/sheet1.xml': '<worksheet><sheetData><row><c t="inlineStr"><is><t>Water bill</t></is></c>'
          '<c><v>1200</v></c></row></sheetData></worksheet>',
    });
    final text = read(path)!;
    expect(text, contains('Rent'));
    expect(text, contains('Electricity'));
    expect(text, contains('Water bill'));
  });

  test('PowerPoint: slides in order, then notes', () {
    final path = zip('talk.pptx', {
      'ppt/slides/slide10.xml': '<p:sld><a:p><a:r><a:t>Thank you</a:t></a:r></a:p></p:sld>',
      'ppt/slides/slide2.xml': '<p:sld><a:p><a:r><a:t>Quarterly results</a:t></a:r></a:p></p:sld>',
      'ppt/notesSlides/notesSlide1.xml': '<p:notes><a:p><a:r><a:t>Mention the merger</a:t></a:r></a:p></p:notes>',
      'ppt/slideLayouts/slideLayout1.xml': '<p:sldLayout><a:p><a:r><a:t>Click to add title</a:t></a:r></a:p></p:sldLayout>',
    });
    final text = read(path)!;
    expect(text.indexOf('Quarterly results'), lessThan(text.indexOf('Thank you')), reason: 'slide 2 before 10');
    expect(text, contains('Mention the merger'));
    expect(text, isNot(contains('Click to add title')), reason: 'layouts are not the deck');
  });

  test('OpenDocument text, sheets and slides, and flat files', () {
    const content = '<office:document-content><office:automatic-styles><style:style style:name="P1"/>'
        '</office:automatic-styles><office:body><office:text><text:h>Minutes</text:h>'
        '<text:p>Budget<text:s/>approved<text:tab/>unanimously</text:p></office:text></office:body></office:document-content>';
    for (final name in ['minutes.odt', 'sheet.ods', 'deck.odp']) {
      final text = read(zip(name, {'mimetype': 'application/vnd.oasis.opendocument.text', 'content.xml': content}))!;
      expect(text, contains('Minutes'), reason: name);
      expect(text, contains('Budget approved unanimously'), reason: name);
      expect(text, isNot(contains('P1')), reason: name);
    }
    expect(read(write('flat.fodt', utf8.encode('<?xml version="1.0"?>$content'))), contains('Budget approved'));
  });

  test('RTF: text, escapes, unicode, and no font table', () {
    // \u then 8364 (the euro sign) and the ? shown by readers without Unicode.
    const rtf = r'''{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}}{\colortbl;\red255\green0\blue0;}'''
        r'''{\*\generator Riched20;}\f0 Caf\'e9 au lait\par Price: \u''' '8364?5 ' r'''\{net\}\line Done}''';
    final text = read(write('note.rtf', latin1.encode(rtf)))!;
    expect(text, contains('Café au lait'));
    expect(text, contains('Price: €5 {net}'));
    expect(text, contains('Done'));
    expect(text, isNot(contains('Times New Roman')));
    expect(text, isNot(contains('Riched20')));
    // Folders' own new .doc files are rich text.
    expect(read(write('new.doc', latin1.encode(r'{\rtf1 Hello doc}'))), contains('Hello doc'));
    expect(read(write('word97.doc', [0xD0, 0xCF, 0x11, 0xE0, 1, 2, 3])), isNull);
  });

  test('EPUB: the chapters\' text', () {
    final path = zip('book.epub', {
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml': '<container/>',
      'OEBPS/ch1.xhtml': '<html><body><h1>Chapter One</h1><p>It was a dark &amp; stormy night.</p></body></html>',
      'OEBPS/style.css': 'p { margin: 0 }',
    });
    final text = read(path)!;
    expect(text, contains('Chapter One'));
    expect(text, contains('dark & stormy night'));
    expect(text, isNot(contains('margin')));
  });

  test('a damaged package reads as nothing', () {
    expect(read(write('broken.docx', Uint8List.fromList(utf8.encode('PK not really a zip')))), isNull);
  });

  test("a big file that isn't a zip is passed over at once", () {
    // The archive package alone would look for a zip's end byte by byte,
    // re-reading a megabyte each time: hours for this.
    final path = write('renamed.pptx', List.filled(3 << 20, 0x78));
    final clock = Stopwatch()..start();
    expect(read(path), isNull);
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('a zip with a long comment still reads', () {
    final archive = Archive();
    final xml = utf8.encode('<w:document><w:p><w:r><w:t>Commented</w:t></w:r></w:p></w:document>');
    archive.addFile(ArchiveFile('word/document.xml', xml.length, xml));
    archive.comment = 'c' * 5000;
    expect(read(write('comment.docx', ZipEncoder().encode(archive)!)), contains('Commented'));
  });
}
