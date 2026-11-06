import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/toolbox/ram_cleaner.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/toolbox/ram_extreme_view.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

/// Memory in use, live, and a button that frees what the system allows. What
/// it says it freed is measured, before and after.
class RamCleanerScreen extends StatefulWidget {
  const RamCleanerScreen({super.key});

  @override
  State<RamCleanerScreen> createState() => _RamCleanerScreenState();
}

class _RamCleanerScreenState extends State<RamCleanerScreen> {
  MemoryStats? _stats;
  bool _canCleanOthers = false;
  bool _cleaning = false;
  String? _result;
  Timer? _timer;

  /// Extreme mode, which only Android has: elsewhere the button already does
  /// what the system allows, and closing programs could lose unsaved work.
  bool _extreme = false;
  static const _modeKey = 'ram_cleaner_extreme';

  bool get _hasExtreme => defaultTargetPlatform == TargetPlatform.android;

  Future<void> _refresh() async {
    final stats = await RamCleaner.read();
    if (mounted) setState(() => _stats = stats);
  }

  Future<void> _clean() async {
    setState(() {
      _cleaning = true;
      _result = null;
    });
    final before = await RamCleaner.read();
    await RamCleaner.clean();
    // The system takes a moment to count what came back.
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = await RamCleaner.read();
    if (!mounted) return;
    final freed = before == null || after == null ? 0 : after.available - before.available;
    setState(() {
      _cleaning = false;
      _stats = after ?? _stats;
      _result = freed > 1024 * 1024
          ? 'Free memory went up by ${EntityFormat.size(freed)}.'
          : 'Memory is about the same: there was nothing more to free right now.';
    });
  }

  /// What the button does here, as each system has its own way.
  String get _limits {
    if (Platform.isWindows) {
      return 'Programs give memory back and take it again as they need it, so they may be a little slower at first.';
    }
    if (Platform.isMacOS) {
      return "This runs macOS's purge, which asks for your password. It empties the disk cache, so things may open a little slower at first.";
    }
    if (Platform.isLinux) {
      return _canCleanOthers
          ? "This drops Linux's file cache, which asks for your password. Programs keep their memory, and things may open a little slower at first."
          : 'Linux frees memory by itself when something needs it. This clears what Folders holds; dropping the file cache needs pkexec.';
    }
    return _canCleanOthers
        ? 'Background apps are closed. Android may start some of them again.'
        : "Android 14 and newer don't let any app close other apps, so this clears what Folders itself holds. "
            'Android frees the rest by itself when something needs it, and Extreme mode closes apps through an '
            'Accessibility service.';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    RamCleaner.canCleanOthers().then((can) {
      if (mounted) setState(() => _canCleanOthers = can);
    });
    if (_hasExtreme) {
      SharedPreferences.getInstance().then((prefs) {
        if (mounted) setState(() => _extreme = prefs.getBool(_modeKey) ?? false);
      });
    }
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_cleaning) _refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _modeSwitch() => SegmentedButton<bool>(
        expandedInsets: EdgeInsets.zero,
        segments: const [
          ButtonSegment(value: false, label: Text('Normal'), icon: Icon(LucideIcons.eraser, size: 16)),
          ButtonSegment(value: true, label: Text('Extreme'), icon: Icon(LucideIcons.zap, size: 16)),
        ],
        selected: {_extreme},
        onSelectionChanged: (mode) {
          setState(() => _extreme = mode.first);
          SharedPreferences.getInstance().then((prefs) => prefs.setBool(_modeKey, mode.first));
        },
      );

  Widget _figure(String label, int bytes) {
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(EntityFormat.size(bytes), style: text.titleMedium),
          const SizedBox(height: 2),
          Text(label, style: text.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final stats = _stats;
    return ExplorerScaffold(
      title: 'RAM cleaner',
      body: _extreme
          ? ExtremeRamView(header: _modeSwitch(), stats: stats)
          : ListView(
        padding: EdgeInsets.fromLTRB(24, DockedGlossyTopBar.contentTopInset(context) + (_hasExtreme ? 16 : 32), 24, 32),
        children: [
          if (_hasExtreme) ...[_modeSwitch(), const SizedBox(height: 24)],
          Center(
            child: SizedBox.square(
              dimension: 190,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: stats?.usedFraction,
                    strokeWidth: 12,
                    strokeCap: StrokeCap.round,
                    backgroundColor: colors.muted,
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          stats == null ? '–' : '${(stats.usedFraction * 100).round()}%',
                          style: text.displaySmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text('in use', style: text.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          if (stats != null)
            Row(
              children: [
                _figure('Used', stats.used),
                _figure('Free', stats.available),
                _figure('Total', stats.total),
              ],
            ),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: _cleaning ? null : _clean,
            icon: _cleaning
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(LucideIcons.eraser, size: 18),
            label: Text(_cleaning ? 'Cleaning…' : 'Clean RAM'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            Text(_result!, textAlign: TextAlign.center, style: text.bodyMedium),
          ],
          const SizedBox(height: 20),
          Text(_limits, textAlign: TextAlign.center, style: text.bodySmall),
        ],
      ),
    );
  }
}
