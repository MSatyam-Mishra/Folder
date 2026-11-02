import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show IconData;
import 'package:image/image.dart' as img;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

/// A kind of file the + button can create.
class NewFileKind {
  const NewFileKind(this.extension, this.label, this.baseName, this.icon, this.group, [this.starter = '']);

  /// Without the dot; also what's saved for a kind that's been ticked.
  final String extension;
  final String label;

  /// The name a new one gets, before the extension.
  final String baseName;
  final IconData icon;
  final String group;

  /// What a text format starts with.
  final String starter;

  String get fileName => '$baseName.$extension';
  String get menuLabel => '$label (.$extension)';
}

/// The kinds of file that can be created, which of them the + button offers,
/// and their blank contents.
abstract final class NewFiles {
  static const _documents = 'Documents';
  static const _sheets = 'Spreadsheets';
  static const _slides = 'Presentations';
  static const _code = 'Web and code';
  static const _images = 'Images';
  static const _archives = 'Archives';

  static const _prefsKey = 'new_file_kinds';

  /// Offered until the user picks.
  static const standard = ['txt', 'docx'];

  static const kinds = <NewFileKind>[
    NewFileKind('txt', 'Text file', 'New Text Document', LucideIcons.fileText, _documents),
    NewFileKind('docx', 'Word document', 'New Word Document', LucideIcons.fileText, _documents),
    NewFileKind('doc', 'Word 97-2003 document', 'New Word Document', LucideIcons.fileText, _documents),
    NewFileKind('rtf', 'Rich text', 'New Rich Text Document', LucideIcons.fileType, _documents),
    NewFileKind('odt', 'OpenDocument text', 'New Document', LucideIcons.fileText, _documents),
    NewFileKind('md', 'Markdown', 'New Markdown Document', LucideIcons.fileText, _documents),
    NewFileKind('pdf', 'PDF', 'New PDF Document', LucideIcons.fileText, _documents),
    NewFileKind('xlsx', 'Excel workbook', 'New Excel Workbook', LucideIcons.fileSpreadsheet, _sheets),
    NewFileKind('xls', 'Excel 97-2003 workbook', 'New Excel Workbook', LucideIcons.fileSpreadsheet, _sheets),
    NewFileKind('ods', 'OpenDocument spreadsheet', 'New Spreadsheet', LucideIcons.fileSpreadsheet, _sheets),
    NewFileKind('csv', 'CSV', 'New Spreadsheet', LucideIcons.fileSpreadsheet, _sheets),
    NewFileKind('tsv', 'TSV', 'New Spreadsheet', LucideIcons.fileSpreadsheet, _sheets),
    NewFileKind('pptx', 'PowerPoint presentation', 'New Presentation', LucideIcons.presentation, _slides),
    NewFileKind('odp', 'OpenDocument presentation', 'New Presentation', LucideIcons.presentation, _slides),
    NewFileKind('html', 'HTML page', 'index', LucideIcons.fileCode, _code,
        '<!doctype html>\n<html>\n<head>\n  <meta charset="utf-8">\n  <title></title>\n</head>\n<body>\n\n</body>\n</html>\n'),
    NewFileKind('css', 'CSS', 'styles', LucideIcons.fileCode, _code),
    NewFileKind('js', 'JavaScript', 'script', LucideIcons.fileCode, _code),
    NewFileKind('ts', 'TypeScript', 'script', LucideIcons.fileCode, _code),
    NewFileKind('json', 'JSON', 'data', LucideIcons.fileJson, _code, '{}\n'),
    NewFileKind('xml', 'XML', 'data', LucideIcons.fileCode, _code, '<?xml version="1.0" encoding="UTF-8"?>\n<root/>\n'),
    NewFileKind('yaml', 'YAML', 'config', LucideIcons.fileCode, _code),
    NewFileKind('toml', 'TOML', 'config', LucideIcons.fileCode, _code),
    NewFileKind('ini', 'INI', 'config', LucideIcons.fileCog, _code),
    NewFileKind('py', 'Python', 'script', LucideIcons.fileCode, _code),
    NewFileKind('dart', 'Dart', 'main', LucideIcons.fileCode, _code),
    NewFileKind('java', 'Java', 'Main', LucideIcons.fileCode, _code),
    NewFileKind('kt', 'Kotlin', 'Main', LucideIcons.fileCode, _code),
    NewFileKind('c', 'C', 'main', LucideIcons.fileCode, _code),
    NewFileKind('cpp', 'C++', 'main', LucideIcons.fileCode, _code),
    NewFileKind('h', 'C/C++ header', 'header', LucideIcons.fileCode, _code),
    NewFileKind('cs', 'C#', 'Program', LucideIcons.fileCode, _code),
    NewFileKind('go', 'Go', 'main', LucideIcons.fileCode, _code),
    NewFileKind('rs', 'Rust', 'main', LucideIcons.fileCode, _code),
    NewFileKind('php', 'PHP', 'index', LucideIcons.fileCode, _code, '<?php\n'),
    NewFileKind('rb', 'Ruby', 'script', LucideIcons.fileCode, _code),
    NewFileKind('sql', 'SQL', 'query', LucideIcons.fileCode, _code),
    NewFileKind('sh', 'Shell script', 'script', LucideIcons.fileTerminal, _code, '#!/bin/sh\n'),
    NewFileKind('bat', 'Batch file', 'script', LucideIcons.fileTerminal, _code),
    NewFileKind('ps1', 'PowerShell script', 'script', LucideIcons.fileTerminal, _code),
    NewFileKind('svg', 'SVG image', 'New Image', LucideIcons.fileImage, _images,
        '<svg xmlns="http://www.w3.org/2000/svg" width="800" height="600" viewBox="0 0 800 600"></svg>\n'),
    NewFileKind('png', 'PNG image', 'New Image', LucideIcons.fileImage, _images),
    NewFileKind('jpg', 'JPEG image', 'New Image', LucideIcons.fileImage, _images),
    NewFileKind('bmp', 'Bitmap image', 'New Image', LucideIcons.fileImage, _images),
    NewFileKind('zip', 'ZIP archive', 'New Archive', LucideIcons.fileArchive, _archives),
    NewFileKind('tar', 'TAR archive', 'New Archive', LucideIcons.fileArchive, _archives),
  ];

  /// The groups, in the order shown, with their kinds.
  static Map<String, List<NewFileKind>> get grouped {
    final groups = <String, List<NewFileKind>>{};
    for (final kind in kinds) {
      groups.putIfAbsent(kind.group, () => []).add(kind);
    }
    return groups;
  }

  /// The extensions the + button offers.
  static Future<Set<String>> chosen() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_prefsKey) ?? standard).toSet();
  }

  static Future<void> setChosen(Set<String> extensions) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, extensions.toList());
  }

  /// [kind]'s default name, with a number if [folder] already has that one.
  static String freeName(String folder, NewFileKind kind) {
    bool taken(String name) {
      final path = '$folder${Platform.pathSeparator}$name';
      return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
    }

    if (!taken(kind.fileName)) return kind.fileName;
    for (var n = 2;; n++) {
      final name = '${kind.baseName} ($n).${kind.extension}';
      if (!taken(name)) return name;
    }
  }

  /// Creates a blank file of [kind] at [path]; never over an existing one.
  static Future<void> create(NewFileKind kind, String path) async {
    final bytes = await contents(kind);
    final file = File(path);
    await file.create(exclusive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  /// A blank file of [kind].
  static Future<List<int>> contents(NewFileKind kind) async {
    switch (kind.extension) {
      case 'docx':
        return _docx();
      // Word and the others read rich text whatever the name says; a real
      // .doc can't be written here, and saving from Word makes it one.
      case 'doc' || 'rtf':
        return ascii.encode('{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Calibri;}}\\f0\\fs22\\par}\n');
      case 'odt':
        return _openDocument('text', '<office:text><text:p/></office:text>');
      case 'pdf':
        return _pdf();
      case 'xlsx':
        return _xlsx();
      case 'xls' || 'pptx':
        final data = await rootBundle.load('assets/new_files/blank.${kind.extension}');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      case 'ods':
        return _openDocument(
          'spreadsheet',
          '<office:spreadsheet><table:table table:name="Sheet1"><table:table-column/>'
              '<table:table-row><table:table-cell/></table:table-row></table:table></office:spreadsheet>',
        );
      case 'odp':
        return _openDocument(
          'presentation',
          '<office:presentation><draw:page draw:name="Slide1" draw:master-page-name="Default"/></office:presentation>',
          styles: '<office:master-styles><style:master-page style:name="Default"/></office:master-styles>',
        );
      case 'png':
        return img.encodePng(_whiteImage());
      case 'jpg':
        return img.encodeJpg(_whiteImage());
      case 'bmp':
        return img.encodeBmp(_whiteImage());
      case 'zip':
        // An archive with nothing in it is only its end record.
        return [0x50, 0x4B, 0x05, 0x06, ...List.filled(18, 0)];
      case 'tar':
        return Uint8List(1024);
      default:
        return utf8.encode(kind.starter);
    }
  }

  static img.Image _whiteImage() =>
      img.fill(img.Image(width: 1280, height: 720), color: img.ColorRgb8(255, 255, 255));

  static const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  static const _relationships = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  static List<int> _zip(List<(String, String)> parts) {
    final archive = Archive();
    for (final (name, text) in parts) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive)!;
  }

  static List<int> _office(String mainPart, String mainType, String main, List<(String, String)> others, String overrides) => _zip([
        (
          '[Content_Types].xml',
          '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
              '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
              '<Default Extension="xml" ContentType="application/xml"/>'
              '<Override PartName="/$mainPart" ContentType="$mainType"/>$overrides</Types>',
        ),
        (
          '_rels/.rels',
          '$_xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="$_relationships/officeDocument" Target="$mainPart"/></Relationships>',
        ),
        (mainPart, main),
        ...others,
      ]);

  static List<int> _docx() => _office(
        'word/document.xml',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml',
        '$_xmlHead<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body><w:p/></w:body></w:document>',
        const [],
        '',
      );

  static List<int> _xlsx() {
    const sheetXml = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
    return _office(
      'xl/workbook.xml',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml',
      '$_xmlHead<workbook xmlns="$sheetXml" xmlns:r="$_relationships">'
          '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
      [
        (
          'xl/_rels/workbook.xml.rels',
          '$_xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
              '<Relationship Id="rId1" Type="$_relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
        ),
        ('xl/worksheets/sheet1.xml', '$_xmlHead<worksheet xmlns="$sheetXml"><sheetData/></worksheet>'),
      ],
      '<Override PartName="/xl/worksheets/sheet1.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
    );
  }

  /// An OpenDocument package; its "mimetype" goes first and uncompressed.
  static List<int> _openDocument(String type, String body, {String styles = ''}) {
    final mime = 'application/vnd.oasis.opendocument.$type';
    const spaces = 'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
        'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
        'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
        'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" office:version="1.2"';
    final archive = Archive();
    final mimeBytes = ascii.encode(mime);
    archive.addFile(ArchiveFile.noCompress('mimetype', mimeBytes.length, mimeBytes));
    void add(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add(
      'META-INF/manifest.xml',
      '$_xmlHead<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">'
          '<manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="$mime"/>'
          '<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>'
          '<manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>'
          '</manifest:manifest>',
    );
    add('content.xml', '$_xmlHead<office:document-content $spaces><office:body>$body</office:body></office:document-content>');
    add('styles.xml', '$_xmlHead<office:document-styles $spaces>$styles</office:document-styles>');
    return ZipEncoder().encode(archive)!;
  }

  /// One empty A4 page.
  static List<int> _pdf() {
    const objects = [
      '<</Type/Catalog/Pages 2 0 R>>',
      '<</Type/Pages/Kids[3 0 R]/Count 1>>',
      '<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]/Resources<<>>>>',
    ];
    final out = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(out.length);
      out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final table = out.length;
    out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
    for (final offset in offsets) {
      out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    out.write('trailer\n<</Size ${objects.length + 1}/Root 1 0 R>>\nstartxref\n$table\n%%EOF\n');
    return ascii.encode(out.toString());
  }
}
