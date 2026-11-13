import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What's kept of the panes between runs: whether the preview pane shows
/// and how wide it is (one for every tab and window), and the layout the
/// last browser had, which a window's first tab starts with.
class PaneSettings extends ChangeNotifier {
  PaneSettings._();

  static final instance = PaneSettings._();

  static const double previewUsual = 320;
  static const double previewMin = 240;
  static const double previewMax = 640;

  static const _previewKey = 'preview_pane';
  static const _previewWidthKey = 'preview_pane_width';
  static const _dualKey = 'dual_pane';
  static const _ratioKey = 'dual_pane_ratio';
  static const _secondKey = 'dual_pane_folder';

  /// Whether the preview pane shows (where there's room for it).
  bool get preview => _preview;
  bool _preview = false;

  double get previewWidth => _previewWidth;
  double _previewWidth = previewUsual;

  /// The last browser's layout: two panes, how the room was shared, and the
  /// second pane's folder.
  bool get dual => _dual;
  bool _dual = false;
  double get ratio => _ratio;
  double _ratio = 0.5;
  String? get secondFolder => _secondFolder;
  String? _secondFolder;

  Timer? _saveWidth;
  Timer? _saveLayout;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _preview = prefs.getBool(_previewKey) ?? false;
    _previewWidth = (prefs.getDouble(_previewWidthKey) ?? previewUsual).clamp(previewMin, previewMax);
    _dual = prefs.getBool(_dualKey) ?? false;
    _ratio = (prefs.getDouble(_ratioKey) ?? 0.5).clamp(0.2, 0.8);
    _secondFolder = prefs.getString(_secondKey);
    notifyListeners();
  }

  void setPreview(bool on) {
    if (on == _preview) return;
    _preview = on;
    notifyListeners();
    unawaited(SharedPreferences.getInstance().then((prefs) => prefs.setBool(_previewKey, on)));
  }

  void togglePreview() => setPreview(!_preview);

  /// Sets the width; saved a moment later (a drag sets it many times).
  void setPreviewWidth(double width) {
    final next = width.clamp(previewMin, previewMax).toDouble();
    if (next == _previewWidth) return;
    _previewWidth = next;
    notifyListeners();
    _saveWidth?.cancel();
    _saveWidth = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_previewWidthKey, _previewWidth);
    });
  }

  /// Keeps a browser's layout for the next window (saved a moment later:
  /// a drag of the divider changes it many times).
  void keepLayout({required bool dual, required double ratio, String? secondFolder}) {
    _dual = dual;
    _ratio = ratio;
    if (secondFolder != null) _secondFolder = secondFolder;
    _saveLayout?.cancel();
    _saveLayout = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_dualKey, _dual);
      await prefs.setDouble(_ratioKey, _ratio);
      final folder = _secondFolder;
      if (folder != null) await prefs.setString(_secondKey, folder);
    });
  }

  /// Back to the defaults (tests).
  @visibleForTesting
  void reset() {
    _saveWidth?.cancel();
    _saveLayout?.cancel();
    _preview = false;
    _previewWidth = previewUsual;
    _dual = false;
    _ratio = 0.5;
    _secondFolder = null;
  }
}
