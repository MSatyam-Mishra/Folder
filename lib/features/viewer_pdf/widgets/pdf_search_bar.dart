import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' show PdfTextSearcher;

/// Floating find bar: query field, match count, previous/next and options.
class PdfSearchBar extends StatelessWidget {
  const PdfSearchBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.result,
    required this.searching,
    required this.matchCase,
    required this.wholeWords,
    required this.onSubmitted,
    required this.onOptionsChanged,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final PdfTextSearcher? result;

  /// True when a query was submitted and results are pending.
  final bool searching;
  final bool matchCase;
  final bool wholeWords;
  final ValueChanged<String> onSubmitted;
  final void Function({bool? matchCase, bool? wholeWords}) onOptionsChanged;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final options = matchCase || wholeWords;
    return AppPanel(
      translucent: true,
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          children: [
            Expanded(
              child: ViewerSearchField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                onSubmitted: onSubmitted,
              ),
            ),
            _ResultLabel(result: result, searching: searching),
            _buildNavigation(),
            ViewerMenuButton<String>(
              tooltip: 'Search options',
              icon: LucideIcons.slidersHorizontal,
              badge: options,
              size: 36,
              minMenuWidth: 180,
              onSelected: (value) => value == 'case'
                  ? onOptionsChanged(matchCase: !matchCase)
                  : onOptionsChanged(wholeWords: !wholeWords),
              itemBuilder: (context) => [
                viewerMenuItem(
                  value: 'case',
                  icon: LucideIcons.caseSensitive,
                  label: 'Match case',
                  checked: matchCase,
                ),
                viewerMenuItem(
                  value: 'words',
                  icon: LucideIcons.wholeWord,
                  label: 'Whole words',
                  checked: wholeWords,
                ),
              ],
            ),
            ViewerAction(
              icon: LucideIcons.x,
              tooltip: 'Close search',
              size: 36,
              iconSize: 18,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    final result = this.result;
    Widget buttons(bool enabled) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ViewerAction(
          icon: LucideIcons.chevronUp,
          tooltip: 'Previous match',
          size: 36,
          iconSize: 18,
          onPressed: enabled ? result!.goToPrevMatch : null,
        ),
        ViewerAction(
          icon: LucideIcons.chevronDown,
          tooltip: 'Next match',
          size: 36,
          iconSize: 18,
          onPressed: enabled ? result!.goToNextMatch : null,
        ),
      ],
    );
    if (result == null) return buttons(false);
    return ListenableBuilder(
      listenable: result,
      builder: (context, _) => buttons(result.hasMatches),
    );
  }
}

class _ResultLabel extends StatelessWidget {
  const _ResultLabel({required this.result, required this.searching});

  final PdfTextSearcher? result;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final result = this.result;
    if (result == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: result,
      builder: (context, _) {
        String text;
        if (result.hasMatches) {
          text = '${(result.currentIndex ?? 0) + 1}/${result.matches.length}';
          if (result.isSearching) text += '+';
        } else if (!result.isSearching || !searching) {
          text = 'No matches';
        } else {
          text = 'Searching…';
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(text, style: style),
        );
      },
    );
  }
}
