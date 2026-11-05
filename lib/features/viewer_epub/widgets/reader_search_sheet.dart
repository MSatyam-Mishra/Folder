import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';

import '../book/book_models.dart';
import '../book/book_source.dart';

/// Holds the last search so reopening the sheet shows previous results.
class ReaderSearchController extends ChangeNotifier {
  String query = '';
  List<SearchHit> results = const [];
  bool searching = false;
  bool truncated = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;

  static const maxResults = 500;

  Future<void> run(BookSource source, String text) async {
    final q = text.trim();
    final gen = ++_generation;
    query = q;
    error = null;
    if (q.isEmpty) {
      results = const [];
      searching = false;
      _notify();
      return;
    }
    searching = true;
    _notify();
    try {
      final hits = await source.search(q, maxResults: maxResults);
      if (gen != _generation) return;
      results = hits;
      truncated = hits.length >= maxResults;
    } catch (e) {
      if (gen != _generation) return;
      results = const [];
      error = 'Search failed: $e';
    }
    searching = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ReaderSearchSheet extends StatefulWidget {
  const ReaderSearchSheet({
    super.key,
    required this.controller,
    required this.source,
    required this.titleForSpine,
    required this.onSelect,
  });

  final ReaderSearchController controller;
  final BookSource source;
  final String Function(int spineIndex) titleForSpine;
  final ValueChanged<SearchHit> onSelect;

  static Future<void> show(
    BuildContext context, {
    required ReaderSearchController controller,
    required BookSource source,
    required String Function(int spineIndex) titleForSpine,
    required ValueChanged<SearchHit> onSelect,
  }) {
    if (!AppSheet.usesBottomSheet(context)) {
      return AppSheet.showRaw<void>(
        context,
        style: SheetStyle.side,
        builder: (sheetContext) => ReaderSearchSheet(
          controller: controller,
          source: source,
          titleForSpine: titleForSpine,
          onSelect: (hit) {
            Navigator.of(sheetContext).pop();
            onSelect(hit);
          },
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (sheetContext) => ReaderSearchSheet(
        controller: controller,
        source: source,
        titleForSpine: titleForSpine,
        onSelect: (hit) {
          Navigator.of(sheetContext).pop();
          onSelect(hit);
        },
      ),
    );
  }

  @override
  State<ReaderSearchSheet> createState() => _ReaderSearchSheetState();
}

class _ReaderSearchSheetState extends State<ReaderSearchSheet> {
  late final TextEditingController _text =
      TextEditingController(text: widget.controller.query);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => widget.controller.run(widget.source, _text.text);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SizedBox(
        height: media.size.height * 0.82,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'Search in book',
                style: text.titleLarge?.copyWith(fontSize: 18),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _text,
                autofocus: widget.controller.results.isEmpty,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  hintText: 'Word or phrase',
                  prefixIcon: const Icon(LucideIcons.search, size: 16),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.all(4),
                    child: ViewerAction(
                      icon: LucideIcons.cornerDownLeft,
                      tooltip: 'Search',
                      size: 36,
                      iconSize: 16,
                      onPressed: _submit,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) {
                  final c = widget.controller;
                  if (c.searching) {
                    return const Center(child: ViewerSpinner(size: 20));
                  }
                  if (c.error != null) {
                    return ViewerMessage(
                      icon: LucideIcons.circleAlert,
                      destructive: true,
                      title: "Couldn't search this book",
                      message: c.error,
                    );
                  }
                  if (c.query.isEmpty) {
                    return const ViewerMessage(
                      icon: LucideIcons.textSearch,
                      title: 'Search the whole book',
                      message: 'Type a word or phrase and press search.',
                    );
                  }
                  if (c.results.isEmpty) {
                    return ViewerMessage(
                      icon: LucideIcons.searchX,
                      title: 'No matches',
                      message: 'Nothing in this book matches "${c.query}".',
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ViewerSectionLabel(
                        c.truncated
                            ? 'First ${c.results.length} matches'
                            : '${c.results.length} match${c.results.length == 1 ? '' : 'es'}',
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
                      ),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                          itemCount: c.results.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            indent: 12,
                            endIndent: 12,
                            color: colors.border,
                          ),
                          itemBuilder: (context, i) =>
                              _hitTile(context, c.results[i]),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hitTile(BuildContext context, SearchHit hit) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final base = text.bodyMedium?.copyWith(color: colors.mutedForeground);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => widget.onSelect(hit),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.titleForSpine(hit.spineIndex),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium,
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                style: base,
                children: [
                  TextSpan(text: hit.before),
                  TextSpan(
                    text: hit.match,
                    style: TextStyle(
                      color: colors.foreground,
                      fontWeight: FontWeight.w600,
                      backgroundColor: colors.primary.withValues(alpha: 0.18),
                    ),
                  ),
                  TextSpan(text: hit.after),
                ],
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
