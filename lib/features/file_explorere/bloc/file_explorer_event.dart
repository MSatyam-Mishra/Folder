part of 'file_explorer_bloc.dart';

@immutable
abstract class FileExplorerEvent {}

class LoadDirectory extends FileExplorerEvent {
  final String path;

  /// The item to select once it's loaded (one just made)...
  final String? select;

  /// ...and to rename where it's shown.
  final bool rename;

  /// What it does to Back and Forward.
  final HistoryStep step;

  LoadDirectory(this.path, {this.select, this.rename = false, this.step = HistoryStep.record});
}

class StopRenaming extends FileExplorerEvent {}

class ToggleSelectionMode extends FileExplorerEvent {
  final bool enable;
  ToggleSelectionMode({required this.enable});
}

class SelectItem extends FileExplorerEvent {
  final FileSystemEntity entity;
  SelectItem(this.entity);
}

class ChangeViewMode extends FileExplorerEvent {
  final ViewMode mode;
  ChangeViewMode(this.mode);
}

class ChangeSortOrder extends FileExplorerEvent {
  final SortOption option;
  final SortOrder order;
  ChangeSortOrder(this.option, this.order);
}

class ClearSelection extends FileExplorerEvent {}

/// Selects exactly [items] (mouse clicks on desktop). [selectionMode] shows
/// the selection bar and check boxes; without it the items are only
/// highlighted.
class SetSelection extends FileExplorerEvent {
  final Set<FileSystemEntity> items;
  final bool selectionMode;
  SetSelection(this.items, {this.selectionMode = false});
}

/// Selects every entry shown (the search results while searching).
class SelectAll extends FileExplorerEvent {}

/// Shows the items under headings (or not, with [GroupBy.none]).
class ChangeGroupBy extends FileExplorerEvent {
  final GroupBy groupBy;
  ChangeGroupBy(this.groupBy);
}

/// Opens the search box.
class OpenSearch extends FileExplorerEvent {}

/// What's typed in the search box: the folder's matching items show at
/// once, then matches from its subfolders as they're found.
class SearchChanged extends FileExplorerEvent {
  final String query;
  SearchChanged(this.query);
}

/// Closes the search box; the folder shows again.
class CloseSearch extends FileExplorerEvent {}

/// Smart search, Inside files or Everywhere switched; searches again.
class ChangeSearchOptions extends FileExplorerEvent {
  final SearchOptions options;
  ChangeSearchOptions(this.options);
}

/// Takes what a chip under the search box stands for out of the query, and
/// searches again.
class RemoveSearchChip extends FileExplorerEvent {
  final QueryChip chip;
  RemoveSearchChip(this.chip);
}
