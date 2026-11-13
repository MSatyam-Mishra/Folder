import 'dart:ui' show ImageFilter;

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/search/smart_query.dart' show SearchKind;
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/bloc/search_info.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Under the search box: what the query was understood as ("Photos",
/// "March 2026", "Text: receipt"), each with an x that takes it out of the
/// query, then Smart search, Inside files and Everywhere.
class SearchPanel extends StatelessWidget {
  const SearchPanel({super.key, required this.state});

  static const double height = 48;

  final FileExplorerLoaded state;

  static IconData chipIcon(QueryChip chip) => switch (chip.type) {
        QueryChipType.kind => switch (SearchKind.values.where((k) => k.label == chip.label).firstOrNull) {
            SearchKind.photos => LucideIcons.image,
            SearchKind.videos => LucideIcons.film,
            SearchKind.music => LucideIcons.music,
            SearchKind.spreadsheets => LucideIcons.sheet,
            SearchKind.presentations => LucideIcons.presentation,
            SearchKind.archives => LucideIcons.archive,
            SearchKind.apps => LucideIcons.package,
            SearchKind.ebooks => LucideIcons.bookOpen,
            SearchKind.code => LucideIcons.code,
            _ => LucideIcons.fileText,
          },
        QueryChipType.extension => LucideIcons.fileType,
        QueryChipType.date => LucideIcons.calendar,
        QueryChipType.size => LucideIcons.ruler,
        QueryChipType.place => LucideIcons.mapPin,
        QueryChipType.words => LucideIcons.textCursor,
      };

  static String chipLabel(QueryChip chip) => chip.type == QueryChipType.words ? 'Text: ${chip.label}' : chip.label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bloc = context.read<FileExplorerBloc>();
    final options = state.search.options;
    final understood = state.search.understood;
    // Plain words need no chips: they're what's in the box.
    final chips = understood != null && understood.hasFilters ? understood.chips : const <QueryChip>[];
    void change(SearchOptions changed) => bloc.add(ChangeSearchOptions(changed));
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: colors.background.withValues(alpha: colors.background.a * 0.82),
          child: SizedBox(
            height: height,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              // What was understood first: on a phone the options can be
              // scrolled to, the chips are what this search is about.
              children: [
                for (final chip in chips)
                  QueryChipView(
                    icon: chipIcon(chip),
                    label: chipLabel(chip),
                    onRemove: () => bloc.add(RemoveSearchChip(chip)),
                  ),
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
                    child: VerticalDivider(width: 1, color: colors.border),
                  ),
                SearchToggle(
                  icon: LucideIcons.sparkles,
                  label: 'Smart search',
                  tooltip: 'Understands plain words: photos, last week, over 10 MB, from WhatsApp',
                  selected: options.smart,
                  onChanged: (on) => change(options.copyWith(smart: on)),
                ),
                SearchToggle(
                  icon: LucideIcons.textSearch,
                  label: 'Inside files',
                  tooltip: 'Also look for the words in documents, PDFs, e-books and text files',
                  selected: options.insideFiles,
                  onChanged: (on) => change(options.copyWith(insideFiles: on)),
                ),
                SearchToggle(
                  icon: LucideIcons.globe,
                  label: 'Everywhere',
                  tooltip: ExplorerPaths.isDesktop ? 'Your folders and every drive' : 'All of this device’s storage',
                  selected: options.everywhere,
                  onChanged: (on) => change(options.copyWith(everywhere: on)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill that's on or off.
class SearchToggle extends StatelessWidget {
  const SearchToggle({
    super.key,
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = selected ? colors.primaryForeground : colors.foreground;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          toggled: selected,
          button: true,
          child: Material(
            color: selected ? colors.primary : colors.muted,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onChanged(!selected),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: foreground),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: foreground,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Something understood in the query, with an x to take it out.
class QueryChipView extends StatelessWidget {
  const QueryChipView({super.key, required this.icon, required this.label, required this.onRemove});

  final IconData icon;
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: colors.foreground,
        );
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colors.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: colors.mutedForeground),
              const SizedBox(width: 6),
              Text(label, style: text),
              Tooltip(
                message: 'Remove “$label”',
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onRemove,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                    child: Icon(LucideIcons.x, size: 14, color: colors.mutedForeground),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line of a file's text with the words searched for in bold.
class SearchSnippetText extends StatelessWidget {
  const SearchSnippetText({super.key, required this.snippet, this.selected = false});

  final SearchSnippet snippet;

  /// On a selected row (its colours follow the selection).
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final base = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: selected ? colors.accentForeground.withValues(alpha: 0.8) : colors.mutedForeground,
        );
    final marked = base?.copyWith(
      fontWeight: FontWeight.w700,
      color: selected ? colors.accentForeground : colors.foreground,
      backgroundColor: colors.primary.withValues(alpha: 0.14),
    );
    final text = snippet.text;
    final spans = <TextSpan>[];
    var at = 0;
    for (final (start, end) in snippet.highlights) {
      if (start < at || end > text.length) continue;
      if (start > at) spans.add(TextSpan(text: text.substring(at, start)));
      spans.add(TextSpan(text: text.substring(start, end), style: marked));
      at = end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// What the search is doing, for the line under the results.
String searchStatus(FileExplorerLoaded state) {
  final progress = state.search.progress;
  final count = NumberFormat.decimalPattern();
  if (progress.photos > 0) {
    return 'Reading text in ${count.format(progress.photos)} ${progress.photos == 1 ? 'photo' : 'photos'}…';
  }
  if (progress.pdfs > 0) {
    return 'Reading ${count.format(progress.pdfs)} ${progress.pdfs == 1 ? 'PDF' : 'PDFs'}…';
  }
  final where = state.search.options.everywhere ? 'Searching everywhere' : 'Searching folders inside';
  final what = state.search.options.insideFiles ? ', in names and text' : '';
  final checked = progress.checked > 0 ? ' · ${count.format(progress.checked)} looked at' : '';
  return '$where$what…$checked';
}

/// Under the results once the search is done: photos it didn't get to.
String? searchLeftOut(FileExplorerLoaded state) {
  final left = state.search.progress.photosLeftOut;
  if (left == 0) return null;
  return '${NumberFormat.decimalPattern().format(left)} more ${left == 1 ? 'photo' : 'photos'} to read: search again to look in them too';
}

/// Why nothing was found, and what to try.
String searchEmptyHint(FileExplorerLoaded state) {
  final options = state.search.options;
  final where = options.everywhere ? 'Nothing anywhere' : 'Nothing here or in the folders inside';
  final what = state.search.understood?.hasFilters ?? false
      ? 'matches all of that.'
      : (options.insideFiles ? 'has those words in its name or text.' : 'has that name.');
  final more = [if (!options.insideFiles) 'Inside files', if (!options.everywhere) 'Everywhere'];
  return [
    '$where $what',
    if (more.isNotEmpty) 'Try ${more.join(' or ')} above.',
    'Use * for any text, as in *.pdf.',
  ].join(' ');
}
