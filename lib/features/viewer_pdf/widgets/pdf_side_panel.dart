import 'package:folder/core/services/bookmark_service.dart';
import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

/// One entry of the document outline (the PDF's own bookmarks).
class PdfOutlineEntry {
  PdfOutlineEntry(this.title, this.dest, this.children);

  final String title;

  /// Where the entry points; null when it has no target.
  final pdfrx.PdfDest? dest;
  final List<PdfOutlineEntry> children;

  /// Reads the outline of [document]. Malformed entries are skipped.
  static Future<List<PdfOutlineEntry>> read(pdfrx.PdfDocument document) async {
    try {
      var budget = 5000;
      List<PdfOutlineEntry> convert(
        List<pdfrx.PdfOutlineNode> nodes,
        int depth,
      ) => [
        for (final node in nodes)
          if (budget-- > 0)
            PdfOutlineEntry(
              node.title.trim().isEmpty ? 'Untitled' : node.title.trim(),
              node.dest,
              depth < 24 ? convert(node.children, depth + 1) : const [],
            ),
      ];
      return convert(await document.loadOutline(), 0);
    } catch (_) {
      return const [];
    }
  }
}

/// Outline, user bookmarks and page manager in tabs. Used as a docked pane
/// on wide screens and inside the drawer on phones.
class PdfSidePanel extends StatefulWidget {
  const PdfSidePanel({
    super.key,
    required this.tabIndex,
    required this.onTabChanged,
    required this.outline,
    required this.onOutlineSelected,
    required this.bookmarks,
    required this.currentPage,
    required this.onBookmarkSelected,
    required this.onBookmarkRemoved,
    required this.onAddBookmark,
    required this.pages,
    this.onClose,
  });

  final int tabIndex;
  final ValueChanged<int> onTabChanged;

  /// Null while the document is loading.
  final List<PdfOutlineEntry>? outline;
  final ValueChanged<PdfOutlineEntry> onOutlineSelected;
  final List<Bookmark> bookmarks;
  final int currentPage;

  /// Called with the 0-based page index of the bookmark.
  final ValueChanged<int> onBookmarkSelected;
  final ValueChanged<Bookmark> onBookmarkRemoved;
  final VoidCallback? onAddBookmark;

  /// Content of the Pages tab.
  final Widget pages;
  final VoidCallback? onClose;

  @override
  State<PdfSidePanel> createState() => _PdfSidePanelState();
}

class _PdfSidePanelState extends State<PdfSidePanel> {
  static const _tabs = ['Outline', 'Bookmarks', 'Pages'];

  late int _index = widget.tabIndex.clamp(0, 2);
  final Set<String> _expanded = {};

  /// Tabs that have been shown; others aren't built until first visited so
  /// the page manager only loads its data when it is actually opened.
  late final Set<int> _visited = {_index};

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      _visited.add(index);
    });
    if (index != widget.tabIndex) widget.onTabChanged(index);
  }

  @override
  void didUpdateWidget(PdfSidePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only follow the owner when it asks for a different tab, so a rebuild
    // during a tab switch doesn't snap back to the old tab.
    final index = widget.tabIndex.clamp(0, 2);
    if (widget.tabIndex != oldWidget.tabIndex && index != _index) {
      _index = index;
      _visited.add(index);
    }
    if (!identical(oldWidget.outline, widget.outline)) _expanded.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              widget.onClose != null ? 4 : 12,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: ViewerTabs(
                    tabs: _tabs,
                    index: _index,
                    onChanged: _select,
                  ),
                ),
                if (widget.onClose != null) ...[
                  const SizedBox(width: 4),
                  ViewerAction(
                    icon: LucideIcons.panelLeftClose,
                    tooltip: 'Hide panel',
                    onPressed: widget.onClose,
                  ),
                ],
              ],
            ),
          ),
          // An IndexedStack keeps each tab's scroll position.
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                _visited.contains(0)
                    ? _buildOutline(context)
                    : const SizedBox.shrink(),
                _visited.contains(1)
                    ? _buildBookmarks(context)
                    : const SizedBox.shrink(),
                _visited.contains(2) ? widget.pages : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOutline(BuildContext context) {
    final outline = widget.outline;
    if (outline == null) {
      return const Center(child: ViewerSpinner(size: 20));
    }
    if (outline.isEmpty) {
      return const ViewerMessage(
        icon: LucideIcons.listTree,
        title: 'No outline',
        message: "This PDF doesn't include a table of contents.",
      );
    }
    final rows = <(PdfOutlineEntry, int, String)>[];
    void add(List<PdfOutlineEntry> nodes, int depth, String prefix) {
      for (var i = 0; i < nodes.length; i++) {
        final key = '$prefix/$i';
        rows.add((nodes[i], depth, key));
        if (_expanded.contains(key)) add(nodes[i].children, depth + 1, key);
      }
    }

    add(outline, 0, '');
    return ListView.builder(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final (node, depth, key) = rows[index];
        final expandable = node.children.isNotEmpty;
        final expanded = _expanded.contains(key);
        return ViewerListTile(
          title: node.title,
          indent: depth * 16.0,
          emphasis: depth == 0,
          onTap: () => widget.onOutlineSelected(node),
          trailing: expandable
              ? ViewerAction(
                  size: 32,
                  iconSize: 16,
                  color: context.colors.mutedForeground,
                  tooltip: expanded ? 'Collapse' : 'Expand',
                  icon: expanded
                      ? LucideIcons.chevronDown
                      : LucideIcons.chevronRight,
                  onPressed: () => setState(() {
                    if (!_expanded.remove(key)) _expanded.add(key);
                  }),
                )
              : null,
        );
      },
    );
  }

  Widget _buildBookmarks(BuildContext context) {
    final bookmarks = [...widget.bookmarks]
      ..sort((a, b) => _page(a).compareTo(_page(b)));
    final current = widget.currentPage - 1;
    final alreadyMarked = bookmarks.any((b) => _page(b) == current);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: alreadyMarked ? null : widget.onAddBookmark,
              icon: Icon(
                alreadyMarked
                    ? LucideIcons.bookmarkCheck
                    : LucideIcons.bookmarkPlus,
                size: 16,
              ),
              label: Text(
                alreadyMarked
                    ? 'Page ${widget.currentPage} is bookmarked'
                    : 'Bookmark page ${widget.currentPage}',
              ),
            ),
          ),
        ),
        Expanded(
          child: bookmarks.isEmpty
              ? const ViewerMessage(
                  icon: LucideIcons.bookmark,
                  title: 'No bookmarks yet',
                  message: 'Bookmark pages to come back to them quickly.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: bookmarks.length,
                  itemBuilder: (context, index) {
                    final bookmark = bookmarks[index];
                    final created = bookmark.createdAt;
                    return ViewerListTile(
                      leading: const Icon(LucideIcons.bookmark),
                      title: bookmark.label,
                      subtitle:
                          'Added ${created.year}-${_two(created.month)}-'
                          '${_two(created.day)}',
                      selected: _page(bookmark) == current,
                      onTap: () => widget.onBookmarkSelected(_page(bookmark)),
                      trailing: ViewerAction(
                        size: 32,
                        iconSize: 16,
                        color: context.colors.mutedForeground,
                        tooltip: 'Remove bookmark',
                        icon: LucideIcons.trash2,
                        onPressed: () => widget.onBookmarkRemoved(bookmark),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static int _page(Bookmark bookmark) {
    final position = bookmark.position;
    if (position is int) return position;
    if (position is num) return position.toInt();
    return int.tryParse('$position') ?? 0;
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
