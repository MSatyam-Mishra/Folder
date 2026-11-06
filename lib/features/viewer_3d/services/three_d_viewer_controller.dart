import 'dart:convert';

import 'package:folders/features/viewer_3d/models/viewer_3d_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Result of a screenshot request: a PNG data URL or an error.
typedef ScreenshotCallback = void Function(String? dataUrl, String? error);

/// Holds the state of the three.js viewer page and sends commands to it.
///
/// The page posts JSON messages through the `viewer3d` JavaScript handler
/// (see `assets/viewer3d/index.html`); [handleMessage] applies them here.
/// Commands go back through `window.viewer.command(name, arg)`.
class ThreeDViewerController extends ChangeNotifier {
  ThreeDViewerController({ViewerBackground background = ViewerBackground.dark})
      : _background = background;

  /// Name of the JavaScript handler the page posts to.
  static const handlerName = 'viewer3d';

  InAppWebViewController? _web;
  bool _disposed = false;

  /// Called when the page delivers a screenshot.
  ScreenshotCallback? onScreenshot;

  /// Called once the model has loaded (e.g. to surface warnings).
  VoidCallback? onLoaded;

  ViewerPhase _phase = ViewerPhase.preparing;
  double? _progress;
  String _progressLabel = 'Preparing viewer';
  String? _errorMessage;
  String? _errorDetail;
  String? _errorCode;

  ModelStats? _stats;
  List<String> _warnings = const [];
  List<AnimationClipInfo> _clips = const [];
  int _animationIndex = -2;
  bool _animationPlaying = false;

  bool _autoRotate = false;
  bool _wireframe = false;
  bool _grid = true;
  bool _axes = false;
  bool _zUp = false;
  bool _hasPoints = false;
  bool _hasMeshes = true;
  double _pointScale = 1;
  ViewerBackground _background;
  ViewerShading _shading = ViewerShading.original;

  ViewerPhase get phase => _phase;
  bool get isReady => _phase == ViewerPhase.ready;

  /// 0..1, or null when indeterminate.
  double? get progress => _progress;
  String get progressLabel => _progressLabel;
  String? get errorMessage => _errorMessage;
  String? get errorDetail => _errorDetail;
  String? get errorCode => _errorCode;

  /// Errors that may go away when the page is reloaded.
  bool get canRetry => const {
        'context_lost',
        'render_process_gone',
        'startup',
        'page_load',
      }.contains(_errorCode);

  ModelStats? get stats => _stats;
  List<String> get warnings => _warnings;
  List<AnimationClipInfo> get clips => _clips;

  /// -2: none, -1: all clips together, >= 0: index into [clips].
  int get animationIndex => _animationIndex;
  bool get animationPlaying => _animationPlaying;

  bool get autoRotate => _autoRotate;
  bool get wireframe => _wireframe;
  bool get grid => _grid;
  bool get axes => _axes;
  bool get zUp => _zUp;
  bool get hasPoints => _hasPoints;
  bool get hasMeshes => _hasMeshes;
  double get pointScale => _pointScale;
  ViewerBackground get background => _background;
  ViewerShading get shading => _shading;

  /// Attaches a freshly created web view and resets the load state.
  void attach(InAppWebViewController web) {
    _web = web;
    _phase = ViewerPhase.loading;
    _progress = null;
    _progressLabel = 'Starting 3D engine';
    _errorMessage = null;
    _errorDetail = null;
    _errorCode = null;
    // A new page only knows the inset in its URL ([initialTopInset]).
    _sentTopInset = null;
    _notify();
  }

  void detach() => _web = null;

  /// Puts the viewer into the error state (used for Flutter-side failures).
  void fail(String message, {String? detail, String? code}) {
    // The screen drops the web view in the error state.
    _web = null;
    _phase = ViewerPhase.error;
    _errorMessage = message;
    _errorDetail = detail;
    _errorCode = code;
    _notify();
  }

  /// Back to "preparing" before the page is (re)created.
  void resetForReload() {
    _web = null;
    _phase = ViewerPhase.preparing;
    _progress = null;
    _progressLabel = 'Preparing viewer';
    _errorMessage = null;
    _errorDetail = null;
    _errorCode = null;
    _stats = null;
    _warnings = const [];
    _clips = const [];
    _animationIndex = -2;
    _animationPlaying = false;
    // The reloaded page starts from its URL's inset; resend the live one.
    _sentTopInset = null;
    _notify();
  }

  /// Applies one message posted by the page.
  void handleMessage(Object? raw) {
    if (_disposed || raw is! Map) return;
    final msg = Map<String, dynamic>.from(raw);
    switch (msg['type']) {
      case 'progress':
        if (_phase == ViewerPhase.ready || _phase == ViewerPhase.error) return;
        _phase = ViewerPhase.loading;
        final fraction = msg['fraction'];
        _progress = fraction is num ? fraction.toDouble().clamp(0.0, 1.0) : null;
        _progressLabel = msg['label']?.toString() ?? 'Loading';
        _notify();
      case 'loaded':
        _phase = ViewerPhase.ready;
        _progress = 1;
        _readStats(msg);
        _readAnimationState(msg['animationIndex'], msg['animationPlaying']);
        final clips = msg['animations'];
        _clips = clips is List
            ? [
                for (final c in clips)
                  if (c is Map) AnimationClipInfo.fromJson(Map<String, dynamic>.from(c)),
              ]
            : const [];
        _readState(msg['state']);
        _notify();
        onLoaded?.call();
      case 'stats':
        _readStats(msg);
        _notify();
      case 'state':
        _readState(msg['state']);
        _notify();
      case 'animation':
        _readAnimationState(msg['index'], msg['playing']);
        _notify();
      case 'error':
        // A late error (e.g. lost GPU context) also replaces the view.
        fail(
          msg['message']?.toString() ?? 'The model could not be displayed.',
          detail: msg['detail']?.toString(),
          code: msg['code']?.toString(),
        );
      case 'screenshot':
        onScreenshot?.call(msg['dataUrl'] as String?, msg['error']?.toString());
      case 'log':
        debugPrint('3D viewer: ${msg['level']}: ${msg['message']}');
    }
  }

  void _readStats(Map<String, dynamic> msg) {
    final stats = msg['stats'];
    if (stats is Map) _stats = ModelStats.fromJson(Map<String, dynamic>.from(stats));
    final warnings = msg['warnings'];
    if (warnings is List) _warnings = [for (final w in warnings) w.toString()];
  }

  void _readAnimationState(Object? index, Object? playing) {
    if (index is num) _animationIndex = index.toInt();
    if (playing is bool) _animationPlaying = playing;
  }

  void _readState(Object? raw) {
    if (raw is! Map) return;
    final s = Map<String, dynamic>.from(raw);
    _autoRotate = s['autoRotate'] == true;
    _wireframe = s['wireframe'] == true;
    _grid = s['grid'] != false;
    _axes = s['axes'] == true;
    _zUp = s['zUp'] == true;
    _hasPoints = s['hasPoints'] == true;
    _hasMeshes = s['hasMeshes'] != false;
    final scale = s['pointScale'];
    if (scale is num) _pointScale = scale.toDouble();
    _background = ViewerBackground.fromId(s['background']);
    _shading = ViewerShading.fromId(s['shading']);
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  void resetView() => _send('resetView');

  void setAutoRotate(bool value) {
    _autoRotate = value;
    _notify();
    _send('setAutoRotate', value);
  }

  void setWireframe(bool value) {
    _wireframe = value;
    _notify();
    _send('setWireframe', value);
  }

  void setGrid(bool value) {
    _grid = value;
    _notify();
    _send('setGrid', value);
  }

  void setAxes(bool value) {
    _axes = value;
    _notify();
    _send('setAxes', value);
  }

  void setZUp(bool value) {
    _zUp = value;
    _notify();
    _send('setZUp', value);
  }

  void setBackground(ViewerBackground value) {
    _background = value;
    _notify();
    _send('setBackground', value.id);
  }

  void setShading(ViewerShading value) {
    _shading = value;
    _notify();
    _send('setShading', value.id);
  }

  /// Point-cloud point size multiplier (0.1–10).
  void setPointScale(double value) {
    _pointScale = value;
    _notify();
    _send('setPointSize', value);
  }

  /// Plays clip [index], or every clip together when [index] is -1.
  void playAnimation(int index) {
    _animationIndex = index;
    _animationPlaying = true;
    _notify();
    _send('playAnimation', index);
  }

  void toggleAnimation() {
    if (_clips.isEmpty) return;
    if (_animationIndex == -2) {
      playAnimation(0);
      return;
    }
    _animationPlaying = !_animationPlaying;
    _notify();
    _send(_animationPlaying ? 'resumeAnimation' : 'pauseAnimation');
  }

  void stopAnimation() {
    _animationIndex = -2;
    _animationPlaying = false;
    _notify();
    _send('stopAnimation');
  }

  /// Asks the page for a PNG; the result arrives via [onScreenshot].
  void requestScreenshot() => _send('screenshot');

  double? _sentTopInset;

  /// Tells the page how much of the canvas the floating top bar covers so
  /// models are framed in the visible area. Only sends real changes.
  void updateTopInset(double inset) {
    if (_web == null || !isReady) return;
    if (_sentTopInset != null && (_sentTopInset! - inset).abs() < 0.5) return;
    _sentTopInset = inset;
    _send('setInsets', {'top': inset});
  }

  /// Records the inset already passed to the page in its URL.
  void initialTopInset(double inset) => _sentTopInset = inset;

  Future<void> _send(String name, [Object? arg]) async {
    final web = _web;
    if (web == null || _disposed) return;
    final source =
        'window.viewer && window.viewer.command(${jsonEncode(name)}, ${jsonEncode(arg)});';
    try {
      await web.evaluateJavascript(source: source);
    } catch (e) {
      debugPrint('3D viewer: command $name failed: $e');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _web = null;
    onScreenshot = null;
    onLoaded = null;
    super.dispose();
  }
}
