import 'package:flutter/material.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/features/git_status/git_porcelain.dart';
import 'package:folders/features/git_status/git_status_controller.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The colour of each kind of change, readable on light and dark.
Color gitMarkColor(GitMark mark) => switch (mark) {
      GitMark.conflicted => const Color(0xFFE5484D),
      GitMark.modified => const Color(0xFFD39210),
      GitMark.added || GitMark.staged => const Color(0xFF30A46C),
      GitMark.renamed => const Color(0xFF3E8ED0),
      GitMark.untracked => const Color(0xFF12A594),
      GitMark.ignored => const Color(0xFF8E8E93),
    };

/// The branch, as a small chip in the header; nothing outside a work tree.
/// A click offers Refresh and turning Git status off.
class GitBranchChip extends StatelessWidget {
  const GitBranchChip({super.key, required this.git});

  final GitStatusController git;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GitStatus?>(
      valueListenable: git,
      builder: (context, status, _) {
        final label = status?.label;
        if (status == null || label == null) return const SizedBox.shrink();
        final colors = context.colors;
        final text = Theme.of(context).textTheme;
        final changes = status.changeCount;
        final tip = [
          status.branch == null ? 'Detached at $label' : 'Git branch $label',
          if (status.ahead > 0) '${status.ahead} to push',
          if (status.behind > 0) '${status.behind} to pull',
          changes == 0 ? 'nothing changed' : (changes == 1 ? '1 item changed' : '$changes items changed'),
        ].join(' · ');
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Tooltip(
            message: tip,
            child: Builder(
              builder: (anchor) => InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => _menu(anchor),
                child: Container(
                  height: 26,
                  constraints: const BoxConstraints(maxWidth: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: colors.muted.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: colors.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(status.branch == null ? LucideIcons.gitCommitHorizontal : LucideIcons.gitBranch,
                          size: 13, color: colors.mutedForeground),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: colors.foreground, fontWeight: FontWeight.w500),
                        ),
                      ),
                      if (status.ahead > 0 || status.behind > 0) ...[
                        const SizedBox(width: 5),
                        Text(
                          [if (status.ahead > 0) '↑${status.ahead}', if (status.behind > 0) '↓${status.behind}'].join(' '),
                          style: text.bodySmall?.copyWith(color: colors.mutedForeground, fontSize: 11),
                        ),
                      ],
                      if (changes > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(color: gitMarkColor(GitMark.modified), shape: BoxShape.circle),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _menu(BuildContext anchor) async {
    final choice = await ExplorerMenu.show<String>(anchor, items: [
      ExplorerMenu.item(anchor, value: 'refresh', label: 'Refresh Git status', icon: LucideIcons.refreshCw),
      ExplorerMenu.item(anchor, value: 'off', label: 'Turn off Git status', icon: LucideIcons.eyeOff),
    ]);
    switch (choice) {
      case 'refresh':
        git.refresh();
      case 'off':
        await GitStatusSettings.instance.set(false);
    }
  }
}

/// An item's Git mark: a letter for its own change, or a dot for a folder
/// with changes inside. Nothing for unchanged or ignored items.
class GitMarkBadge extends StatelessWidget {
  const GitMarkBadge({super.key, required this.mark, this.inside});

  /// The item's own change.
  final GitMark? mark;

  /// The weightiest change inside a folder.
  final GitMark? inside;

  @override
  Widget build(BuildContext context) {
    final mark = this.mark;
    if (mark != null && mark != GitMark.ignored) {
      final color = gitMarkColor(mark);
      return Tooltip(
        message: mark.label,
        child: Container(
          height: 15,
          padding: const EdgeInsets.symmetric(horizontal: 3.5),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            mark.letter,
            style: TextStyle(fontSize: 10, height: 1.1, fontWeight: FontWeight.w700, color: color),
          ),
        ),
      );
    }
    final inside = this.inside;
    if (inside == null || mark == GitMark.ignored) return const SizedBox.shrink();
    // A dot on the same square as the letters, so it isn't taken for a tag's.
    final color = gitMarkColor(inside);
    return Tooltip(
      message: 'Changes inside',
      child: Container(
        width: 15,
        height: 15,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// Dims what Git ignores, as code editors do.
class GitDim extends StatelessWidget {
  const GitDim({super.key, required this.git, required this.path, required this.child});

  final GitStatusController? git;
  final String path;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final git = this.git;
    if (git == null) return child;
    return ValueListenableBuilder<GitStatus?>(
      valueListenable: git,
      child: child,
      // Always there, so the item isn't built anew when that changes.
      builder: (context, status, child) =>
          Opacity(opacity: status?.markFor(path) == GitMark.ignored ? 0.5 : 1, child: child),
    );
  }
}
