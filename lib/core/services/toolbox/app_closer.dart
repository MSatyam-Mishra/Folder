import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An app the RAM cleaner's Extreme mode can close.
@immutable
class ClosableApp {
  const ClosableApp({required this.package, required this.label, this.system = false, this.running = false});

  final String package;
  final String label;
  final bool system;

  /// Started since it was last stopped.
  final bool running;
}

/// Which apps Play closes: all that are launched, less the exceptions, or only
/// the ones on a list.
enum CloseScope { all, custom }

/// Extreme mode's choices, kept between visits.
@immutable
class ExtremeSettings {
  const ExtremeSettings({
    this.userApps = true,
    this.systemApps = false,
    this.scope = CloseScope.all,
    this.exceptions = const {},
    this.custom = const {},
  });

  final bool userApps;
  final bool systemApps;
  final CloseScope scope;

  /// Never closed, when the scope is [CloseScope.all].
  final Set<String> exceptions;

  /// The only ones closed, when the scope is [CloseScope.custom].
  final Set<String> custom;

  ExtremeSettings copyWith({
    bool? userApps,
    bool? systemApps,
    CloseScope? scope,
    Set<String>? exceptions,
    Set<String>? custom,
  }) =>
      ExtremeSettings(
        userApps: userApps ?? this.userApps,
        systemApps: systemApps ?? this.systemApps,
        scope: scope ?? this.scope,
        exceptions: exceptions ?? this.exceptions,
        custom: custom ?? this.custom,
      );

  static const _userKey = 'ram_extreme_user_apps';
  static const _systemKey = 'ram_extreme_system_apps';
  static const _scopeKey = 'ram_extreme_scope';
  static const _exceptionsKey = 'ram_extreme_exceptions';
  static const _customKey = 'ram_extreme_custom';

  static Future<ExtremeSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ExtremeSettings(
      userApps: prefs.getBool(_userKey) ?? true,
      systemApps: prefs.getBool(_systemKey) ?? false,
      scope: prefs.getString(_scopeKey) == CloseScope.custom.name ? CloseScope.custom : CloseScope.all,
      exceptions: (prefs.getStringList(_exceptionsKey) ?? const []).toSet(),
      custom: (prefs.getStringList(_customKey) ?? const []).toSet(),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_userKey, userApps);
    await prefs.setBool(_systemKey, systemApps);
    await prefs.setString(_scopeKey, scope.name);
    await prefs.setStringList(_exceptionsKey, exceptions.toList());
    await prefs.setStringList(_customKey, custom.toList());
  }
}

/// How a run went, as the service saw it.
@immutable
class CloseOutcome {
  const CloseOutcome({required this.closed, required this.skipped, required this.cancelled});

  final int closed;
  final int skipped;
  final bool cancelled;
}

/// Android's Extreme mode. Since Android 14 no app may close others, so its
/// Accessibility service (AppCloserService.kt) presses Force stop on each app's
/// info page, as the user could by hand, and only during a run they started.
abstract final class AppCloser {
  static const _channel = MethodChannel('explorer/app_closer');
  static final _icons = <String, Future<Uint8List?>>{};

  /// Whether the Accessibility service is on.
  static Future<bool> isOn() async {
    try {
      return await _channel.invokeMethod<bool>('status') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> openAccessibility() => _channel.invokeMethod<void>('openAccessibility');

  /// Where Android 13 and newer want "restricted settings" allowed first, for
  /// an app not from a store.
  static Future<void> openAppInfo() => _channel.invokeMethod<void>('openAppInfo');

  static Future<List<ClosableApp>> apps() async {
    try {
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>('apps') ?? const [];
      return [
        for (final app in list)
          ClosableApp(
            package: app['package']! as String,
            label: app['label']! as String,
            system: app['system'] == true,
            running: app['running'] == true,
          ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<Uint8List?> icon(String package) => _icons[package] ??= _readIcon(package);

  static Future<Uint8List?> _readIcon(String package) async {
    try {
      return await _channel.invokeMethod<Uint8List>('icon', {'package': package});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Answers once the run is over: finished or cancelled. Throws a
  /// [PlatformException] if the service isn't up.
  static Future<CloseOutcome> close(List<ClosableApp> apps) async {
    final answer = await _channel.invokeMapMethod<String, Object?>('close', {
      'apps': [
        for (final app in apps) {'package': app.package, 'label': app.label},
      ],
    });
    return CloseOutcome(
      closed: answer?['closed'] as int? ?? 0,
      skipped: answer?['skipped'] as int? ?? 0,
      cancelled: answer?['cancelled'] == true,
    );
  }

  /// What Play would close. A stopped app has nothing to close. The kind
  /// switches only narrow "all": what's on a custom list was picked by name.
  static List<ClosableApp> appsToClose(List<ClosableApp> apps, ExtremeSettings settings) => [
        for (final app in apps)
          if (app.running &&
              switch (settings.scope) {
                CloseScope.all => !settings.exceptions.contains(app.package) &&
                    (app.system ? settings.systemApps : settings.userApps),
                CloseScope.custom => settings.custom.contains(app.package),
              })
            app,
      ];
}
