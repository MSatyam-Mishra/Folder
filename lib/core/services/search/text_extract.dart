import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:folders/core/files/file_types.dart';

/// How a file's text is read for searching inside it.
enum ContentFormat {
  /// Plain text and code: UTF-8, UTF-16 with a byte order mark, else Latin-1.
  text,

  /// A web page: its text without the tags.
  html,

  /// Word (.docx), Excel (.xlsx), PowerPoint (.pptx), OpenDocument (.odt,
  /// .ods, .odp): the text in their XML parts.
  word,
  sheet,
  slides,
  openDocument,

  rtf,
  epub,

  /// Read with PDFium, outside the search's isolate.
  pdf,
}

/// The text inside files, for searching in it. Everything here is
/// synchronous plain Dart, for the search's isolate.
abstract final class TextExtract {
  /// The largest files read, by kind: nothing reads a 4 GB file.
  static const maxTextBytes = 16 << 20;
  static const maxPackageBytes = 100 << 20;
  static const maxPdfBytes = 100 << 20;

  /// A file of no known type is read only when it's small and looks like
  /// text.
  static const maxUnknownBytes = 1 << 20;

  /// One XML part unpacked from a package, and all of them together.
  static const maxPartBytes = 32 << 20;
  static const maxUnpackedBytes = 64 << 20;

  /// How [path]'s text is read, going by its name; null when it has none
  /// worth reading (pictures, videos, archives…).
  static ContentFormat? formatOf(String path) {
    final kind = FileTypes.kindOf(path);
    switch (kind) {
      case FileKind.html:
        return ContentFormat.html;
      case FileKind.code ||
            FileKind.text ||
            FileKind.markdown ||
            FileKind.json ||
            FileKind.delimited ||
            FileKind.svg:
        return ContentFormat.text;
      case FileKind.word:
        return ContentFormat.word;
      case FileKind.spreadsheet:
        return ContentFormat.sheet;
      case FileKind.presentation:
        return ContentFormat.slides;
      case FileKind.openDocumentText || FileKind.openDocumentSpreadsheet || FileKind.openDocumentPresentation:
        return ContentFormat.openDocument;
      // Folders' own new .doc files are rich text; real Word 97 files
      // aren't read.
      case FileKind.richText || FileKind.legacyWord:
        return ContentFormat.rtf;
      case FileKind.epub:
        return ContentFormat.epub;
      case FileKind.pdf:
        return ContentFormat.pdf;
      case FileKind.unknown:
        return FileTypes.extensionOf(path).isEmpty ? ContentFormat.text : null;
      default:
        return null;
    }
  }

  /// The largest file of [format] (at [path]) that's read.
  static int maxBytes(ContentFormat format, String path) => switch (format) {
        ContentFormat.text =>
          FileTypes.kindOf(path) == FileKind.unknown ? maxUnknownBytes : maxTextBytes,
        ContentFormat.html || ContentFormat.rtf => maxTextBytes,
        ContentFormat.pdf => maxPdfBytes,
        _ => maxPackageBytes,
      };

  /// The text in [path], read as [format]; null when it can't be read, is
  /// too big, or isn't text after all.
  static String? read(String path, ContentFormat format, {int? size}) {
    try {
      final length = size ?? File(path).lengthSync();
      if (length > maxBytes(format, path)) return null;
      switch (format) {
        case ContentFormat.text:
          return decode(File(path).readAsBytesSync());
        case ContentFormat.html:
          final text = decode(File(path).readAsBytesSync());
          return text == null ? null : htmlText(text);
        case ContentFormat.rtf:
          final bytes = File(path).readAsBytesSync();
          if (!_startsWith(bytes, '{\\rtf')) return null;
          return rtfText(latin1.decode(bytes));
        case ContentFormat.openDocument:
          // A flat OpenDocument file (.fodt) is the XML itself.
          final bytes = File(path).readAsBytesSync();
          if (!_startsWith(bytes, 'PK')) return openDocumentText(utf8.decode(bytes, allowMalformed: true));
          return _fromPackage(path, format);
        case ContentFormat.word || ContentFormat.sheet || ContentFormat.slides || ContentFormat.epub:
          return _fromPackage(path, format);
        case ContentFormat.pdf:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  static bool _startsWith(List<int> bytes, String ascii) {
    if (bytes.length < ascii.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  // Plain text.

  /// [bytes] as text: UTF-8 or UTF-16 by their byte order mark, UTF-16
  /// without one when every other byte is zero, else UTF-8, else Latin-1.
  /// Null for what looks binary (zero bytes).
  static String? decode(Uint8List bytes) {
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(Uint8List.sublistView(bytes, 3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes, 2, little: true);
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes, 2, little: false);
    final guess = _utf16Guess(bytes);
    if (guess != null) return _utf16(bytes, 0, little: guess);
    final probe = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < probe; i++) {
      if (bytes[i] == 0) return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static String _utf16(Uint8List bytes, int start, {required bool little}) {
    final count = (bytes.length - start) ~/ 2;
    final units = Uint16List(count);
    for (var i = 0; i < count; i++) {
      final a = bytes[start + 2 * i];
      final b = bytes[start + 2 * i + 1];
      units[i] = little ? a | (b << 8) : (a << 8) | b;
    }
    return String.fromCharCodes(units);
  }

  /// Little-endian (true) or big-endian (false) UTF-16 by the zero bytes of
  /// mostly-ASCII text; null when it doesn't look like UTF-16.
  static bool? _utf16Guess(Uint8List bytes) {
    final length = (bytes.length < 4096 ? bytes.length : 4096) & ~1;
    if (length < 16) return null;
    var evenZeros = 0;
    var oddZeros = 0;
    for (var i = 0; i < length; i += 2) {
      if (bytes[i] == 0) evenZeros++;
      if (bytes[i + 1] == 0) oddZeros++;
    }
    final pairs = length ~/ 2;
    if (oddZeros > pairs * 0.4 && evenZeros < pairs * 0.05) return true;
    if (evenZeros > pairs * 0.4 && oddZeros < pairs * 0.05) return false;
    return null;
  }

  // Markup.

  static final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);');

  static const _named = {
    'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'ndash': '–',
    'mdash': '—', 'lsquo': '‘', 'rsquo': '’', 'ldquo': '“', 'rdquo': '”', 'hellip': '…',
    'copy': '©', 'reg': '®', 'trade': '™', 'euro': '€', 'pound': '£', 'laquo': '«',
    'raquo': '»', 'bull': '•', 'middot': '·', 'eacute': 'é', 'egrave': 'è', 'aacute': 'á',
    'agrave': 'à', 'uuml': 'ü', 'ouml': 'ö', 'auml': 'ä', 'szlig': 'ß', 'ccedil': 'ç',
  };

  /// XML and HTML entities (&amp;, &#233;, &#xE9;, &eacute;) as characters.
  static String entities(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(_entity, (m) {
      final name = m.group(1)!;
      if (name.startsWith('#x')) {
        final code = int.tryParse(name.substring(2), radix: 16);
        return code == null || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
      }
      if (name.startsWith('#')) {
        final code = int.tryParse(name.substring(1));
        return code == null || code > 0x10FFFF ? m.group(0)! : String.fromCharCode(code);
      }
      return _named[name] ?? _named[name.toLowerCase()] ?? m.group(0)!;
    });
  }

  static final _hidden = RegExp(r'<(script|style|head)\b[^>]*>.*?</\1\s*>|<!--.*?-->', caseSensitive: false, dotAll: true);
  static final _breaks = RegExp(r'<br\b[^>]*>|</(p|div|li|h[1-6]|tr|td|th|title|blockquote|pre|section|article)\s*>',
      caseSensitive: false);
  static final _tag = RegExp(r'<[^>]*>');

  /// A web page's text, without its tags, scripts and styles.
  static String htmlText(String html) {
    final text = html.replaceAll(_hidden, ' ').replaceAll(_breaks, '\n').replaceAll(_tag, '');
    return entities(text);
  }

  /// The text runs of an Office part: [run] holds a run's text in group 1;
  /// [breakTag] matches what ends a paragraph or breaks a line.
  static String _runs(String xml, RegExp pattern) {
    final out = StringBuffer();
    for (final m in pattern.allMatches(xml)) {
      final text = m.group(1);
      if (text != null) {
        out.write(entities(text));
      } else {
        out.write(m.group(0)!.startsWith('</') ? '\n' : ' ');
      }
    }
    return out.toString();
  }

  static final _wordRuns = RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>|<w:(?:tab|br|cr)\b[^>]*/>|</w:p>');
  static final _slideRuns = RegExp(r'<a:t(?:\s[^>]*)?>([^<]*)</a:t>|<a:br\b[^>]*/>|</a:p>');
  static final _sheetRuns = RegExp(r'<t(?:\s[^>]*)?>([^<]*)</t>|</si>|</is>');

  /// Word's document.xml (and headers, footers, notes) as text.
  static String wordText(String xml) => _runs(xml, _wordRuns);

  /// A PowerPoint slide's (or its notes') text.
  static String slideText(String xml) => _runs(xml, _slideRuns);

  /// Excel's shared strings, and a sheet's own (inline) strings.
  static String sheetText(String xml) => _runs(xml, _sheetRuns);

  static final _odfSpace = RegExp(r'<text:s\b[^>]*/>|<text:tab\b[^>]*/>');
  static final _odfBreak = RegExp(r'<text:line-break\b[^>]*/>|</text:p>|</text:h>');

  /// OpenDocument's content.xml as text.
  static String openDocumentText(String xml) {
    // Styles and fonts hold no text, only attributes.
    final body = xml.contains('<office:body') ? xml.substring(xml.indexOf('<office:body')) : xml;
    return entities(body.replaceAll(_odfSpace, ' ').replaceAll(_odfBreak, '\n').replaceAll(_tag, ''));
  }

  static int _partNumber(String name) => int.tryParse(RegExp(r'(\d+)\.xml$').firstMatch(name)?.group(1) ?? '') ?? 0;

  /// The parts of a package to read for [format], in order.
  static List<ArchiveFile> _partsFor(Archive archive, ContentFormat format) {
    bool numbered(ArchiveFile f, String prefix) =>
        f.name.startsWith(prefix) && RegExp(r'\d+\.xml$').hasMatch(f.name);
    final List<ArchiveFile> parts;
    switch (format) {
      case ContentFormat.word:
        parts = [
          for (final f in archive.files)
            if (f.name == 'word/document.xml' ||
                RegExp(r'^word/(header|footer)\d*\.xml$').hasMatch(f.name) ||
                const {'word/footnotes.xml', 'word/endnotes.xml', 'word/comments.xml'}.contains(f.name))
              f,
        ];
        parts.sort((a, b) => a.name == 'word/document.xml' ? -1 : (b.name == 'word/document.xml' ? 1 : 0));
      case ContentFormat.sheet:
        parts = [
          for (final f in archive.files)
            if (f.name == 'xl/sharedStrings.xml' || numbered(f, 'xl/worksheets/sheet')) f,
        ];
      case ContentFormat.slides:
        final slides = [for (final f in archive.files) if (numbered(f, 'ppt/slides/slide')) f]
          ..sort((a, b) => _partNumber(a.name).compareTo(_partNumber(b.name)));
        final notes = [for (final f in archive.files) if (numbered(f, 'ppt/notesSlides/notesSlide')) f]
          ..sort((a, b) => _partNumber(a.name).compareTo(_partNumber(b.name)));
        parts = [...slides, ...notes];
      case ContentFormat.openDocument:
        parts = [for (final f in archive.files) if (f.name == 'content.xml') f];
      case ContentFormat.epub:
        parts = [
          for (final f in archive.files)
            if (f.isFile && RegExp(r'\.(x?html?)$', caseSensitive: false).hasMatch(f.name)) f,
        ];
      default:
        parts = const [];
    }
    return parts;
  }

  /// How far from the end of [path] its zip directory record starts, or
  /// null when it has none: not a zip, or a damaged one. The archive
  /// package looks for it byte by byte from the end, re-reading a 1 MB
  /// buffer at each step, which takes hours on a big file that isn't a zip.
  static int? _zipEndRecord(String path) {
    final file = File(path).openSync();
    try {
      final length = file.lengthSync();
      // The record is 22 bytes, plus a comment of up to 64 KB.
      final tail = length < 22 + 0xFFFF ? length : 22 + 0xFFFF;
      if (tail < 22) return null;
      file.setPositionSync(length - tail);
      final bytes = file.readSync(tail);
      for (var i = bytes.length - 22; i >= 0; i--) {
        if (bytes[i] == 0x50 && bytes[i + 1] == 0x4B && bytes[i + 2] == 5 && bytes[i + 3] == 6) {
          return bytes.length - i;
        }
      }
      return null;
    } finally {
      file.closeSync();
    }
  }

  static String? _fromPackage(String path, ContentFormat format) {
    final fromEnd = _zipEndRecord(path);
    if (fromEnd == null) return null;
    final input = InputFileStream(path);
    try {
      // A long zip comment would make the archive package's search slow
      // too: such a zip is read from memory, if it's small enough.
      final archive = fromEnd <= 1024
          ? ZipDecoder().decodeBuffer(input)
          : (input.length <= maxPartBytes ? ZipDecoder().decodeBytes(File(path).readAsBytesSync()) : null);
      if (archive == null) return null;
      final out = StringBuffer();
      var unpacked = 0;
      for (final part in _partsFor(archive, format)) {
        if (part.size > maxPartBytes) continue;
        unpacked += part.size;
        if (unpacked > maxUnpackedBytes) break;
        final content = part.content;
        if (content is! List<int>) continue;
        final xml = utf8.decode(content, allowMalformed: true);
        out.writeln(switch (format) {
          ContentFormat.word => wordText(xml),
          ContentFormat.sheet => sheetText(xml),
          ContentFormat.slides => slideText(xml),
          ContentFormat.openDocument => openDocumentText(xml),
          _ => htmlText(xml),
        });
      }
      return out.toString();
    } catch (_) {
      return null;
    } finally {
      input.closeSync();
    }
  }

  // Rich text.

  /// RTF groups whose words aren't the document's text.
  static const _skippedGroups = {
    'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'object', 'themedata',
    'colorschememapping', 'datastore', 'latentstyles', 'listtable', 'listoverridetable',
    'rsidtbl', 'generator', 'xmlnstbl', 'mmathpr', 'fldinst', 'bkmkstart', 'bkmkend',
    'filetbl', 'revtbl', 'pgdsctbl', 'wgrffmtfilter', 'passwordhash',
  };

  /// Windows-1252's characters at 0x80–0x9F, where Latin-1 has controls.
  static const _cp1252 = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
    0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022,
    0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
  ];

  static String _byte(int code) =>
      String.fromCharCode(code >= 0x80 && code <= 0x9F ? _cp1252[code - 0x80] : code);

  /// An RTF document's text: groups such as the font table are left out,
  /// \par breaks lines, \'e9 and \u233 are characters.
  static String rtfText(String rtf) {
    final out = StringBuffer();
    var depth = 0;
    // The depths of the groups being left out, and \uc's per group.
    final skipped = <int>[];
    final ucStack = <int>[1];
    var skipChars = 0;
    var i = 0;
    void emit(String s) {
      if (skipChars > 0) {
        skipChars--;
        return;
      }
      if (skipped.isEmpty) out.write(s);
    }

    while (i < rtf.length) {
      final c = rtf.codeUnitAt(i);
      if (c == 0x7B) {
        // {
        depth++;
        ucStack.add(ucStack.last);
        skipChars = 0;
        i++;
      } else if (c == 0x7D) {
        // }
        if (skipped.isNotEmpty && skipped.last == depth) skipped.removeLast();
        depth--;
        if (ucStack.length > 1) ucStack.removeLast();
        skipChars = 0;
        i++;
      } else if (c == 0x5C) {
        // \
        if (i + 1 >= rtf.length) break;
        final next = rtf[i + 1];
        if (next == '\\' || next == '{' || next == '}') {
          emit(next);
          i += 2;
        } else if (next == "'") {
          final code = int.tryParse(rtf.substring(i + 2, i + 4 <= rtf.length ? i + 4 : rtf.length), radix: 16);
          if (code != null) emit(_byte(code));
          i += 4;
        } else if (next == '*') {
          if (skipped.isEmpty || skipped.last != depth) skipped.add(depth);
          i += 2;
        } else if (next == '~') {
          emit(' ');
          i += 2;
        } else if (next == '_') {
          emit('-');
          i += 2;
        } else if (RegExp(r'[a-zA-Z]').hasMatch(next)) {
          var j = i + 1;
          while (j < rtf.length && _isLetter(rtf.codeUnitAt(j))) {
            j++;
          }
          final word = rtf.substring(i + 1, j).toLowerCase();
          var k = j;
          if (k < rtf.length && (rtf[k] == '-' || _isDigit(rtf.codeUnitAt(k)))) {
            k++;
            while (k < rtf.length && _isDigit(rtf.codeUnitAt(k))) {
              k++;
            }
          }
          final param = k > j ? int.tryParse(rtf.substring(j, k)) : null;
          if (k < rtf.length && rtf[k] == ' ') k++;
          i = k;
          switch (word) {
            case 'par' || 'line' || 'sect' || 'row' || 'page':
              if (skipped.isEmpty) out.write('\n');
            case 'tab' || 'cell':
              if (skipped.isEmpty) out.write(word == 'tab' ? '\t' : ' ');
            case 'u':
              if (param != null) {
                skipChars = 0;
                emit(String.fromCharCode(param < 0 ? param + 65536 : param));
                skipChars = ucStack.last;
              }
            case 'uc':
              ucStack[ucStack.length - 1] = param ?? 1;
            case 'emdash':
              emit('—');
            case 'endash':
              emit('–');
            case 'lquote':
              emit('‘');
            case 'rquote':
              emit('’');
            case 'ldblquote':
              emit('“');
            case 'rdblquote':
              emit('”');
            case 'bullet':
              emit('•');
            default:
              if (_skippedGroups.contains(word) && (skipped.isEmpty || skipped.last != depth)) {
                skipped.add(depth);
              }
          }
        } else {
          // Other control symbols (\-, \|, \:...) aren't text.
          i += 2;
        }
      } else if (c == 0x0D || c == 0x0A) {
        i++;
      } else {
        emit(rtf[i]);
        i++;
      }
    }
    return out.toString();
  }

  static bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
}
