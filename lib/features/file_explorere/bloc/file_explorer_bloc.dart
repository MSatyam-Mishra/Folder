import 'dart:async';
import 'dart:io';
import 'package:bloc/bloc.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/services/folder_prefs_service.dart';
import 'package:folders/core/services/search/file_search.dart';
import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:folders/core/services/search/search_criteria.dart';
import 'package:folders/core/services/trash/trash.dart';
import 'package:folders/features/file_explorere/bloc/folder_history.dart';
import 'package:folders/features/file_explorere/bloc/grouping.dart';
import 'package:folders/features/file_explorere/bloc/search_info.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

export 'package:folders/features/file_explorere/bloc/folder_history.dart' show HistoryStep;

part 'file_explorer_event.dart';
part 'file_explorer_state.dart';

class FileExplorerBloc extends Bloc<FileExplorerEvent, FileExplorerState> {
  final FileRepository repository;

  FileExplorerBloc({FileRepository? repository, bool? watchFolders})
    : repository = repository ?? LocalFileRepository(),
      // Off in widget tests, whose clock is fake.
      watchFolders =
          watchFolders ?? !Platform.environment.containsKey('FLUTTER_TEST'),
      super(FileExplorerInitial()) {
    on<LoadDirectory>(_onLoadDirectory);

    on<ToggleSelectionMode>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(
          currentState.copyWith(
            isSelectionMode: event.enable,
            selectedItems: {}, // Clear selection when toggling mode
          ),
        );
      }
    });

    on<StopRenaming>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(currentState.copyWith(stopRenaming: true));
      }
    });

    on<SelectItem>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        // Create a new, modifiable set from the current selection
        final newSelectedItems = Set<FileSystemEntity>.from(
          currentState.selectedItems,
        );
        if (newSelectedItems.contains(event.entity)) {
          newSelectedItems.remove(event.entity); // Deselect if already selected
        } else {
          newSelectedItems.add(event.entity); // Select if not selected
        }
        emit(currentState.copyWith(selectedItems: newSelectedItems));
      }
    });

    on<SelectAll>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(
          currentState.copyWith(
            isSelectionMode: true,
            selectedItems: Set<FileSystemEntity>.of(currentState.visibleEntities),
          ),
        );
      }
    });

    on<SetSelection>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(
          currentState.copyWith(
            isSelectionMode: event.selectionMode,
            selectedItems: Set<FileSystemEntity>.of(event.items),
          ),
        );
      }
    });

    on<ClearSelection>((event, emit) {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        emit(currentState.copyWith(selectedItems: {}));
      }
    });
    on<ChangeViewMode>((event, emit) async {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        await FolderPrefsService().setViewMode(currentState.path, event.mode);
        // Another folder may have opened meanwhile; don't bring this one back.
        final latest = state;
        if (latest is FileExplorerLoaded && latest.path == currentState.path) {
          emit(latest.copyWith(viewMode: event.mode));
        }
      }
    });

    on<ChangeSortOrder>((event, emit) async {
      final currentState = state;
      if (currentState is FileExplorerLoaded) {
        await FolderPrefsService().setSort(
          currentState.path,
          event.option,
          event.order,
        );
        final sortedEntities = await _sortEntities(
          currentState.entities,
          event.option,
          event.order,
          pathLabels: currentState.pathLabels,
        );
        final latest = state;
        if (latest is! FileExplorerLoaded || latest.path != currentState.path) {
          return;
        }
        final sorted = latest.copyWith(
          sortOption: event.option,
          sortOrder: event.order,
          entities: sortedEntities,
          searchResults: latest.query.isEmpty
              ? null
              : _sortedLike(latest.searchResults, sortedEntities),
        );
        emit(sorted.copyWith(groups: await _group(sorted)));
      }
    });

    on<ChangeGroupBy>((event, emit) async {
      final current = state;
      if (current is! FileExplorerLoaded) return;
      await FolderPrefsService().setGroupBy(current.path, event.groupBy);
      final groups = await _group(current.copyWith(groupBy: event.groupBy));
      final latest = state;
      if (latest is FileExplorerLoaded && latest.path == current.path) {
        emit(latest.copyWith(groupBy: event.groupBy, groups: groups));
      }
    });

    on<OpenSearch>((event, emit) async {
      final current = state;
      if (current is! FileExplorerLoaded) return;
      emit(current.copyWith(searchOpen: true));
      // The remembered options; Everywhere stays as it is.
      final before = current.search.options;
      final options = (await SearchOptions.load()).copyWith(everywhere: before.everywhere);
      final latest = state;
      if (options == before || latest is! FileExplorerLoaded || latest.path != current.path) return;
      emit(latest.copyWith(search: latest.search.copyWith(options: options)));
      if (latest.query.isNotEmpty) add(SearchChanged(latest.query));
    });

    on<CloseSearch>((event, emit) async {
      _searchGeneration++;
      final current = state;
      if (current is! FileExplorerLoaded) return;
      final closed = current.copyWith(
        searchOpen: false,
        query: '',
        searchResults: const [],
        searching: false,
        search: SearchInfo(options: current.search.options.copyWith(everywhere: false), edits: current.search.edits),
      );
      emit(closed.copyWith(groups: await _group(closed)));
    });

    on<SearchChanged>(_onSearchChanged);

    on<ChangeSearchOptions>((event, emit) async {
      final current = state;
      if (current is! FileExplorerLoaded) return;
      emit(current.copyWith(search: current.search.copyWith(options: event.options)));
      if (current.query.isNotEmpty) add(SearchChanged(current.query));
      await event.options.save();
    });

    on<RemoveSearchChip>((event, emit) {
      final current = state;
      if (current is! FileExplorerLoaded) return;
      final query = current.search.understood?.without(event.chip);
      if (query == null) return;
      // The search box shows the new query.
      emit(current.copyWith(query: query, search: current.search.copyWith(edits: current.search.edits + 1)));
      add(SearchChanged(query));
    });
  }

  /// Incremented per search; a search's late results are dropped once
  /// another one started.
  int _searchGeneration = 0;

  Future<void> _onSearchChanged(SearchChanged event, Emitter<FileExplorerState> emit) async {
    final generation = ++_searchGeneration;
    final current = state;
    if (current is! FileExplorerLoaded) return;
    final query = event.query.trim();
    if (query.isEmpty) {
      final cleared = current.copyWith(
        searchOpen: true,
        query: '',
        searchResults: const [],
        searching: false,
        search: current.search.cleared,
      );
      emit(cleared.copyWith(groups: await _group(cleared)));
      return;
    }
    final options = current.search.options;
    final smart = options.smart ? SmartQuery.parse(query) : null;
    // The folder's own items whose names match, at once.
    final names = SearchCriteria(query, smart: smart);
    final results = [
      if (!options.everywhere)
        for (final e in current.entities)
          if (names.literal(current.labelFor(e))) e,
    ];
    // This PC lists drives: searching all of them would take ages, unless
    // asked to. A category's files are all listed already.
    final deep = SearchScope.goesOn(current.path, query, options, smart);
    var shown = current.copyWith(
      searchOpen: true,
      query: query,
      searchResults: List.of(results),
      searching: deep,
      search: current.search.cleared.copyWith(understood: smart, progress: SearchProgress(walking: deep)),
    );
    emit(shown.copyWith(groups: await _group(shown)));
    if (!deep) return;

    // Then the rest, once typing pauses.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (generation != _searchGeneration || emit.isDone) return;
    await FolderPrefsService().init();
    final spec = await SearchScope.spec(
      path: current.path,
      query: query,
      smart: smart,
      options: options,
      entities: current.entities,
      showHidden: FolderPrefsService().showHidden,
    );
    if (generation != _searchGeneration || emit.isDone) return;
    final seen = {for (final e in results) e.path};
    final snippets = <String, SearchSnippet>{};
    await for (final update in FileSearch.run(spec, photos: PhotoTextIndex.shared)) {
      final latest = state;
      if (generation != _searchGeneration || emit.isDone || latest is! FileExplorerLoaded || latest.path != current.path) {
        return; // Cancelling the stream stops the search.
      }
      var added = false;
      for (final hit in update.hits) {
        final snippet = hit.snippet;
        if (snippet != null && snippet.text.isNotEmpty) snippets[hit.path] = snippet;
        if (seen.add(hit.path)) {
          results.add(hit.entity);
          added = true;
        }
      }
      shown = latest.copyWith(
        searchResults: added ? List.of(results) : null,
        search: latest.search.copyWith(snippets: added ? Map.of(snippets) : null, progress: update.progress),
      );
      emit(added ? shown.copyWith(groups: await _group(shown)) : shown);
    }
    final latest = state;
    if (generation == _searchGeneration && !emit.isDone && latest is FileExplorerLoaded && latest.path == current.path) {
      emit(latest.copyWith(searching: false, search: latest.search.copyWith(progress: latest.search.progress.done)));
    }
  }

  /// [results] with the folder's own items in [sorted]'s order first, then
  /// those from subfolders as found.
  static List<FileSystemEntity> _sortedLike(
    List<FileSystemEntity> results,
    List<FileSystemEntity> sorted,
  ) {
    final paths = {for (final e in results) e.path};
    final own = [for (final e in sorted) if (paths.contains(e.path)) e];
    final ownPaths = {for (final e in own) e.path};
    return [...own, for (final e in results) if (!ownPaths.contains(e.path)) e];
  }

  /// The headings for what [s] shows.
  Future<List<EntityGroup>> _group(FileExplorerLoaded s) => groupEntities(
        s.visibleEntities,
        s.groupBy,
        stat: _statOrNull,
        nameOf: s.labelFor,
      );

  /// The folders this browser showed, for Back and Forward.
  final history = FolderHistory();

  /// Incremented per [LoadDirectory]; a load that finishes after a newer
  /// one started drops its result, so the last folder opened always wins.
  int _loadGeneration = 0;

  /// Whether the folder on screen is reloaded when its files change (in
  /// another window, another app, a download…).
  final bool watchFolders;
  String? _watched;
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _changed;

  void _watch(String path) {
    if (!watchFolders || path == _watched) return;
    _watcher?.cancel();
    _watcher = null;
    _changed?.cancel();
    _changed = null;
    _watched = path;
    if (ExplorerPaths.isVirtual(path)) return;
    try {
      _watcher = Directory(path).watch().listen(
        (_) {
          // At most once a second while files keep changing (a copy).
          _changed ??= Timer(const Duration(milliseconds: 700), () {
            _changed = null;
            final current = state;
            if (!isClosed && current is FileExplorerLoaded && current.path == path) {
              add(LoadDirectory(path));
            }
          });
        },
        onError: (Object _) {},
      );
    } catch (_) {
      // Some folders can't be watched (network shares): F5 still works.
    }
  }

  @override
  Future<void> close() async {
    _changed?.cancel();
    await _watcher?.cancel();
    return super.close();
  }

  Future<void> _onLoadDirectory(
    LoadDirectory event,
    Emitter<FileExplorerState> emit,
  ) async {
    final generation = ++_loadGeneration;
    bool stale() => generation != _loadGeneration;
    history.apply(event.path, event.step);
    try {
      // Refreshing the folder already on screen (e.g. after a viewer saved a
      // copy) keeps the list and its scroll position instead of flashing a
      // spinner.
      final current = state;
      final refreshing =
          current is FileExplorerLoaded && current.path == event.path;
      if (!refreshing) emit(FileExplorerLoading(path: event.path));
      _watch(event.path);

      if (!await repository.exists(event.path)) {
        if (stale()) return;
        emit(
          FileExplorerError(
            "Directory not found or access denied.",
            path: event.path,
          ),
        );
        return;
      }

      await FolderPrefsService().init();
      final viewMode = FolderPrefsService().getViewMode(event.path);
      final sortOption = FolderPrefsService().getSortOption(event.path);
      final sortOrder = FolderPrefsService().getSortOrder(event.path);
      final groupBy = FolderPrefsService().getGroupBy(event.path);

      Map<String, String> pathLabels = {};
      if (ExplorerPaths.isWindowsRoots(event.path) &&
          repository is LocalFileRepository) {
        pathLabels =
            await (repository as LocalFileRepository).windowsRootLabels();
      }

      final List<FileSystemEntity> entities = await repository.listEntities(
        event.path,
      );
      // The Trash shows its items under the names they had.
      if (ExplorerPaths.isTrash(event.path)) pathLabels = TrashListing.labels;
      final sortedEntities = await _sortEntities(
        entities,
        sortOption,
        sortOrder,
        pathLabels: pathLabels,
      );

      if (stale()) return;
      // A refresh keeps what's selected, if it's still there.
      final latest = state;
      final kept = latest is FileExplorerLoaded && latest.path == event.path
          ? {for (final e in latest.selectedItems) e.path}
          : const <String>{};
      final select = event.select;
      final selected = {
        for (final e in sortedEntities)
          if (select != null ? e.path == select : kept.contains(e.path)) e,
      };
      final same = latest is FileExplorerLoaded && latest.path == event.path;
      final loaded = FileExplorerLoaded(
        entities: sortedEntities,
        path: event.path,
        viewMode: viewMode,
        sortOption: sortOption,
        sortOrder: sortOrder,
        pathLabels: pathLabels,
        groupBy: groupBy,
        selectedItems: selected,
        isSelectionMode: select == null &&
            selected.isNotEmpty &&
            latest is FileExplorerLoaded &&
            latest.isSelectionMode,
        // A refresh of the folder doesn't end a rename going on in it.
        renamingPath: event.rename ? select : (same && select == null ? latest.renamingPath : null),
        // A refresh keeps the search box open.
        searchOpen: latest is FileExplorerLoaded && latest.path == event.path && latest.searchOpen,
        // And the search as it is; another folder only its options.
        search: same
            ? latest.search
            : SearchInfo(
                options: latest is FileExplorerLoaded
                    ? latest.search.options.copyWith(everywhere: false)
                    : const SearchOptions(),
              ),
      );
      final groups = await _group(loaded);
      if (stale()) return;
      emit(loaded.copyWith(groups: groups));
      // And searches again, so changed files show up in the results.
      if (latest is FileExplorerLoaded && latest.path == event.path && latest.query.isNotEmpty) {
        add(SearchChanged(latest.query));
      }
    } catch (e) {
      if (stale()) return;
      emit(
        FileExplorerError(
          "Failed to read directory: ${e.toString()}",
          path: event.path,
        ),
      );
    }
  }

  String _sortKey(FileSystemEntity entity, Map<String, String> pathLabels) {
    return (pathLabels[entity.path] ?? p.basename(entity.path)).toLowerCase();
  }

  static Future<FileStat?> _statOrNull(FileSystemEntity entity) async {
    try {
      return await entity.stat();
    } catch (_) {
      return null;
    }
  }

  /// Sorts with folders first; macOS packages (apps…) sort among the
  /// files, as in Finder. Each entry's key is computed once (size/date via
  /// async stat calls) instead of inside the comparator, which used to make
  /// O(n log n) synchronous stat calls on the UI isolate.
  Future<List<FileSystemEntity>> _sortEntities(
    List<FileSystemEntity> entities,
    SortOption option,
    SortOrder order, {
    Map<String, String> pathLabels = const {},
  }) async {
    final folders = [
      for (final e in entities) e is Directory && !EntityFormat.isPackage(e),
    ];
    final List<Comparable<Object>> keys;
    switch (option) {
      case SortOption.name:
        keys = [for (final e in entities) _sortKey(e, pathLabels)];
      case SortOption.size:
        // Folder and package sizes would need a full traversal. Folders
        // sort as 0; packages as -1, so their unknown size sorts at the
        // small end (like Finder's "--") without mixing with empty files.
        final stats = await Future.wait([
          for (final e in entities)
            e is File ? _statOrNull(e) : Future<FileStat?>.value(null),
        ]);
        keys = [
          for (var i = 0; i < entities.length; i++)
            entities[i] is Directory && !folders[i] ? -1 : stats[i]?.size ?? 0,
        ];
      case SortOption.date:
        final stats = await Future.wait(entities.map(_statOrNull));
        keys = [for (final s in stats) s?.modified.millisecondsSinceEpoch ?? 0];
      case SortOption.type:
        keys = [
          for (var i = 0; i < entities.length; i++)
            folders[i] ? 'dir' : p.extension(entities[i].path),
        ];
    }
    final indices = List<int>.generate(entities.length, (i) => i);
    indices.sort((i, j) {
      final aIsDir = folders[i];
      final bIsDir = folders[j];
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      final comparison = keys[i].compareTo(keys[j]);
      return order == SortOrder.ascending ? comparison : -comparison;
    });
    return [for (final i in indices) entities[i]];
  }
}
