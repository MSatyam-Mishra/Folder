import 'dart:typed_data';

import 'package:folders/core/services/bookmark_service.dart';
import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../book/book_models.dart';

/// Contents (nested TOC) and bookmarks, used as a drawer on phones and as a
/// docked pane on tablets/foldables.
class ReaderSidePanel extends StatefulWidget {
  const ReaderSidePanel({
    super.key,
    required this.info,
    required this.cover,
    required this.current,
    required this.bookmarks,
    required this.bookmarkLabel,
    required this.onTocTap,
    required this.onBookmarkTap,
    required this.onBookmarkDelete,
    this.onClose,
  });

  final BookInfo info;
  final Uint8List? cover;

  /// The TOC entry being read (highlighted and scrolled into view).
  final FlatTocEntry? current;
  final List<Bookmark> bookmarks;
  final String Function(Bookmark) bookmarkLabel;
  final ValueChanged<TocEntry> onTocTap;
  final ValueChanged<Bookmark> onBookmarkTap;
  final ValueChanged<Bookmark> onBookmarkDelete;

  /// Shown as a close button in the header (docked mode).
  final VoidCallback? onClose;

  @override
  State<ReaderSidePanel> createState() => _ReaderSidePanelState();
}

class _ReaderSidePanelState extends State<ReaderSidePanel> {
  /// Approximate height of a one-line row, for the initial scroll offset.
  static const _rowHeight = 42.0;
  final Set<int> _collapsed = {};
  int _tab = 0;
  late ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    final flat = widget.info.flatToc;
    // Big books: start with deep levels collapsed.
    if (flat.length > 150) {
      for (final f in flat) {
        if (f.depth >= 1 && f.entry.children.isNotEmpty) _collapsed.add(f.order);
        if (f.depth == 0 && f.entry.children.length > 40) _collapsed.add(f.order);
      }
      _expandToCurrent();
    }
    final index = _visible().indexWhere((f) => f.order == widget.current?.order);
    _scroll = ScrollController(
      initialScrollOffset: index <= 3 ? 0 : (index - 3) * _rowHeight,
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _expandToCurrent() {
    final current = widget.current;
    if (current == null) return;
    // Expand every ancestor of the current entry.
    final flat = widget.info.flatToc;
    var depth = current.depth;
    for (var i = current.order - 1; i >= 0 && depth > 0; i--) {
      if (flat[i].depth < depth) {
        _collapsed.remove(flat[i].order);
        depth = flat[i].depth;
      }
    }
  }

  static bool _hasTarget(TocEntry e) =>
      e.spineIndex != null || e.children.any(_hasTarget);

  List<FlatTocEntry> _visible() {
    final out = <FlatTocEntry>[];
    int? hideDeeperThan;
    for (final f in widget.info.flatToc) {
      if (hideDeeperThan != null) {
        if (f.depth > hideDeeperThan) continue;
        hideDeeperThan = null;
      }
      out.add(f);
      if (_collapsed.contains(f.order)) hideDeeperThan = f.depth;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          _Header(
            info: widget.info,
            cover: widget.cover,
            onClose: widget.onClose,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: ViewerTabs(
              tabs: [
                'Contents',
                widget.bookmarks.isEmpty
                    ? 'Bookmarks'
                    : 'Bookmarks (${widget.bookmarks.length})',
              ],
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [_buildToc(context), _buildBookmarks(context)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToc(BuildContext context) {
    final visible = _visible();
    if (visible.isEmpty) {
      return const ViewerMessage(
        icon: LucideIcons.listTree,
        title: 'No table of contents',
        message: "This book doesn't list its chapters.",
      );
    }
    final currentOrder = widget.current?.order;
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final f = visible[i];
          final collapsed = _collapsed.contains(f.order);
          return ViewerListTile(
            title: f.entry.title,
            indent: f.depth * 16.0,
            emphasis: f.depth == 0,
            selected: f.order == currentOrder,
            enabled: _hasTarget(f.entry),
            onTap: () => widget.onTocTap(f.entry),
            trailing: f.entry.children.isNotEmpty
                ? ViewerAction(
                    size: 32,
                    iconSize: 16,
                    color: context.colors.mutedForeground,
                    tooltip: collapsed ? 'Expand' : 'Collapse',
                    icon: collapsed
                        ? LucideIcons.chevronRight
                        : LucideIcons.chevronDown,
                    onPressed: () => setState(() {
                      if (!_collapsed.remove(f.order)) {
                        _collapsed.add(f.order);
                      }
                    }),
                  )
                : null,
          );
        },
      ),
    );
  }

  Widget _buildBookmarks(BuildContext context) {
    if (widget.bookmarks.isEmpty) {
      return const ViewerMessage(
        icon: LucideIcons.bookmark,
        title: 'No bookmarks yet',
        message: 'Use the bookmark button in the top bar to save your place.',
      );
    }
    final dateFormat = DateFormat.yMMMd();
    final sorted = [...widget.bookmarks]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final b = sorted[i];
        return ViewerListTile(
          leading: const Icon(LucideIcons.bookmark),
          title: widget.bookmarkLabel(b),
          subtitle: dateFormat.format(b.createdAt),
          onTap: () => widget.onBookmarkTap(b),
          trailing: ViewerAction(
            size: 32,
            iconSize: 16,
            color: context.colors.mutedForeground,
            tooltip: 'Remove bookmark',
            icon: LucideIcons.trash2,
            onPressed: () => widget.onBookmarkDelete(b),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.info, required this.cover, this.onClose});

  final BookInfo info;
  final Uint8List? cover;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final meta = info.metadata;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 76,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: context.isDarkMode ? 0.4 : 0.08,
                  ),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: cover != null
                ? Image.memory(
                    cover!,
                    fit: BoxFit.cover,
                    cacheWidth: 168,
                    errorBuilder: (_, _, _) => _placeholder(context),
                  )
                : _placeholder(context),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                if (meta.authorLine.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    meta.authorLine,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: colors.border),
                  ),
                  child: Text(
                    '${info.format.name.toUpperCase()} · '
                    '${info.spine.length} section${info.spine.length == 1 ? '' : 's'}',
                    style: text.labelMedium,
                  ),
                ),
              ],
            ),
          ),
          if (onClose != null)
            ViewerAction(
              icon: LucideIcons.panelLeftClose,
              tooltip: 'Hide contents',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }

  Widget _placeholder(BuildContext context) => ColoredBox(
        color: context.colors.muted,
        child: Icon(
          LucideIcons.bookOpen,
          size: 20,
          color: context.colors.mutedForeground,
        ),
      );
}
