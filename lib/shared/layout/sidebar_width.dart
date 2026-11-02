import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How wide the docked sidebar is: dragged by its border, one width for
/// every tab and window, and kept.
class SidebarWidth extends ValueNotifier<double> {
  SidebarWidth._() : super(usual);

  static final instance = SidebarWidth._();

  static const double usual = 280;
  static const double min = 200;
  static const double max = 480;
  static const _key = 'sidebar_width';

  Timer? _save;

  /// The width last used.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    value = (prefs.getDouble(_key) ?? usual).clamp(min, max);
  }

  /// Sets the width; saved a moment later (a drag sets it many times).
  void set(double width) {
    final next = width.clamp(min, max).toDouble();
    if (next == value) return;
    value = next;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_key, value);
    });
  }
}
