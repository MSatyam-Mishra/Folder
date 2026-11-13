import 'dart:io';

import 'package:folders/core/services/search/file_search.dart';

/// Whether a name matches what was typed in the search box: anywhere in
/// the name, ignoring case; with * or ? it's a pattern for the whole name
/// ("*.pdf", "IMG_20??*").
class NameMatcher {
  NameMatcher(String query)
      : _query = query.trim().toLowerCase(),
        _pattern = query.contains('*') || query.contains('?')
            ? RegExp(
                '^${query.trim().split('').map((c) => switch (c) {
                      '*' => '.*',
                      '?' => '.',
                      _ => RegExp.escape(c),
                    }).join()}\$',
                caseSensitive: false,
              )
            : null;

  final String _query;
  final RegExp? _pattern;

  bool matches(String name) =>
      _pattern?.hasMatch(name) ?? name.toLowerCase().contains(_query);
}

/// Items inside [root]'s subfolders (not its own items, which the caller
/// already filters) whose names match [query], in batches as they're found.
/// Hidden items are skipped unless [showHidden]. On macOS packages (apps,
/// document packages) can match but aren't searched inside, as in Finder.
/// Stops after [limit] matches, or when the stream is cancelled. The search
/// box itself uses [FileSearch], which also understands plain words and
/// looks inside files.
Stream<List<FileSystemEntity>> searchSubfolders(
  String root,
  String query, {
  bool showHidden = false,
  int limit = 2000,
}) =>
    FileSearch.run(SearchSpec(
      query: query,
      roots: [root],
      rootItems: false,
      showHidden: showHidden,
      limit: limit,
    ))
        .where((update) => update.hits.isNotEmpty)
        .map((update) => [for (final hit in update.hits) hit.entity]);
