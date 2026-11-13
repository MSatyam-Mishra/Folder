import 'dart:io';

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/search/file_search.dart';
import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:folders/core/services/search/search_criteria.dart';
import 'package:folders/core/services/search/search_options.dart';
import 'package:folders/core/services/search/search_places.dart';
import 'package:folders/core/services/search/smart_query.dart';

export 'package:folders/core/services/search/file_search.dart' show SearchProgress;
export 'package:folders/core/services/search/search_criteria.dart' show SearchSnippet;
export 'package:folders/core/services/search/search_options.dart';
export 'package:folders/core/services/search/smart_query.dart' show QueryChip, QueryChipType, SmartQuery;

/// The search box's state besides what's typed and found: its options, what
/// the query was understood as, the words in context, how far it's got.
class SearchInfo {
  const SearchInfo({
    this.options = const SearchOptions(),
    this.understood,
    this.snippets = const {},
    this.progress = const SearchProgress(),
    this.edits = 0,
  });

  final SearchOptions options;

  /// What Smart search made of the query; null with it off.
  final SmartQuery? understood;

  /// Text around the words, for results found inside files, by path.
  final Map<String, SearchSnippet> snippets;

  final SearchProgress progress;

  /// Counts changes the app made to the query (a chip removed), so the
  /// search box shows the new one.
  final int edits;

  SearchInfo copyWith({
    SearchOptions? options,
    SmartQuery? understood,
    bool forgetUnderstood = false,
    Map<String, SearchSnippet>? snippets,
    SearchProgress? progress,
    int? edits,
  }) =>
      SearchInfo(
        options: options ?? this.options,
        understood: forgetUnderstood ? null : (understood ?? this.understood),
        snippets: snippets ?? this.snippets,
        progress: progress ?? this.progress,
        edits: edits ?? this.edits,
      );

  /// Nothing searched: only the options and the edit count stay.
  SearchInfo get cleared => SearchInfo(options: options, edits: edits);
}

/// Where a search looks after the folder's own items.
abstract final class SearchScope {
  static bool _onDisk(String path) => !ExplorerPaths.isVirtual(path) && !path.startsWith('explorer://');

  static bool _listed(String path) => ExplorerPaths.isCategory(path) || ExplorerPaths.isSocial(path);

  /// Whether photos' text is looked in: for words left over, when the
  /// search looks inside files or something narrows the photos down ("from
  /// March"), and the system can read text in pictures.
  static bool photoText(SmartQuery? smart, SearchOptions options) =>
      smart != null &&
      smart.words.isNotEmpty &&
      (options.insideFiles || smart.hasFilters) &&
      PhotoTextIndex.shared != null;

  /// Whether the search of [path] goes on in the background: through its
  /// subfolders, everywhere, in the places named, or (a category's files,
  /// all listed already) for what their names don't show.
  static bool goesOn(String path, String query, SearchOptions options, SmartQuery? smart) {
    if (options.everywhere || _onDisk(path)) return true;
    if (smart != null && smart.places.isNotEmpty) return true;
    if (!_listed(path)) return false;
    return (smart?.hasFilters ?? false) ||
        (options.insideFiles && SearchCriteria(query, smart: smart, insideFiles: true).words.isNotEmpty) ||
        photoText(smart, options);
  }

  /// The search to run in the background for [query] in [path], whose items
  /// are [entities].
  static Future<SearchSpec> spec({
    required String path,
    required String query,
    required SmartQuery? smart,
    required SearchOptions options,
    required List<FileSystemEntity> entities,
    required bool showHidden,
  }) async {
    final places = smart?.places ?? const <SearchPlace>{};
    final roots = <String>[
      if (options.everywhere) ...await SearchPlaces.everywhere() else if (_onDisk(path)) path,
      for (final place in places) ...SearchPlaces.rootsFor(place),
    ];
    return SearchSpec(
      query: query,
      roots: SearchPlaces.outermost(roots),
      files: !options.everywhere && _listed(path)
          ? [for (final e in entities) if (e is File && _onDisk(e.path)) e.path]
          : const [],
      smart: smart,
      insideFiles: options.insideFiles,
      photoText: photoText(smart, options),
      showHidden: showHidden,
      placeFolders: {for (final place in places) place: SearchPlaces.foldersFor(place)},
    );
  }
}
