import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/search/smart_query.dart';
import 'package:folders/features/file_explorere/bloc/folder_search.dart' show NameMatcher;
import 'package:path/path.dart' as p;

/// A few lines of a file's text around the words searched for, and where
/// they are in it.
class SearchSnippet {
  const SearchSnippet(this.text, this.highlights);

  final String text;

  /// Start and end of each match in [text], in order, not overlapping.
  final List<(int, int)> highlights;

  /// [words] in context in [source] (any case), or null if none is there.
  static SearchSnippet? find(String source, List<String> words, {int before = 40, int after = 100, String? lower}) {
    if (words.isEmpty) return null;
    lower ??= source.toLowerCase();
    // Lower case can change a string's length (İ): then show it lower-cased.
    final text = lower.length == source.length ? source : lower;
    var first = -1;
    for (final word in words) {
      final at = lower.indexOf(word);
      if (at >= 0 && (first < 0 || at < first)) first = at;
    }
    if (first < 0) return null;
    var start = first - before < 0 ? 0 : first - before;
    var end = first + after > text.length ? text.length : first + after;
    final space = RegExp(r'\s');
    if (start > 0) {
      final at = text.indexOf(space, start);
      if (at >= 0 && at < first) start = at + 1;
    }
    if (end < text.length) {
      final at = text.lastIndexOf(space, end);
      if (at > first) end = at;
    }
    final body = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    final shown = '${start > 0 ? '…' : ''}$body${end < text.length ? '…' : ''}';
    return SearchSnippet(shown, highlightsIn(shown, words));
  }

  /// Where [words] are in [text], merged where they overlap.
  static List<(int, int)> highlightsIn(String text, List<String> words) {
    final lower = text.toLowerCase();
    if (lower.length != text.length) return const [];
    final ranges = <(int, int)>[];
    for (final word in words) {
      if (word.isEmpty) continue;
      for (var at = lower.indexOf(word); at >= 0; at = lower.indexOf(word, at + word.length)) {
        ranges.add((at, at + word.length));
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final range in ranges) {
      if (merged.isNotEmpty && range.$1 <= merged.last.$2) {
        final last = merged.removeLast();
        merged.add((last.$1, range.$2 > last.$2 ? range.$2 : last.$2));
      } else {
        merged.add(range);
      }
    }
    return merged;
  }

  @override
  String toString() => 'SearchSnippet($text, $highlights)';
}

/// What a search looks for, and whether a file or folder is it. Plain data
/// and plain Dart: the search's isolate builds one from the same query.
class SearchCriteria {
  SearchCriteria(
    this.query, {
    this.smart,
    this.insideFiles = false,
    this.photoText = false,
    this.placeFolders = const {},
  })  : _name = NameMatcher(query),
        _literalWords = smart == null ? const [] : _literalWordsOf(smart),
        words = smart != null
            ? [for (final w in smart.words) stem(w)]
            : (insideFiles && !_isPattern(query) && query.trim().isNotEmpty ? [query.trim().toLowerCase()] : const []);

  /// What was typed.
  final String query;

  /// What it asks for in plain words; null with Smart search off.
  final SmartQuery? smart;

  /// Whether the words are also looked for in files' text...
  final bool insideFiles;

  /// ...and photos' (through the index).
  final bool photoText;

  /// Each place's folders on this device.
  final Map<SearchPlace, List<String>> placeFolders;

  final NameMatcher _name;

  /// Every word typed but the little ones: a name with all of them matches
  /// whatever else was understood ("march" still finds march-report.pdf).
  final List<String> _literalWords;

  /// What must be found in a name or a text, in lower case: the words left
  /// over (shortened, so "receipts" finds "receipt"), or with Smart search
  /// off the whole query.
  final List<String> words;

  static bool _isPattern(String query) => query.contains('*') || query.contains('?');

  static List<String> _literalWordsOf(SmartQuery smart) {
    final all = <String>[
      for (final token in smart.tokens)
        if (token.startsWith('"')) token.replaceAll('"', '').trim().toLowerCase() else SmartQuery.plain(token),
    ]..removeWhere((w) => w.isEmpty);
    final meaningful = [for (final w in all) if (!SmartQuery.isStopWord(w)) stem(w)];
    return meaningful;
  }

  /// [word] without a plural s ("receipts" → "receipt", but "glass" stays).
  static String stem(String word) {
    if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss') && !word.contains(' ')) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  /// Whether a name matches what was typed, as plain text: anywhere in it, a
  /// * ? pattern, or (Smart search) every word somewhere in it.
  bool literal(String name) {
    if (_name.matches(name)) return true;
    if (_literalWords.isEmpty) return false;
    return containsAll(name.toLowerCase(), _literalWords);
  }

  bool get _filters => smart?.hasFilters ?? false;

  /// Whether anything but a name typed as is can match: something
  /// understood, or words to look for inside files.
  bool get beyondNames => _filters || ((insideFiles || photoText) && words.isNotEmpty);

  /// Whether [passesStat] needs the file's size or date.
  bool get needsStat => (smart?.dates.isNotEmpty ?? false) || (smart?.sizes.isNotEmpty ?? false);

  /// Folders are only kinds of nothing: they pass places, not kinds, sizes
  /// or dates.
  bool passesName(String path, {required bool isDirectory}) {
    final s = smart;
    if (s == null) return true;
    if (isDirectory && (s.kinds.isNotEmpty || s.extensions.isNotEmpty || s.sizes.isNotEmpty || s.dates.isNotEmpty)) {
      return false;
    }
    if (s.kinds.isNotEmpty || s.extensions.isNotEmpty) {
      final ext = FileTypes.extensionOf(path);
      if (!s.extensions.contains(ext) && !s.kinds.any((k) => k.matches(path))) return false;
    }
    if (s.places.isNotEmpty &&
        !s.places.any((place) => place.holds(path, folders: placeFolders[place] ?? const []))) {
      return false;
    }
    return true;
  }

  bool passesStat({required int size, required DateTime modified}) {
    final s = smart;
    if (s == null) return true;
    for (final span in s.sizes) {
      if (!span.contains(size)) return false;
    }
    for (final span in s.dates) {
      if (!span.contains(modified)) return false;
    }
    return true;
  }

  /// Whether every word is in [lowerText] (already lower case).
  bool wordsIn(String lowerText) => containsAll(lowerText, words);

  static bool containsAll(String lowerText, List<String> words) {
    for (final word in words) {
      if (!lowerText.contains(word)) return false;
    }
    return true;
  }

  /// Whether [path]'s name and [text] hold every word between them; the
  /// snippet shows them in [text].
  SearchSnippet? matchText(String path, String text) {
    final name = p.basename(path).toLowerCase();
    final lower = text.toLowerCase();
    for (final word in words) {
      if (!name.contains(word) && !lower.contains(word)) return null;
    }
    return SearchSnippet.find(text, words, lower: lower) ?? const SearchSnippet('', []);
  }
}
