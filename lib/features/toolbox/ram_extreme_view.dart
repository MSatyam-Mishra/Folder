import 'dart:async';
import 'dart:math' as math;

import 'package:explorer/core/services/toolbox/app_closer.dart';
import 'package:explorer/core/services/toolbox/ram_cleaner.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/features/file_explorere/widgets/entity_meta.dart';
import 'package:explorer/shared/widgets/docked_glossy_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What to say after a run, from what's measured afterwards: how many of the
/// apps are stopped now, and how far free memory moved.
String describeClosing({required int asked, required int stopped, required bool cancelled, required int freed}) {
  String apps(int count) => count == 1 ? '1 app' : '$count apps';
  final what = cancelled ? 'Cancelled after closing ${apps(stopped)}.' : 'Closed ${apps(stopped)}.';
  final left = cancelled || stopped >= asked ? '' : " ${apps(asked - stopped)} didn't close, or started again.";
  final memory = freed > 1024 * 1024
      ? ' Free memory went up by ${EntityFormat.size(freed)}.'
      : ' Free memory is about the same.';
  return '$what$left$memory';
}

/// The RAM cleaner's Extreme mode on Android: a gauge, what Play would close,
/// and the lists that decide it. The progress screen during a run is drawn by
/// the Accessibility service, over the pages it works through.
class ExtremeRamView extends StatefulWidget {
  const ExtremeRamView({super.key, required this.header, required this.stats});

  /// The switch between modes, at the top of what scrolls.
  final Widget header;
  final MemoryStats? stats;

  @override
  State<ExtremeRamView> createState() => _ExtremeRamViewState();
}

class _ExtremeRamViewState extends State<ExtremeRamView> {
  ExtremeSettings _settings = const ExtremeSettings();
  List<ClosableApp>? _apps;
  bool? _serviceOn;
  bool _running = false;
  bool _listOpen = true;
  String? _result;
  late final AppLifecycleListener _lifecycle;

  List<ClosableApp> get _targets => AppCloser.appsToClose(_apps ?? const [], _settings);

  bool get _custom => _settings.scope == CloseScope.custom;

  /// The packages on the list being shown.
  Set<String> get _listed => _custom ? _settings.custom : _settings.exceptions;

  @override
  void initState() {
    super.initState();
    // Coming back from Accessibility settings, or from other apps.
    _lifecycle = AppLifecycleListener(onResume: () {
      if (!_running) unawaited(_load());
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    final settings = await ExtremeSettings.load();
    if (mounted) setState(() => _settings = settings);
    await _load();
  }

  Future<void> _load() async {
    final on = await AppCloser.isOn();
    final apps = await AppCloser.apps();
    if (!mounted) return;
    setState(() {
      _serviceOn = on;
      _apps = apps;
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _change(ExtremeSettings settings) {
    setState(() => _settings = settings);
    unawaited(settings.save());
  }

  void _setListed(Set<String> packages) =>
      _change(_custom ? _settings.copyWith(custom: packages) : _settings.copyWith(exceptions: packages));

  Future<void> _run() async {
    final targets = _targets;
    if (targets.isEmpty) {
      setState(() => _result = _custom ? 'None of the apps on your list are launched.' : 'No launched apps to close.');
      return;
    }
    setState(() {
      _running = true;
      _result = null;
    });
    final before = await RamCleaner.read();
    final CloseOutcome outcome;
    try {
      outcome = await AppCloser.close(targets);
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = "The Accessibility service isn't running. Turn it off and on again in Accessibility settings.";
      });
      return;
    }
    // The system takes a moment to count what came back.
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = await RamCleaner.read();
    final apps = await AppCloser.apps();
    if (!mounted) return;
    final stopped = {
      for (final app in apps)
        if (!app.running) app.package,
    };
    setState(() {
      _running = false;
      _apps = apps;
      _result = describeClosing(
        asked: targets.length,
        stopped: targets.where((app) => stopped.contains(app.package)).length,
        cancelled: outcome.cancelled,
        freed: before == null || after == null ? 0 : after.available - before.available,
      );
    });
  }

  Future<void> _pick() async {
    await AppSheet.show<void>(
      context,
      style: SheetStyle.side,
      child: _AppPicker(
        title: _custom ? 'Apps to close' : 'Apps to leave alone',
        apps: _apps ?? const [],
        selected: _listed,
        onChanged: _setListed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final listed = [
      for (final app in _apps ?? const <ClosableApp>[])
        if (_listed.contains(app.package)) app,
    ];
    return Stack(
      children: [
        ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            DockedGlossyTopBar.contentTopInset(context) + 16,
            16,
            MediaQuery.paddingOf(context).bottom + 96,
          ),
          children: [
            widget.header,
            const SizedBox(height: 20),
            Center(child: _Gauge(stats: widget.stats)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _Figure(label: 'Launched apps', value: _apps == null ? '–' : '${_targets.length}')),
                Expanded(
                  child: _Figure(
                    label: 'Free memory',
                    value: widget.stats == null ? '–' : EntityFormat.size(widget.stats!.available),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _KindSwitch(
                    label: 'User apps',
                    value: _settings.userApps,
                    onChanged: _custom ? null : (on) => _change(_settings.copyWith(userApps: on)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _KindSwitch(
                    label: 'System apps',
                    value: _settings.systemApps,
                    onChanged: _custom ? null : (on) => _change(_settings.copyWith(systemApps: on)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_serviceOn == false)
              const _ServiceSetup()
            else
              Center(child: _PlayButton(running: _running, onPressed: _serviceOn == true && !_running ? _run : null)),
            if (_result != null) ...[
              const SizedBox(height: 16),
              Text(_result!, textAlign: TextAlign.center, style: text.bodyMedium),
            ],
            const SizedBox(height: 20),
            SegmentedButton<CloseScope>(
              expandedInsets: EdgeInsets.zero,
              segments: const [
                ButtonSegment(value: CloseScope.all, label: Text('All apps'), icon: Icon(LucideIcons.layoutGrid, size: 16)),
                ButtonSegment(value: CloseScope.custom, label: Text('Custom list'), icon: Icon(LucideIcons.listChecks, size: 16)),
              ],
              selected: {_settings.scope},
              onSelectionChanged: (scope) => _change(_settings.copyWith(scope: scope.first)),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppTheme.surfaceRadius)),
              title: Text('${_custom ? 'Apps to close' : 'Exception list'} (${listed.length})'),
              trailing: Icon(_listOpen ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18),
              onTap: () => setState(() => _listOpen = !_listOpen),
            ),
            if (_listOpen) ...[
              if (listed.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Text(
                    _custom
                        ? 'Add the apps Play should close, with the + button.'
                        : 'Add the apps Play should leave alone, with the + button.',
                    style: text.bodySmall,
                  ),
                ),
              for (final app in listed)
                ListTile(
                  key: ValueKey(app.package),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: _AppIcon(package: app.package),
                  title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(LucideIcons.x, size: 18),
                    tooltip: 'Remove',
                    onPressed: () => _setListed({..._listed}..remove(app.package)),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Text(
              'Force stop closes an app completely: anything unsaved in it is lost, and it gets no messages or alarms '
              'until you open it again. Put the apps you rely on in the Exception list.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
          child: AppFab(
            tooltip: _custom ? 'Add apps to close' : 'Add exceptions',
            icon: LucideIcons.plus,
            onPressed: _pick,
          ),
        ),
      ],
    );
  }
}

/// Memory in use on three quarters of a ring, in the theme's gradient.
class _Gauge extends StatelessWidget {
  const _Gauge({required this.stats});

  final MemoryStats? stats;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final stats = this.stats;
    return SizedBox.square(
      dimension: 220,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: stats?.usedFraction ?? 0),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        builder: (_, fraction, child) => CustomPaint(
          painter: _GaugePainter(
            fraction: fraction,
            track: colors.surfaceContainerHighest,
            gradient: AppTheme.gradientOf(colors.primary),
          ),
          child: child,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                stats == null ? '–' : '${(stats.usedFraction * 100).round()}%',
                style: text.displayMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text('RAM', style: text.titleSmall),
              const SizedBox(height: 2),
              if (stats != null)
                Text('${EntityFormat.size(stats.used)} / ${EntityFormat.size(stats.total)}', style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  const _GaugePainter({required this.fraction, required this.track, required this.gradient});

  final double fraction;
  final Color track;
  final List<Color> gradient;

  static const _sweep = math.pi * 1.5;
  static const _stroke = 14.0;

  // The sweep gradient jumps at its angle 0, and a round cap reaches back past
  // the arc's start: so the arc starts a little after that angle.
  static const _lead = 0.2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - _stroke / 2;
    final rect = Rect.fromCircle(center: Offset.zero, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(math.pi * 0.75 - _lead)
      ..drawArc(rect, _lead, _sweep, false, paint..color = track);
    if (fraction > 0) {
      paint.shader = SweepGradient(
        endAngle: _lead * 2 + _sweep,
        colors: gradient,
      ).createShader(rect);
      canvas.drawArc(rect, _lead, _sweep * fraction, false, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.track != track || old.gradient[0] != gradient[0];
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(value, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(label, style: text.bodySmall),
      ],
    );
  }
}

class _KindSwitch extends StatelessWidget {
  const _KindSwitch({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Opacity(
      opacity: onChanged == null ? 0.5 : 1,
      child: Container(
        padding: const EdgeInsets.only(left: 12, right: 6),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppTheme.surfaceRadius),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.running, required this.onPressed});

  final bool running;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final gradient = AppTheme.gradientOf(Theme.of(context).colorScheme.primary);
    return Tooltip(
      message: 'Close apps',
      child: Opacity(
        opacity: onPressed == null && !running ? 0.5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradient),
            boxShadow: [
              BoxShadow(color: gradient.first.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6)),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox.square(
                dimension: 84,
                child: Center(
                  child: running
                      ? const SizedBox.square(
                          dimension: 28,
                          child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                        )
                      : const Icon(LucideIcons.play, color: Colors.white, size: 36),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Instead of Play, until the service is on: what it is and where to turn it on.
class _ServiceSetup extends StatelessWidget {
  const _ServiceSetup();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppTheme.surfaceRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Turn on the Accessibility service', style: text.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Android gives apps no other way to close others. When you press Play, the service opens the info page of '
            'each app and presses Force stop, as you could by hand. It does nothing at any other time.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: AppCloser.openAccessibility,
            icon: const Icon(LucideIcons.settings, size: 18),
            label: const Text('Open Accessibility settings'),
          ),
          const SizedBox(height: 12),
          Text(
            "If Android says it's a restricted setting: open App info, tap ⋮ at the top, choose Allow restricted "
            'settings, then try again.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: AppCloser.openAppInfo,
            icon: const Icon(LucideIcons.info, size: 18),
            label: const Text('Open App info'),
          ),
        ],
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.package});

  final String package;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 36,
      child: FutureBuilder<Uint8List?>(
        future: AppCloser.icon(package),
        builder: (_, icon) => icon.data == null
            ? Icon(LucideIcons.box, color: Theme.of(context).colorScheme.onSurfaceVariant)
            : Image.memory(icon.data!, gaplessPlayback: true),
      ),
    );
  }
}

/// Ticks apps on or off a list; each tick counts at once.
class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.title, required this.apps, required this.selected, required this.onChanged});

  final String title;
  final List<ClosableApp> apps;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  late final Set<String> _selected = {...widget.selected};
  String _query = '';

  void _toggle(ClosableApp app, bool on) {
    setState(() => on ? _selected.add(app.package) : _selected.remove(app.package));
    widget.onChanged({..._selected});
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final shown = [
      for (final app in widget.apps)
        if (query.isEmpty || app.label.toLowerCase().contains(query)) app,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            hintText: 'Search apps',
            prefixIcon: Icon(LucideIcons.search, size: 18),
            isDense: true,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 8),
        // A phone can have hundreds, and each brings a picture from Android.
        SizedBox(
          height: math.max(240, MediaQuery.sizeOf(context).height * 0.55),
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (_, index) {
              final app = shown[index];
              return CheckboxListTile(
                key: ValueKey(app.package),
                contentPadding: EdgeInsets.zero,
                secondary: _AppIcon(package: app.package),
                title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: app.system ? const Text('System app') : null,
                value: _selected.contains(app.package),
                onChanged: (on) => _toggle(app, on ?? false),
              );
            },
          ),
        ),
      ],
    );
  }
}
