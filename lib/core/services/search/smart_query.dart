// Smart search: what a query in plain words asks for ("photos from last
// week", "pdf bigger than 10 MB", "receipts from March"), worked out on the
// device with plain rules: a word list and a few patterns. There is no model
// and nothing goes over the network.

import 'package:folders/core/files/file_types.dart';
import 'package:path/path.dart' as p;

/// A kind of file a query can ask for.
enum SearchKind {
  photos('Photos'),
  videos('Videos'),
  music('Music'),
  documents('Documents'),
  pdf('PDFs'),
  spreadsheets('Spreadsheets'),
  presentations('Presentations'),
  archives('Archives'),
  apps('Apps'),
  ebooks('E-books'),
  code('Code');

  const SearchKind(this.label);

  final String label;

  static const _photos = {FileKind.image, FileKind.rasterImage, FileKind.cameraRaw};
  static const _sheets = {
    FileKind.spreadsheet,
    FileKind.legacySpreadsheet,
    FileKind.openDocumentSpreadsheet,
    FileKind.delimited,
  };
  static const _slides = {
    FileKind.presentation,
    FileKind.legacyPresentation,
    FileKind.openDocumentPresentation,
  };
  static const _documents = {
    FileKind.word,
    FileKind.legacyWord,
    FileKind.richText,
    FileKind.openDocumentText,
    FileKind.pdf,
    FileKind.text,
    FileKind.markdown,
    ..._sheets,
    ..._slides,
  };

  /// Whether a file at [path] is of this kind, going by its name.
  bool matches(String path) {
    final kind = FileTypes.kindOf(path);
    return switch (this) {
      photos => _photos.contains(kind),
      videos => kind == FileKind.video,
      music => kind == FileKind.audio,
      documents => _documents.contains(kind),
      pdf => kind == FileKind.pdf,
      spreadsheets => _sheets.contains(kind),
      presentations => _slides.contains(kind),
      archives => kind == FileKind.archive || kind == FileKind.diskImage,
      apps => kind == FileKind.package || const {'xapk', 'apks', 'aab'}.contains(FileTypes.extensionOf(path)),
      ebooks => kind == FileKind.epub || kind == FileKind.ebook || kind == FileKind.comic,
      code => kind == FileKind.code || kind == FileKind.json || kind == FileKind.html,
    };
  }
}

/// A place a query can name: a usual folder, or what an app saved.
enum SearchPlace {
  downloads('In Downloads', {'download', 'downloads'}),
  screenshots('Screenshots', {'screenshots', 'screenshot', 'screen shots'}),
  camera('From the camera', {'camera', 'camera roll', 'dcim'}),
  whatsapp('From WhatsApp', {'whatsapp'}, prefix: true),
  telegram('From Telegram', {'telegram'}, prefix: true),
  instagram('From Instagram', {'instagram'}, prefix: true),
  twitter('From Twitter', {'twitter'}, prefix: true);

  const SearchPlace(this.label, this.folderNames, {this.prefix = false});

  final String label;

  /// Folder names that mean this place anywhere in a path, in lower case.
  final Set<String> folderNames;

  /// Also folders whose names start with one of [folderNames] ("WhatsApp
  /// Images", "Telegram Desktop", "com.whatsapp").
  final bool prefix;

  bool _isFolder(String name) {
    if (folderNames.contains(name)) return true;
    if (!prefix) return false;
    for (final known in folderNames) {
      if (name.startsWith('$known ') || name.endsWith('.$known') || name.contains('.$known.')) return true;
    }
    return false;
  }

  /// Whether [path] is in one of [folders] (this place's folders on this
  /// device), or in a folder named for it, or (screenshots) named as one.
  bool holds(String path, {Iterable<String> folders = const []}) {
    for (final folder in folders) {
      if (p.isWithin(folder, path)) return true;
    }
    final parts = path.split(RegExp(r'[\\/]'));
    for (var i = 0; i < parts.length - 1; i++) {
      if (_isFolder(parts[i].toLowerCase())) return true;
    }
    if (this == screenshots) {
      final name = parts.last.toLowerCase();
      return name.startsWith('screenshot') || name.startsWith('screen shot') || name.startsWith('screen_shot');
    }
    return false;
  }
}

/// When a file was last changed: from (included) to (not included); either
/// end may be open.
class DateSpan {
  const DateSpan(this.from, this.to, this.label);

  final DateTime? from;
  final DateTime? to;
  final String label;

  bool contains(DateTime time) =>
      (from == null || !time.isBefore(from!)) && (to == null || time.isBefore(to!));

  @override
  String toString() => 'DateSpan($from, $to, $label)';
}

/// A file's size in bytes, both ends included; either may be open.
class SizeSpan {
  const SizeSpan(this.min, this.max, this.label);

  final int? min;
  final int? max;
  final String label;

  bool contains(int size) => (min == null || size >= min!) && (max == null || size <= max!);

  @override
  String toString() => 'SizeSpan($min, $max, $label)';
}

enum QueryChipType { kind, extension, date, size, place, words }

/// One thing understood in a query, shown as a chip under the search box;
/// removing it takes its [tokens] out of the query.
class QueryChip {
  const QueryChip(this.type, this.label, this.tokens);

  final QueryChipType type;
  final String label;

  /// Which of [SmartQuery.tokens] it came from.
  final List<int> tokens;

  @override
  bool operator ==(Object other) =>
      other is QueryChip && other.type == type && other.label == label && _sameList(other.tokens, tokens);

  @override
  int get hashCode => Object.hash(type, label, Object.hashAll(tokens));

  @override
  String toString() => 'QueryChip($type, $label, $tokens)';
}

bool _sameList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What a search query asks for, in plain words: kinds of file, dates,
/// sizes, places, and the words left over, which are looked for in names
/// (and, when asked, inside files and in the text of photos).
class SmartQuery {
  const SmartQuery({
    required this.text,
    required this.tokens,
    this.kinds = const {},
    this.extensions = const {},
    this.dates = const [],
    this.sizes = const [],
    this.places = const {},
    this.words = const [],
    this.chips = const [],
  });

  /// The query as typed.
  final String text;

  /// Its parts as typed, split at spaces ("quoted words" stay one part).
  final List<String> tokens;

  /// Kinds and file types asked for: a file of any of them will do.
  final Set<SearchKind> kinds;
  final Set<String> extensions;

  /// All of them must hold.
  final List<DateSpan> dates;
  final List<SizeSpan> sizes;

  /// Any of them will do.
  final Set<SearchPlace> places;

  /// What's left, in lower case: every one must be found.
  final List<String> words;

  /// What was understood, in the order typed.
  final List<QueryChip> chips;

  /// Whether anything besides words was understood.
  bool get hasFilters =>
      kinds.isNotEmpty || extensions.isNotEmpty || dates.isNotEmpty || sizes.isNotEmpty || places.isNotEmpty;

  /// The query with [chip]'s words taken out, and the little words that led
  /// to them ("of" in "photos of receipts").
  String without(QueryChip chip) {
    final drop = chip.tokens.toSet();
    final used = <int>{for (final c in chips) ...c.tokens};
    for (final index in chip.tokens) {
      for (var i = index - 1; i >= 0 && !used.contains(i) && !drop.contains(i); i--) {
        if (!_stopWords.contains(_plain(tokens[i]))) break;
        drop.add(i);
      }
    }
    return [
      for (var i = 0; i < tokens.length; i++)
        if (!drop.contains(i)) tokens[i],
    ].join(' ');
  }

  static final _tokenPattern = RegExp(r'"[^"]*"?|\S+');

  /// Works out what [text] asks for; [now] is for the tests' fixed clock.
  /// A pattern with * or ? is a pattern for names, not words.
  static SmartQuery parse(String text, {DateTime? now}) {
    final tokens = [for (final m in _tokenPattern.allMatches(text)) m.group(0)!];
    if (text.contains('*') || text.contains('?')) {
      return SmartQuery(text: text, tokens: tokens);
    }
    return _Parser(tokens, now ?? DateTime.now()).run(text);
  }

  /// [token] in lower case without the punctuation around it.
  static String plain(String token) => _plain(token);

  /// Words that only join the others ("from", "the", "files"…).
  static bool isStopWord(String word) => _stopWords.contains(word);

  @override
  String toString() =>
      'SmartQuery(kinds: $kinds, ext: $extensions, dates: $dates, sizes: $sizes, places: $places, words: $words)';
}

String _plain(String token) {
  var t = token.toLowerCase();
  t = t.replaceAll(RegExp(r'^[(\[{"' "'" r']+|[)\]}"' "'" r',.;:!]+$'), '');
  return t;
}

const _stopWords = {
  'a', 'an', 'the', 'and', 'or', 'of', 'in', 'on', 'at', 'from', 'with', 'for', 'to', 'by',
  'during', 'than', 'that', 'which', 'were', 'was', 'are', 'is', 'my', 'me', 'all', 'any',
  'some', 'show', 'find', 'search', 'files', 'file', 'items', 'item', 'stuff', 'please',
  'taken', 'made', 'modified', 'changed', 'edited', 'created', 'saved', 'sent', 'received',
  'shot', 'containing', 'contains', 'about', 'named', 'called', 'where', 'whose', 'having',
};

/// Words before a date or place that belong to it.
const _prepositions = {'in', 'from', 'during', 'on', 'of', 'at', 'within', 'for'};

const _months = [
  'january', 'february', 'march', 'april', 'may', 'june', 'july', 'august', 'september',
  'october', 'november', 'december',
];

/// Short month names, and "may": words of their own too, so they're months
/// only after "in", "from"… or before a year.
const _shortMonths = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'sept': 9,
  'oct': 10, 'nov': 11, 'dec': 12,
};

const _kindWords = {
  'photo': SearchKind.photos, 'photos': SearchKind.photos, 'picture': SearchKind.photos,
  'pictures': SearchKind.photos, 'pic': SearchKind.photos, 'pics': SearchKind.photos,
  'image': SearchKind.photos, 'images': SearchKind.photos, 'selfie': SearchKind.photos,
  'selfies': SearchKind.photos,
  'video': SearchKind.videos, 'videos': SearchKind.videos, 'movie': SearchKind.videos,
  'movies': SearchKind.videos, 'film': SearchKind.videos, 'films': SearchKind.videos,
  'clip': SearchKind.videos, 'clips': SearchKind.videos,
  'music': SearchKind.music, 'audio': SearchKind.music, 'song': SearchKind.music,
  'songs': SearchKind.music, 'track': SearchKind.music, 'tracks': SearchKind.music,
  'podcast': SearchKind.music, 'podcasts': SearchKind.music,
  'document': SearchKind.documents, 'documents': SearchKind.documents, 'doc': SearchKind.documents,
  'docs': SearchKind.documents,
  'pdf': SearchKind.pdf, 'pdfs': SearchKind.pdf,
  'spreadsheet': SearchKind.spreadsheets, 'spreadsheets': SearchKind.spreadsheets,
  'sheet': SearchKind.spreadsheets, 'sheets': SearchKind.spreadsheets,
  'excel': SearchKind.spreadsheets, 'workbook': SearchKind.spreadsheets,
  'workbooks': SearchKind.spreadsheets,
  'presentation': SearchKind.presentations, 'presentations': SearchKind.presentations,
  'slides': SearchKind.presentations, 'slideshow': SearchKind.presentations,
  'slideshows': SearchKind.presentations, 'powerpoint': SearchKind.presentations,
  'deck': SearchKind.presentations, 'decks': SearchKind.presentations,
  'archive': SearchKind.archives, 'archives': SearchKind.archives, 'zip': SearchKind.archives,
  'zips': SearchKind.archives, 'zipped': SearchKind.archives, 'compressed': SearchKind.archives,
  'apk': SearchKind.apps, 'apks': SearchKind.apps, 'app': SearchKind.apps, 'apps': SearchKind.apps,
  'installer': SearchKind.apps, 'installers': SearchKind.apps,
  'ebook': SearchKind.ebooks, 'ebooks': SearchKind.ebooks, 'e-book': SearchKind.ebooks,
  'e-books': SearchKind.ebooks, 'book': SearchKind.ebooks, 'books': SearchKind.ebooks,
  'epub': SearchKind.ebooks, 'epubs': SearchKind.ebooks,
  'code': SearchKind.code, 'source': SearchKind.code, 'script': SearchKind.code,
  'scripts': SearchKind.code,
};

/// File types that can be asked for by name ("mp3", ".docx").
const _extensionWords = {
  'mp3', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'aac', 'mp4', 'mkv', 'avi', 'mov', 'webm',
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', 'tiff', 'svg', 'dng',
  'psd', 'docx', 'xlsx', 'pptx', 'xls', 'ppt', 'odt', 'ods', 'odp', 'rtf', 'txt', 'csv',
  'json', 'xml', 'html', 'md', 'mobi', 'rar', '7z', 'tar', 'gz', 'iso', 'exe', 'msi', 'dmg',
  'deb', 'rpm',
};

const _placeWords = {
  'download': SearchPlace.downloads, 'downloads': SearchPlace.downloads,
  'downloaded': SearchPlace.downloads,
  'screenshot': SearchPlace.screenshots, 'screenshots': SearchPlace.screenshots,
  'screen-shots': SearchPlace.screenshots,
  'camera': SearchPlace.camera, 'dcim': SearchPlace.camera,
  'whatsapp': SearchPlace.whatsapp, 'telegram': SearchPlace.telegram,
  'instagram': SearchPlace.instagram, 'twitter': SearchPlace.twitter,
};

const _kb = 1024;

const _units = {
  'b': 1, 'byte': 1, 'bytes': 1,
  'k': _kb, 'kb': _kb, 'kib': _kb, 'kilobyte': _kb, 'kilobytes': _kb,
  'm': _kb * _kb, 'mb': _kb * _kb, 'mib': _kb * _kb, 'meg': _kb * _kb, 'megs': _kb * _kb,
  'megabyte': _kb * _kb, 'megabytes': _kb * _kb,
  'g': _kb * _kb * _kb, 'gb': _kb * _kb * _kb, 'gib': _kb * _kb * _kb, 'gig': _kb * _kb * _kb,
  'gigs': _kb * _kb * _kb, 'gigabyte': _kb * _kb * _kb, 'gigabytes': _kb * _kb * _kb,
  't': _kb * _kb * _kb * _kb, 'tb': _kb * _kb * _kb * _kb, 'tib': _kb * _kb * _kb * _kb,
  'terabyte': _kb * _kb * _kb * _kb, 'terabytes': _kb * _kb * _kb * _kb,
};

const _overWords = {'over', 'above', 'bigger', 'larger', 'greater', 'more', 'heavier', 'exceeding'};
const _underWords = {'under', 'below', 'smaller', 'less', 'lighter'};

enum _Compare { over, under, atLeast, atMost }

/// What a run of tokens was understood as.
class _Found {
  _Found(this.end, this.type, this.label, {this.kind, this.extension, this.date, this.size, this.place});

  /// The token after it.
  final int end;
  final QueryChipType type;
  final String label;
  final SearchKind? kind;
  final String? extension;
  final DateSpan? date;
  final SizeSpan? size;
  final SearchPlace? place;
}

class _Parser {
  _Parser(this.tokens, this.now) : words = [for (final t in tokens) _plain(t)];

  final List<String> tokens;

  /// [tokens] in lower case, without punctuation around them.
  final List<String> words;
  final DateTime now;

  int get length => tokens.length;

  String at(int i) => i >= 0 && i < length ? words[i] : '';

  bool quoted(int i) => tokens[i].startsWith('"');

  SmartQuery run(String text) {
    final used = List<bool>.filled(length, false);
    final chips = <QueryChip>[];
    final kinds = <SearchKind>{};
    final extensions = <String>{};
    final dates = <DateSpan>[];
    final sizes = <SizeSpan>[];
    final places = <SearchPlace>{};
    var i = 0;
    while (i < length) {
      if (quoted(i)) {
        i++;
        continue;
      }
      var start = i;
      var found = _size(i) ?? _date(i) ?? _place(i) ?? _kind(i);
      // "in March", "from WhatsApp": the little word goes with it.
      if (found == null && _prepositions.contains(at(i)) && i + 1 < length && !quoted(i + 1)) {
        found = _date(i + 1, afterWord: true) ?? _place(i + 1);
        if (found != null) start = i;
      }
      if (found == null) {
        i++;
        continue;
      }
      for (var j = start; j < found.end; j++) {
        used[j] = true;
      }
      chips.add(QueryChip(found.type, found.label, [for (var j = start; j < found.end; j++) j]));
      switch (found.type) {
        case QueryChipType.kind:
          kinds.add(found.kind!);
        case QueryChipType.extension:
          extensions.add(found.extension!);
        case QueryChipType.date:
          dates.add(found.date!);
        case QueryChipType.size:
          sizes.add(found.size!);
        case QueryChipType.place:
          places.add(found.place!);
        case QueryChipType.words:
          break;
      }
      i = found.end;
    }
    final left = <int>[
      for (var j = 0; j < length; j++)
        if (!used[j] && (quoted(j) || (words[j].isNotEmpty && !_stopWords.contains(words[j])))) j,
    ];
    final leftWords = [
      for (final j in left)
        if (quoted(j)) tokens[j].replaceAll('"', '').trim().toLowerCase() else words[j],
    ]..removeWhere((w) => w.isEmpty);
    if (leftWords.isNotEmpty) {
      // After the others, so they keep the order typed.
      chips.add(QueryChip(QueryChipType.words, leftWords.join(' '), left));
    }
    return SmartQuery(
      text: text,
      tokens: tokens,
      kinds: kinds,
      extensions: extensions,
      dates: dates,
      sizes: sizes,
      places: places,
      words: leftWords,
      chips: chips,
    );
  }

  // Kinds and file types.

  _Found? _kind(int i) {
    final word = at(i);
    if (word == 'source' && at(i + 1) == 'code') {
      return _Found(i + 2, QueryChipType.kind, SearchKind.code.label, kind: SearchKind.code);
    }
    final kind = _kindWords[word];
    if (kind != null) return _Found(i + 1, QueryChipType.kind, kind.label, kind: kind);
    final ext = word.startsWith('.') ? word.substring(1) : word;
    if (_extensionWords.contains(ext)) {
      return _Found(i + 1, QueryChipType.extension, ext.toUpperCase(), extension: ext);
    }
    return null;
  }

  // Places.

  _Found? _place(int i) {
    final word = at(i);
    if (word == 'camera' && at(i + 1) == 'roll') {
      return _Found(i + 2, QueryChipType.place, SearchPlace.camera.label, place: SearchPlace.camera);
    }
    final place = _placeWords[word];
    if (place == null) return null;
    return _Found(i + 1, QueryChipType.place, place.label, place: place);
  }

  // Sizes.

  /// "10mb", "10 MB", "1,5 GB": bytes, its label and the token after it.
  (int, String, int)? _amount(int i, {String? first}) {
    final token = first ?? at(i);
    final match = RegExp(r'^(\d+(?:[.,]\d+)*)([a-z]*)$').firstMatch(token);
    if (match == null) return null;
    final number = _number(match.group(1)!);
    if (number == null) return null;
    var unitWord = match.group(2)!;
    var end = i + 1;
    if (unitWord.isEmpty) {
      unitWord = at(i + 1);
      end = i + 2;
    }
    final unit = _units[unitWord];
    if (unit == null) return null;
    return ((number * unit).round(), _sizeLabel(number, unit), end);
  }

  _Found? _size(int i) {
    final word = at(i);
    switch (word) {
      case 'large' || 'big' || 'largest' || 'biggest':
        return _sizeFound(i + 1, 128 * _kb * _kb + 1, null, 'Large (over 128 MB)');
      case 'huge' || 'gigantic':
        return _sizeFound(i + 1, _kb * _kb * _kb + 1, null, 'Huge (over 1 GB)');
      case 'small' || 'smallest':
        return _sizeFound(i + 1, null, _kb * _kb - 1, 'Small (under 1 MB)');
      case 'tiny':
        return _sizeFound(i + 1, null, 16 * _kb - 1, 'Tiny (under 16 KB)');
      case 'empty':
        return _sizeFound(i + 1, null, 0, 'Empty');
      case 'between':
        final low = RegExp(r'^\d+(?:[.,]\d+)*$').hasMatch(at(i + 1)) ? _number(at(i + 1)) : null;
        if (low == null || (at(i + 2) != 'and' && at(i + 2) != '-' && at(i + 2) != 'to')) return null;
        final high = _amount(i + 3);
        if (high == null) return null;
        // The unit given once, after the second number.
        final unit = _units[RegExp(r'[a-z]+$').firstMatch(at(i + 3))?.group(0) ?? at(i + 4)] ?? 1;
        final lowBytes = (low * unit).round();
        return _sizeFound(high.$3, lowBytes, high.$1, '${_trim(low)}–${high.$2}');
    }
    _Compare? compare;
    var j = i;
    String? attached;
    if (_overWords.contains(word)) {
      compare = _Compare.over;
      j++;
    } else if (_underWords.contains(word)) {
      compare = _Compare.under;
      j++;
    } else if (word == 'at' && at(i + 1) == 'least') {
      compare = _Compare.atLeast;
      j += 2;
    } else if ((word == 'at' && at(i + 1) == 'most') || (word == 'up' && at(i + 1) == 'to')) {
      compare = _Compare.atMost;
      j += 2;
    } else {
      final symbol = RegExp(r'^(>=|<=|>|<)(.*)$').firstMatch(tokens[i].toLowerCase());
      if (symbol == null) return null;
      compare = switch (symbol.group(1)) {
        '>=' => _Compare.atLeast,
        '<=' => _Compare.atMost,
        '>' => _Compare.over,
        _ => _Compare.under,
      };
      final rest = symbol.group(2)!;
      if (rest.isEmpty) {
        j++;
      } else {
        attached = rest;
      }
    }
    if (attached == null && at(j) == 'than') j++;
    final amount = attached != null ? _amount(i, first: attached) : _amount(j);
    if (amount == null) return null;
    final (bytes, label, end) = amount;
    return switch (compare) {
      _Compare.over => _sizeFound(end, bytes + 1, null, 'Over $label'),
      _Compare.under => _sizeFound(end, null, bytes - 1, 'Under $label'),
      _Compare.atLeast => _sizeFound(end, bytes, null, '$label or more'),
      _Compare.atMost => _sizeFound(end, null, bytes, 'Up to $label'),
    };
  }

  _Found _sizeFound(int end, int? min, int? max, String label) =>
      _Found(end, QueryChipType.size, label, size: SizeSpan(min, max, label));

  /// "1,5" is 1.5 and "1,500" is 1500; "1.5" is 1.5 and "1.234.567" is
  /// 1234567; with both, the last one is the decimal point.
  static double? _number(String text) {
    final comma = text.lastIndexOf(',');
    final dot = text.lastIndexOf('.');
    String normal;
    if (comma >= 0 && dot >= 0) {
      normal = comma > dot
          ? text.replaceAll('.', '').replaceAll(',', '.')
          : text.replaceAll(',', '');
    } else if (comma >= 0) {
      final groups = text.split(',');
      final thousands = groups.skip(1).every((g) => g.length == 3);
      normal = thousands ? groups.join() : (groups.length == 2 ? groups.join('.') : '');
    } else if (dot >= 0) {
      final groups = text.split('.');
      normal = groups.length == 2 ? text : (groups.skip(1).every((g) => g.length == 3) ? groups.join() : '');
    } else {
      normal = text;
    }
    return double.tryParse(normal);
  }

  static String _trim(double number) {
    final fixed = number == number.roundToDouble() ? number.round().toString() : number.toString();
    return fixed;
  }

  static String _sizeLabel(double number, int unit) {
    final name = switch (unit) {
      1 => 'bytes',
      _kb => 'KB',
      const (_kb * _kb) => 'MB',
      const (_kb * _kb * _kb) => 'GB',
      _ => 'TB',
    };
    return '${_trim(number)} $name';
  }

  // Dates.

  DateTime get _today => DateTime(now.year, now.month, now.day);

  /// Monday of this week.
  DateTime get _weekStart => _today.subtract(Duration(days: _today.weekday - 1));

  static String _monthName(int month) => _months[month - 1][0].toUpperCase() + _months[month - 1].substring(1);

  static String _day(DateTime d) => '${d.day} ${_monthName(d.month)} ${d.year}';

  DateTime _addMonths(DateTime d, int months) {
    final index = d.year * 12 + d.month - 1 + months;
    return DateTime(index ~/ 12, index % 12 + 1, d.day);
  }

  _Found _dateFound(int end, DateTime? from, DateTime? to, String label) =>
      _Found(end, QueryChipType.date, label, date: DateSpan(from, to, label));

  bool _isYear(String word) {
    if (!RegExp(r'^\d{4}$').hasMatch(word)) return false;
    final year = int.parse(word);
    return year >= 1970 && year <= now.year + 1;
  }

  /// A date phrase starting at [i]: one point in time, or "before", "after",
  /// "since", "until" one. [afterWord]: it follows "in", "from"…, so "may"
  /// and short month names count as months.
  _Found? _date(int i, {bool afterWord = false}) {
    final word = at(i);
    switch (word) {
      case 'before' || 'until' || 'till' || 'after' || 'since':
        final point = _datePoint(i + 1, afterWord: true);
        if (point == null) return null;
        final span = point.date!;
        return switch (word) {
          'before' => _dateFound(point.end, null, span.from, 'Before ${_lowerFirst(span.label)}'),
          'until' || 'till' => _dateFound(point.end, null, span.to, 'Until ${_lowerFirst(span.label)}'),
          'after' => _dateFound(point.end, span.to, null, 'After ${_lowerFirst(span.label)}'),
          _ => _dateFound(point.end, span.from, null, 'Since ${_lowerFirst(span.label)}'),
        };
      case 'older' || 'newer':
        // "older than 2 years", "newer than 30 days".
        if (at(i + 1) != 'than') return null;
        final ago = _duration(i + 2);
        if (ago == null) return null;
        final (time, label, end) = ago;
        return word == 'older'
            ? _dateFound(end, null, time, 'Older than $label')
            : _dateFound(end, time, null, 'Newer than $label');
    }
    return _datePoint(i, afterWord: afterWord);
  }

  /// "2 years", "30 days": that long before now, its label and the token
  /// after it.
  (DateTime, String, int)? _duration(int i) {
    final count = int.tryParse(at(i));
    if (count == null || count <= 0 || count > 1000) return null;
    final unit = at(i + 1);
    final singular = unit.endsWith('s') ? unit.substring(0, unit.length - 1) : unit;
    final DateTime when;
    switch (singular) {
      case 'day':
        when = _today.subtract(Duration(days: count));
      case 'week':
        when = _today.subtract(Duration(days: 7 * count));
      case 'month':
        when = _addMonths(_today, -count);
      case 'year':
        when = DateTime(_today.year - count, _today.month, _today.day);
      default:
        return null;
    }
    return (when, '$count ${count == 1 ? singular : '${singular}s'}', i + 2);
  }

  static String _lowerFirst(String label) {
    // "Before March 2026", "Since last week": month names keep their capital.
    final first = label.split(' ').first;
    if (_months.contains(first.toLowerCase()) || RegExp(r'^\d').hasMatch(first)) return label;
    return label[0].toLowerCase() + label.substring(1);
  }

  _Found? _datePoint(int i, {bool afterWord = false}) {
    final word = at(i);
    final next = at(i + 1);
    switch (word) {
      case 'today':
        return _dateFound(i + 1, _today, _today.add(const Duration(days: 1)), 'Today');
      case 'yesterday':
        return _dateFound(i + 1, _today.subtract(const Duration(days: 1)), _today, 'Yesterday');
      case 'recent' || 'recently' || 'lately':
        return _dateFound(i + 1, _today.subtract(const Duration(days: 6)), _today.add(const Duration(days: 1)),
            'Last 7 days');
      case 'this' || 'current':
        return switch (next) {
          'week' => _dateFound(i + 2, _weekStart, _weekStart.add(const Duration(days: 7)), 'This week'),
          'month' => _dateFound(
              i + 2, DateTime(now.year, now.month), DateTime(now.year, now.month + 1), 'This month'),
          'year' => _dateFound(i + 2, DateTime(now.year), DateTime(now.year + 1), 'This year'),
          _ => null,
        };
      case 'last' || 'past' || 'previous':
        switch (next) {
          case 'week':
            final start = _weekStart.subtract(const Duration(days: 7));
            return _dateFound(i + 2, start, _weekStart, 'Last week');
          case 'month':
            return _dateFound(
                i + 2, DateTime(now.year, now.month - 1), DateTime(now.year, now.month), 'Last month');
          case 'year':
            return _dateFound(i + 2, DateTime(now.year - 1), DateTime(now.year), 'Last year');
        }
        // "last 30 days", "past 2 weeks".
        final count = int.tryParse(next);
        if (count == null || count <= 0 || count > 1000) return null;
        final unit = at(i + 2);
        final singular = unit.endsWith('s') ? unit.substring(0, unit.length - 1) : unit;
        final tomorrow = _today.add(const Duration(days: 1));
        final from = switch (singular) {
          'day' => _today.subtract(Duration(days: count - 1)),
          'week' => _today.subtract(Duration(days: 7 * count - 1)),
          'month' => _addMonths(tomorrow, -count),
          'year' => DateTime(tomorrow.year - count, tomorrow.month, tomorrow.day),
          _ => null,
        };
        if (from == null) return null;
        return _dateFound(i + 3, from, tomorrow, 'Last $count ${count == 1 ? singular : '${singular}s'}');
    }
    // "3 days ago", "2 weeks ago".
    if (at(i + 2) == 'ago') {
      final ago = _duration(i);
      if (ago != null) {
        final (time, label, _) = ago;
        final unit = at(i + 1);
        final DateTime from;
        final DateTime to;
        if (unit.startsWith('week')) {
          from = time.subtract(Duration(days: time.weekday - 1));
          to = from.add(const Duration(days: 7));
        } else if (unit.startsWith('month')) {
          from = DateTime(time.year, time.month);
          to = DateTime(time.year, time.month + 1);
        } else if (unit.startsWith('year')) {
          from = DateTime(time.year);
          to = DateTime(time.year + 1);
        } else {
          from = time;
          to = time.add(const Duration(days: 1));
        }
        return _dateFound(i + 3, from, to, '$label ago'[0].toUpperCase() + '$label ago'.substring(1));
      }
    }
    // 2025-03-14 and 2025-03.
    final iso = RegExp(r'^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$').firstMatch(word);
    if (iso != null) {
      final year = int.parse(iso.group(1)!);
      final month = int.parse(iso.group(2)!);
      final day = iso.group(3) == null ? null : int.parse(iso.group(3)!);
      if (month < 1 || month > 12 || year < 1970 || (day != null && (day < 1 || day > 31))) return null;
      if (day == null) {
        return _dateFound(i + 1, DateTime(year, month), DateTime(year, month + 1), '${_monthName(month)} $year');
      }
      final from = DateTime(year, month, day);
      return _dateFound(i + 1, from, from.add(const Duration(days: 1)), _day(from));
    }
    // A month, with or without its year.
    final full = _months.indexOf(word);
    final short = _shortMonths[word];
    final month = full >= 0 && word != 'may' ? full + 1 : null;
    final shy = word == 'may' ? 5 : short;
    if (month != null || (shy != null && (afterWord || _isYear(next)))) {
      final m = month ?? shy!;
      if (_isYear(next)) {
        final year = int.parse(next);
        return _dateFound(i + 2, DateTime(year, m), DateTime(year, m + 1), '${_monthName(m)} $year');
      }
      // The last one that has begun: in November, "December" is last year's.
      final year = m > now.month ? now.year - 1 : now.year;
      return _dateFound(i + 1, DateTime(year, m), DateTime(year, m + 1), '${_monthName(m)} $year');
    }
    if (_isYear(word)) {
      final year = int.parse(word);
      return _dateFound(i + 1, DateTime(year), DateTime(year + 1), '$year');
    }
    return null;
  }
}
