part of 'file_explorer_bloc.dart';

@immutable
abstract class FileExplorerState {}

class FileExplorerInitial extends FileExplorerState {}

class FileExplorerLoading extends FileExplorerState {
  /// The folder being opened, when known.
  final String? path;

  FileExplorerLoading({this.path});
}

class FileExplorerLoaded extends FileExplorerState {
  final List<FileSystemEntity> entities;
  final String path;
  final bool isSelectionMode;
  final Set<FileSystemEntity> selectedItems;
  final ViewMode viewMode;
  final SortOption sortOption;
  final SortOrder sortOrder;

  /// Optional display names (e.g. Windows drives / libraries on This PC).
  final Map<String, String> pathLabels;

  /// Headings the items are grouped under; [groups] holds what's shown,
  /// empty when not grouped.
  final GroupBy groupBy;
  final List<EntityGroup> groups;

  /// The search box: whether it's open, what's typed, the matches (this
  /// folder's first, then its subfolders'), and whether subfolders are
  /// still being searched.
  final bool searchOpen;
  final String query;
  final List<FileSystemEntity> searchResults;
  final bool searching;

  /// The search's options, what it understood, words in context, progress.
  final SearchInfo search;

  /// The item whose name is being edited in the list.
  final String? renamingPath;

  /// The folder's items, or the search results while searching.
  List<FileSystemEntity> get visibleEntities =>
      query.isEmpty ? entities : searchResults;

  /// [visibleEntities] in the order shown (group after group).
  List<FileSystemEntity> get displayEntities => groups.isEmpty
      ? visibleEntities
      : [for (final group in groups) ...group.entities];

  FileExplorerLoaded({
    required this.entities,
    required this.path,
    this.isSelectionMode = false,
    this.selectedItems = const {},
    this.viewMode = ViewMode.list,
    this.sortOption = SortOption.name,
    this.sortOrder = SortOrder.ascending,
    this.pathLabels = const {},
    this.groupBy = GroupBy.none,
    this.groups = const [],
    this.searchOpen = false,
    this.query = '',
    this.searchResults = const [],
    this.searching = false,
    this.search = const SearchInfo(),
    this.renamingPath,
  });

  String labelFor(FileSystemEntity entity) {
    return pathLabels[entity.path] ??
        ExplorerPaths.displayNameForEntity(entity.path);
  }

  FileExplorerLoaded copyWith({
    List<FileSystemEntity>? entities,
    String? path,
    bool? isSelectionMode,
    Set<FileSystemEntity>? selectedItems,
    ViewMode? viewMode,
    SortOption? sortOption,
    SortOrder? sortOrder,
    Map<String, String>? pathLabels,
    GroupBy? groupBy,
    List<EntityGroup>? groups,
    bool? searchOpen,
    String? query,
    List<FileSystemEntity>? searchResults,
    bool? searching,
    SearchInfo? search,
    String? renamingPath,
    bool stopRenaming = false,
  }) {
    return FileExplorerLoaded(
      entities: entities ?? this.entities,
      path: path ?? this.path,
      isSelectionMode: isSelectionMode ?? this.isSelectionMode,
      selectedItems: selectedItems ?? this.selectedItems,
      viewMode: viewMode ?? this.viewMode,
      sortOption: sortOption ?? this.sortOption,
      sortOrder: sortOrder ?? this.sortOrder,
      pathLabels: pathLabels ?? this.pathLabels,
      groupBy: groupBy ?? this.groupBy,
      groups: groups ?? this.groups,
      searchOpen: searchOpen ?? this.searchOpen,
      query: query ?? this.query,
      searchResults: searchResults ?? this.searchResults,
      searching: searching ?? this.searching,
      search: search ?? this.search,
      renamingPath: stopRenaming ? null : (renamingPath ?? this.renamingPath),
    );
  }
}

class FileExplorerError extends FileExplorerState {
  final String message;

  /// The folder that failed to open, when known.
  final String? path;

  FileExplorerError(this.message, {this.path});
}
