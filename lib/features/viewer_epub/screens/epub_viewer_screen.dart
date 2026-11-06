import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:folders/core/services/bookmark_service.dart';
import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../book/book_models.dart';
import '../book/book_source.dart';
import '../book/document_preparer.dart';
import '../reader/reader_session.dart';
import '../reader/reader_settings.dart';
import '../widgets/reader_controls.dart';
import '../widgets/reader_search_sheet.dart';
import '../widgets/reader_settings_sheet.dart';
import '../widgets/reader_side_panel.dart';

/// E-book reader for EPUB 2/3, FB2 (`.fb2`, `.fb2.zip`, `.fbz`) and
/// MOBI/AZW/AZW3/PRC (best effort). The format is detected from the file
/// content, falling back to the extension.
class EpubViewerScreen extends StatefulWidget {
  final File epubFile;
  const EpubViewerScreen({super.key, required this.epubFile});

  @override
  State<EpubViewerScreen> createState() => _EpubViewerScreenState();
}

class _EpubViewerScreenState extends State<EpubViewerScreen> {
  final BookmarkService _bookmarkService = BookmarkService();
  final ReaderSearchController _search = ReaderSearchController();
  final FocusNode _focus = FocusNode(debugLabel: 'ebook-reader');

  BookSource? _source;
  ReaderSession? _session;
  InAppWebViewController? _web;
  int _webGeneration = 0;

  bool _opening = true;
  String? _error;
  bool _retryable = false;

  ReaderSettings _settings = ReaderSettings.lastKnown ?? const ReaderSettings();

  /// The app's brightness, which the "Auto" reader theme follows.
  Brightness _brightness = Brightness.light;

  /// [_settings] with the "Auto" theme resolved: what the page shows.
  ReaderSettings get _effective => _settings.resolved(_brightness);

  /// A load requested while the WebView didn't exist yet (it is created by
  /// the first build, concurrently with opening the book, and recreated
  /// after a renderer crash): `(spine index, target)`.
  (int, Map<String, dynamic>)? _pending;

  /// Renderer crashes of the same section with no successful load since.
  int _crashSpine = -1;
  int _crashes = 0;

  /// The first page has been shown (deferred work may start).
  bool _shownOnce = false;

  int _spine = 0;
  int _page = 0;
  int _pages = 1;
  double _fraction = 0;
  Map<String, int> _anchorPages = const {};
  bool _docLoading = true;
  String? _docError;

  int _loadId = 0;
  String? _expectedUrl;
  Map<String, dynamic> _lastTarget = const {'type': 'start'};

  bool _controlsVisible = false;
  bool? _panelPreference;
  double? _scrubValue;

  List<Bookmark> _bookmarks = const [];
  Uint8List? _cover;
  List<int> _cumulative = const [0, 1];

  Map<String, dynamic>? _hinge;
  String _hingeKey = '';

  Timer? _saveTimer;
  Timer? _readyTimer;

  String get _path => widget.epubFile.path;
  BookInfo? get _info => _source?.info;

  /// The file name without its e-book extension, shown until the book's
  /// own title is known.
  String get _fileTitle => widget.epubFile.uri.pathSegments.last.replaceFirst(
        RegExp(
          r'\.(epub|kepub|fb2(\.zip)?|fbz|mobi|azw3?|prc|pdb|kf8)$',
          caseSensitive: false,
        ),
        '',
      );

  static bool get _platformSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (brightness == _brightness) return;
    final before = _effective;
    _brightness = brightness;
    // The app switched light/dark while an "Auto" themed page is open.
    if (_effective != before && _web != null && !_docLoading) {
      _js('window.ER && ER.applySettings(${jsonEncode(_effective.toJs())})');
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _readyTimer?.cancel();
    _savePosition();
    _session?.dispose();
    final source = _source;
    if (source != null) {
      unawaited(source.saveCache());
      unawaited(source.dispose());
    }
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ opening

  Future<void> _open({bool retry = false}) async {
    if (!_platformSupported) {
      _opening = false;
      _error = "The e-book reader isn't available on this platform.";
      _retryable = false;
      if (retry) setState(() {});
      return;
    }
    if (retry) {
      _session?.dispose();
      final old = _source;
      if (old != null) unawaited(old.dispose());
      _session = null;
      _source = null;
      _web = null;
      _pending = null;
      _shownOnce = false;
      _loadId++;
      setState(() {
        _opening = true;
        _error = null;
        _docError = null;
        _docLoading = true;
        _cover = null;
      });
    }

    // Nothing here waits for anything it doesn't need: the WebView is
    // already being created by the first build (behind the loading page),
    // and the book is parsed (or restored from the structure cache) while
    // settings and bookmarks load alongside.
    final settingsFuture = ReaderSettings.load();
    final savedFuture = _readSaved();
    unawaited(settingsFuture.then((s) {
      if (mounted && _session == null && s != _settings) {
        setState(() => _settings = s);
      }
    }));
    try {
      final source = await BookSource.open(
        widget.epubFile,
        cacheDir: ReaderSession.cacheDirectory(),
      );
      if (!mounted) {
        unawaited(source.dispose());
        return;
      }
      final session = ReaderSession(source);
      final mounting = session.start();
      final (saved, bookmarks) = await savedFuture;
      final info = source.info;
      final start = ReaderPosition.fromSaved(saved, info) ??
          ReaderPosition(_firstLinear(info), 0);
      // The first page is prepared while the server mount, the settings and
      // the WebView finish; _openSpine below joins this work.
      session.prepare(start.spine).ignore();
      final ReaderSettings settings;
      try {
        await mounting;
        settings = await settingsFuture;
      } catch (_) {
        session.dispose();
        unawaited(source.dispose());
        rethrow;
      }
      if (!mounted) {
        session.dispose();
        unawaited(source.dispose());
        return;
      }

      final cumulative = <int>[0];
      var total = 0;
      for (final s in info.spine) {
        total += math.max(1, s.size);
        cumulative.add(total);
      }

      setState(() {
        _source = source;
        _session = session;
        _settings = settings;
        _bookmarks = bookmarks;
        _cumulative = cumulative;
        _spine = start.spine;
        _fraction = start.progress;
        _page = 0;
        _pages = 1;
        _docLoading = true;
        _opening = false;
      });
      _openSpine(start.spine, {'type': 'fraction', 'value': start.progress});
    } on BookOpenException catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = e.message;
        _retryable = e.retryable;
      });
    } catch (e, st) {
      debugPrint('EPUB reader: open failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = "Couldn't open this book. It may be damaged or in an "
            'unsupported format.';
        _retryable = true;
      });
    }
  }

  int _firstLinear(BookInfo info) {
    final i = info.spine.indexWhere((s) => s.linear);
    return i < 0 ? 0 : i;
  }

  /// Saved position and bookmarks; never throws.
  Future<(dynamic, List<Bookmark>)> _readSaved() async {
    try {
      final r = await Future.wait<dynamic>([
        _bookmarkService.getLastReadPosition(_path),
        _bookmarkService.getBookmarks(_path),
      ]);
      return (r[0], r[1] as List<Bookmark>);
    } catch (e) {
      debugPrint('EPUB reader: could not read saved position: $e');
      return (null, const <Bookmark>[]);
    }
  }

  /// Loads [_pending] once both the book and the WebView are ready.
  void _startIfReady() {
    final pending = _pending;
    if (pending == null || _web == null || _session == null) return;
    _pending = null;
    _openSpine(pending.$1, pending.$2);
  }

  /// Work the first page doesn't need waits until it is on screen.
  void _onFirstPageShown() {
    if (_shownOnce) return;
    _shownOnce = true;
    final source = _source;
    Timer(const Duration(milliseconds: 600), () {
      if (!mounted || !identical(source, _source)) return;
      _loadCover();
      unawaited(source?.saveCache());
    });
  }

  Future<void> _loadCover() async {
    final source = _source;
    final path = source?.info.metadata.coverPath;
    if (source == null || path == null) return;
    try {
      final bytes = await source.readResource(path);
      if (mounted && bytes != null && identical(source, _source)) {
        setState(() => _cover = bytes);
      }
    } catch (_) {
      // The header falls back to a placeholder.
    }
  }

  // ------------------------------------------------------- navigation

  Future<void> _openSpine(int index, Map<String, dynamic> target) async {
    final session = _session;
    final info = _info;
    if (session == null || info == null) return;
    index = index.clamp(0, info.spine.length - 1);
    final loadId = ++_loadId;
    _lastTarget = target;
    _pending = null;
    _readyTimer?.cancel();
    setState(() {
      _spine = index;
      _docLoading = true;
      _docError = null;
      _anchorPages = const {};
      _page = 0;
      _pages = 1;
      final value = target['value'];
      _fraction = target['type'] == 'fraction' && value is num
          ? value.toDouble()
          : 0;
    });

    PreparedDocument doc;
    try {
      doc = await session.prepare(index);
    } on BookOpenException catch (e) {
      if (mounted && loadId == _loadId) {
        setState(() {
          _docLoading = false;
          _docError = e.message;
        });
      }
      return;
    } catch (e) {
      debugPrint('EPUB reader: preparing section $index failed: $e');
      if (mounted && loadId == _loadId) {
        setState(() {
          _docLoading = false;
          _docError = 'This section could not be displayed.';
        });
      }
      return;
    }
    if (!mounted || loadId != _loadId || !identical(session, _session)) return;
    final web = _web;
    if (web == null) {
      // The WebView is still starting (or restarting after a crash): it
      // loads this as soon as it exists.
      _pending = (index, target);
      return;
    }

    session.configJson =
        ReaderSession.encodeConfig(_configFor(index, loadId, target));
    final url = session.documentUrl(index, doc).toString();
    _expectedUrl = url;
    _readyTimer = Timer(const Duration(seconds: 10), () => _onReadyTimeout(loadId));
    try {
      await web.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    } catch (e) {
      debugPrint('EPUB reader: loadUrl failed: $e');
      if (mounted && loadId == _loadId) {
        setState(() {
          _docLoading = false;
          _docError = 'This section could not be loaded.';
        });
      }
    }
  }

  Map<String, dynamic> _configFor(
    int index,
    int loadId,
    Map<String, dynamic> target,
  ) {
    final info = _info!;
    return {
      'loadId': loadId,
      'target': target,
      'anchors': _anchorsFor(index),
      'dir': info.metadata.rtl ? 'rtl' : 'auto',
      'fixed': info.spine[index].fixedLayout,
      'settings': _effective.toJs(),
      'hinge': _hinge,
      'hasPrev': _adjacent(index, -1) != null,
      'hasNext': _adjacent(index, 1) != null,
    };
  }

  List<String> _anchorsFor(int index) => {
        for (final f in _info!.flatToc)
          if (f.entry.spineIndex == index && f.entry.fragment != null)
            f.entry.fragment!,
      }.toList();

  /// Next/previous spine item in reading order, skipping non-linear items.
  int? _adjacent(int index, int dir) {
    final spine = _info?.spine;
    if (spine == null) return null;
    for (var j = index + dir; j >= 0 && j < spine.length; j += dir) {
      if (spine[j].linear) return j;
    }
    final j = index + dir;
    if (!spine[index].linear && j >= 0 && j < spine.length) return j;
    return null;
  }

  void _goTo(int index, String? fragment) {
    if (index == _spine && !_docLoading && _docError == null) {
      if (fragment != null) {
        _js('ER.goToFragment(${jsonEncode(fragment)})');
      } else {
        _js('ER.goToStart()');
      }
      return;
    }
    _openSpine(
      index,
      fragment != null
          ? {'type': 'fragment', 'id': fragment}
          : const {'type': 'start'},
    );
  }

  void _goToPosition(int spine, double fraction) {
    if (spine == _spine && !_docLoading && _docError == null) {
      _js('ER.goToFraction($fraction)');
    } else {
      _openSpine(spine, {'type': 'fraction', 'value': fraction});
    }
  }

  void _next() {
    if (_docError != null) return _onEdge(1);
    if (!_docLoading) _js('ER.next()');
  }

  void _prev() {
    if (_docError != null) return _onEdge(-1);
    if (!_docLoading) _js('ER.prev()');
  }

  void _onEdge(int dir) {
    final target = _adjacent(_spine, dir);
    if (target == null) {
      _snack(dir > 0
          ? "You've reached the end of the book."
          : 'This is the beginning of the book.');
      return;
    }
    _openSpine(target, {'type': dir > 0 ? 'start' : 'end'});
  }

  void _prefetchNext() {
    final session = _session;
    final next = _adjacent(_spine, 1);
    if (session == null || next == null) return;
    session.prepare(next).then((_) {}, onError: (_) {});
  }

  // ---------------------------------------------------- web view glue

  Future<dynamic> _js(String source) async {
    final web = _web;
    if (web == null) return null;
    try {
      return await web.evaluateJavascript(source: source);
    } catch (e) {
      debugPrint('EPUB reader: JS failed: $e');
      return null;
    }
  }

  static String _stripFragment(String url) {
    final i = url.indexOf('#');
    var s = i < 0 ? url : url.substring(0, i);
    try {
      s = Uri.decodeFull(s);
    } catch (_) {}
    return s;
  }

  dynamic _onJsMessage(List<dynamic> args) {
    if (!mounted || args.isEmpty) return null;
    final type = '${args[0]}';
    var data = const <String, dynamic>{};
    if (args.length > 1) {
      try {
        final raw = args[1];
        final decoded = raw is String ? jsonDecode(raw) : raw;
        if (decoded is Map) data = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    if (type == 'log') {
      debugPrint('EPUB reader JS: ${data['message']} ${data['source'] ?? ''}');
      return null;
    }
    final id = data['loadId'];
    if (id is num && id.toInt() != _loadId) return null;
    switch (type) {
      case 'ready':
      case 'layout':
      case 'relocated':
        _applyState(data, ready: type == 'ready');
      case 'toggleControls':
        setState(() => _controlsVisible = !_controlsVisible);
      case 'edge':
        _onEdge((data['dir'] as num?)?.toInt() ?? 1);
      case 'link':
        final href = data['href'];
        if (href is String) _onLink(href);
      case 'parseError':
        if (_session?.forceHtml(_spine) ?? false) {
          _openSpine(_spine, _lastTarget);
        }
    }
    return null;
  }

  void _applyState(Map<String, dynamic> d, {bool ready = false}) {
    final pages = math.max(1, (d['pages'] as num?)?.toInt() ?? _pages);
    final page = ((d['page'] as num?)?.toInt() ?? _page).clamp(0, pages - 1);
    final fraction =
        ((d['fraction'] as num?)?.toDouble() ?? _fraction).clamp(0.0, 1.0);
    final anchors = d['anchors'];
    final wasLoading = _docLoading;
    setState(() {
      _pages = pages;
      _page = page;
      _fraction = fraction;
      if (anchors is Map) {
        _anchorPages = {
          for (final e in anchors.entries)
            if (e.value is num) '${e.key}': (e.value as num).toInt(),
        };
      }
      _docLoading = false;
      // The current load reported in, so any error shown was stale (e.g. a
      // superseded navigation of the same URL).
      _docError = null;
    });
    if (ready) _crashes = 0;
    if (wasLoading) {
      _readyTimer?.cancel();
      _prefetchNext();
      _onFirstPageShown();
    }
    _scheduleSave();
  }

  Future<void> _onLoadStop(InAppWebViewController c, WebUri? url) async {
    final expected = _expectedUrl;
    if (url == null || expected == null) return;
    if (_stripFragment(url.toString()) != _stripFragment(expected)) return;
    final loadId = _loadId;
    dynamic result;
    try {
      result = await c.evaluateJavascript(
        source: 'window.ER ? ER.state() : "__no_reader__"',
      );
    } catch (_) {
      return;
    }
    if (!mounted || loadId != _loadId) return;
    if (result == '__no_reader__') {
      // An XHTML parse error stops scripts; retry with the HTML parser.
      if (_session?.forceHtml(_spine) ?? false) {
        _openSpine(_spine, _lastTarget);
      } else if (_docLoading) {
        setState(() => _docLoading = false);
      }
      return;
    }
    if (result is String && _docLoading) {
      try {
        final d = jsonDecode(result);
        if (d is Map && d['ready'] == true) {
          _applyState(Map<String, dynamic>.from(d), ready: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _onReadyTimeout(int loadId) async {
    if (!mounted || loadId != _loadId || !_docLoading) return;
    final result = await _js('window.ER ? ER.state() : null');
    if (!mounted || loadId != _loadId || !_docLoading) return;
    if (result is String) {
      try {
        final d = jsonDecode(result);
        if (d is Map) {
          _applyState(Map<String, dynamic>.from(d), ready: true);
          return;
        }
      } catch (_) {}
    }
    setState(() => _docLoading = false);
  }

  Future<NavigationActionPolicy?> _shouldOverride(
    InAppWebViewController c,
    NavigationAction action,
  ) async {
    final url = action.request.url?.toString();
    if (url == null || !action.isForMainFrame) {
      return NavigationActionPolicy.ALLOW;
    }
    if (url == 'about:blank' || url.startsWith('data:')) {
      return NavigationActionPolicy.ALLOW;
    }
    final expected = _expectedUrl;
    if (expected != null && _stripFragment(url) == _stripFragment(expected)) {
      return NavigationActionPolicy.ALLOW;
    }
    _onLink(url);
    return NavigationActionPolicy.CANCEL;
  }

  void _onLink(String href) {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    final resolved = _session?.resolveBookUrl(uri);
    if (resolved != null) {
      final (index, _, fragment) = resolved;
      if (index == null) {
        _snack("This link points to a part of the book that isn't in the "
            'reading order.');
        return;
      }
      _goTo(index, fragment);
      return;
    }
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      _confirmExternalLink(href);
      return;
    }
    Clipboard.setData(ClipboardData(text: href));
    _snack('Link copied to clipboard: $href');
  }

  Future<void> _confirmExternalLink(String href) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open external link?'),
        content: SelectableText(
          href,
          style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
            color: ctx.colors.mutedForeground,
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            icon: const Icon(LucideIcons.copy, size: 16),
            label: const Text('Copy'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'open'),
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('Open'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'open') {
      try {
        await InAppBrowser.openWithSystemBrowser(url: WebUri(href));
        return;
      } catch (e) {
        debugPrint('EPUB reader: could not open browser: $e');
      }
    }
    await Clipboard.setData(ClipboardData(text: href));
    if (mounted) _snack('Link copied to clipboard');
  }

  // ---------------------------------------------------------- position

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), _savePosition);
  }

  void _savePosition() {
    if (_source == null || _docLoading || _docError != null) return;
    final position = ReaderPosition(_spine, _fraction).toJson();
    _bookmarkService
        .saveLastReadPosition(_path, position)
        .catchError((Object e) => debugPrint('EPUB reader: save failed: $e'));
  }

  double _overall(int spine, double fraction) {
    if (_cumulative.length < 2) return 0;
    final s = spine.clamp(0, _cumulative.length - 2);
    final size = _cumulative[s + 1] - _cumulative[s];
    return ((_cumulative[s] + fraction * size) / _cumulative.last)
        .clamp(0.0, 1.0);
  }

  (int, double) _fromOverall(double value) {
    final last = _cumulative.length - 2;
    final target = value.clamp(0.0, 1.0) * _cumulative.last;
    for (var s = 0; s <= last; s++) {
      if (target < _cumulative[s + 1] || s == last) {
        final size = math.max(1, _cumulative[s + 1] - _cumulative[s]);
        return (s, ((target - _cumulative[s]) / size).clamp(0.0, 0.999));
      }
    }
    return (0, 0);
  }

  double get _displayOverall =>
      _overall(_spine, _pages > 0 ? (_page + 1) / _pages : _fraction);

  FlatTocEntry? _currentTocEntry() {
    final info = _info;
    if (info == null) return null;
    FlatTocEntry? best;
    var bestSpine = -1;
    var bestPage = -1;
    for (final f in info.flatToc) {
      final s = f.entry.spineIndex;
      if (s == null || s > _spine) continue;
      var page = 0;
      final frag = f.entry.fragment;
      if (s == _spine && frag != null) {
        final p = _anchorPages[frag];
        if (p == null || p > _page) continue;
        page = p;
      }
      if (s > bestSpine || (s == bestSpine && page >= bestPage)) {
        best = f;
        bestSpine = s;
        bestPage = page;
      }
    }
    return best;
  }

  String _titleForSpine(int index) {
    final info = _info;
    if (info == null) return '';
    FlatTocEntry? before;
    for (final f in info.flatToc) {
      final s = f.entry.spineIndex;
      if (s == index) return f.entry.title;
      if (s != null && s < index) before = f;
    }
    final own = info.spine[index].title;
    if (own != null) return own;
    return before?.entry.title ?? 'Section ${index + 1}';
  }

  String get _chapterTitle {
    if (_info == null) return '';
    return _currentTocEntry()?.entry.title ?? _titleForSpine(_spine);
  }

  // --------------------------------------------------------- bookmarks

  Bookmark? _currentBookmark() {
    final info = _info;
    if (info == null || _docLoading) return null;
    for (final b in _bookmarks) {
      final p = ReaderPosition.fromSaved(b.position, info);
      if (p == null || p.spine != _spine) continue;
      // Same tolerance as the page script's goToFraction (older saves were
      // rounded to 5 decimals).
      final page = (p.progress * _pages + 0.01).floor().clamp(0, _pages - 1);
      if (page == _page) return b;
    }
    return null;
  }

  Future<void> _reloadBookmarks() async {
    try {
      final list = await _bookmarkService.getBookmarks(_path);
      if (mounted) setState(() => _bookmarks = list);
    } catch (_) {}
  }

  Future<void> _toggleBookmark() async {
    final existing = _currentBookmark();
    try {
      if (existing != null) {
        await _bookmarkService.removeBookmark(_path, existing.id);
        if (mounted) _snack('Bookmark removed');
      } else {
        final label =
            '$_chapterTitle · ${(_displayOverall * 100).round()}%';
        final position = ReaderPosition(_spine, _fraction).toJson();
        // Saving first guarantees BookmarkService has a growable record
        // (a brand-new book starts with an unmodifiable empty list).
        await _bookmarkService.saveLastReadPosition(_path, position);
        await _bookmarkService.addBookmark(_path, position, label);
        if (mounted) _snack('Bookmarked "$label"');
      }
    } catch (e) {
      if (mounted) _snack("Couldn't update bookmarks: $e");
    }
    await _reloadBookmarks();
  }

  void _goToBookmark(Bookmark b) {
    final info = _info;
    if (info == null) return;
    final p = ReaderPosition.fromSaved(b.position, info);
    if (p == null) {
      _snack("This bookmark's position can't be found in the book.");
      return;
    }
    _goToPosition(p.spine, p.progress);
  }

  Future<void> _deleteBookmark(Bookmark b) async {
    try {
      await _bookmarkService.removeBookmark(_path, b.id);
    } catch (_) {}
    await _reloadBookmarks();
  }

  // ------------------------------------------------------------ sheets

  void _updateSettings(ReaderSettings s) {
    if (!mounted) return;
    setState(() => _settings = s);
    unawaited(s.save());
    if (!_docLoading) {
      _js(
        'window.ER && ER.applySettings('
        '${jsonEncode(s.resolved(_brightness).toJs())})',
      );
    }
  }

  void _openSettings() {
    final info = _info;
    if (info == null) return;
    ReaderSettingsSheet.show(
      context,
      initial: _settings,
      onChanged: _updateSettings,
      fixedLayout: info.metadata.fixedLayout,
    );
  }

  void _openSearch() {
    final source = _source;
    if (source == null) return;
    ReaderSearchSheet.show(
      context,
      controller: _search,
      source: source,
      titleForSpine: _titleForSpine,
      onSelect: _openSearchHit,
    );
  }

  void _openSearchHit(SearchHit hit) {
    final query = _search.query;
    if (hit.spineIndex == _spine && !_docLoading && _docError == null) {
      _js('ER.find(${jsonEncode(query)}, ${hit.occurrence})');
    } else {
      _openSpine(hit.spineIndex, {
        'type': 'search',
        'query': query,
        'occurrence': hit.occurrence,
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Only when the reader itself (not the web view) has focus; the page
    // script handles keys while the web view is focused.
    if (!node.hasPrimaryFocus || event is KeyUpEvent || _info == null) {
      return KeyEventResult.ignored;
    }
    final rtl = _info!.metadata.rtl;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      rtl ? _prev() : _next();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      rtl ? _next() : _prev();
    } else if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowDown) {
      _next();
    } else if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowUp) {
      _prev();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ------------------------------------------------------------- layout

  /// Tells the page about a vertical hinge it must keep text away from.
  void _syncHinge(FoldInfo? fold) {
    final hinge = fold == null
        ? null
        : <String, dynamic>{
            'x': fold.bounds.left,
            'width': fold.bounds.width,
          };
    final key = hinge == null ? '' : '${hinge['x']}:${hinge['width']}';
    if (key == _hingeKey) return;
    _hingeKey = key;
    _hinge = hinge;
    if (_web != null && !_docLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _js('window.ER && ER.setHinge(${jsonEncode(hinge)})');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final fold = FoldInfo.of(context);
    final verticalHinge = fold != null && fold.isVertical;
    final wide = AdaptiveSplitView.isSplit(context);
    final docked = info != null &&
        _error == null &&
        wide &&
        (_panelPreference ?? !verticalHinge);
    _syncHinge(!docked && verticalHinge ? fold : null);

    final bookmarked = _currentBookmark() != null;

    return ExplorerScaffold(
      title: info?.metadata.title ?? widget.epubFile.uri.pathSegments.last,
      trailing: info == null
          ? null
          : ViewerActions(
              children: [
                ViewerAction(
                  icon: LucideIcons.search,
                  tooltip: 'Search in book',
                  onPressed: _openSearch,
                ),
                ViewerAction(
                  icon: bookmarked
                      ? LucideIcons.bookmarkCheck
                      : LucideIcons.bookmarkPlus,
                  tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
                  selected: bookmarked,
                  onPressed: _docLoading || _docError != null
                      ? null
                      : _toggleBookmark,
                ),
                Builder(
                  builder: (barContext) => ViewerAction(
                    icon: wide
                        ? (docked
                              ? LucideIcons.panelLeftClose
                              : LucideIcons.panelLeft)
                        : LucideIcons.listTree,
                    tooltip: 'Contents & bookmarks',
                    onPressed: () {
                      if (wide) {
                        setState(() => _panelPreference = !docked);
                      } else {
                        Scaffold.maybeOf(barContext)?.openDrawer();
                      }
                    },
                  ),
                ),
                ViewerAction(
                  icon: LucideIcons.aLargeSmall,
                  tooltip: 'Reading settings',
                  onPressed: _openSettings,
                ),
              ],
            ),
      drawer: info != null && !docked ? _buildDrawer(context) : null,
      body: Column(
        children: [
          SizedBox(height: DockedGlossyTopBar.contentTopInset(context)),
          Expanded(child: _buildContent(context, docked, fold)),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final width = math.min(380.0, MediaQuery.sizeOf(context).width * 0.88);
    return AppSidebar(
      width: width,
      child: Builder(
        builder: (drawerContext) => _buildPanel(
          onDone: () => Scaffold.maybeOf(drawerContext)?.closeDrawer(),
        ),
      ),
    );
  }

  Widget _buildPanel({VoidCallback? onDone, VoidCallback? onClose}) {
    final info = _info!;
    return ReaderSidePanel(
      info: info,
      cover: _cover,
      current: _currentTocEntry(),
      bookmarks: _bookmarks,
      bookmarkLabel: (b) => b.label,
      onTocTap: (entry) {
        final target = _tocTarget(entry);
        if (target == null) return;
        onDone?.call();
        _goTo(target.spineIndex!, target.fragment);
      },
      onBookmarkTap: (b) {
        onDone?.call();
        _goToBookmark(b);
      },
      onBookmarkDelete: _deleteBookmark,
      onClose: onClose,
    );
  }

  /// The entry itself, or for a heading without a link its first child
  /// that has one.
  static TocEntry? _tocTarget(TocEntry entry) {
    if (entry.spineIndex != null) return entry;
    for (final child in entry.children) {
      final t = _tocTarget(child);
      if (t != null) return t;
    }
    return null;
  }

  Widget _buildContent(BuildContext context, bool docked, FoldInfo? fold) {
    final error = _error;
    if (error != null || (!_opening && _info == null)) {
      return _ErrorView(
        message: error ?? 'Unknown error',
        onRetry: _retryable ? () => _open(retry: true) : null,
      );
    }
    // While the book is still opening, the same layout is built (with the
    // reader pane only) so the WebView starts immediately and survives the
    // switch: the reader pane keeps its key when the docked panel appears.
    final hingeSplit = docked && fold != null && fold.isVertical;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final panelWidth = hingeSplit
        ? fold.bounds.left
        : (screenWidth >= 1200 ? 360.0 : 320.0);
    return Row(
      children: [
        if (docked)
          SizedBox(
            key: const ValueKey('toc-pane'),
            width: panelWidth,
            child: Material(
              color: context.colors.background,
              child: _buildPanel(
                onClose: () => setState(() => _panelPreference = false),
              ),
            ),
          ),
        if (docked)
          hingeSplit
              ? SizedBox(
                  key: const ValueKey('hinge-gap'),
                  width: fold.bounds.width,
                )
              : const VerticalDivider(key: ValueKey('toc-divider'), width: 1),
        Expanded(
          key: const ValueKey('reader-pane'),
          child: _buildReader(context),
        ),
      ],
    );
  }

  Widget _buildReader(BuildContext context) {
    final theme = _effective.theme;
    final overall = _displayOverall;
    final status = _docLoading
        ? ''
        : '${_page + 1}/$_pages · ${(overall * 100).round()}%';
    final prev = _adjacent(_spine, -1);
    final next = _adjacent(_spine, 1);

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: theme.background,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _buildWebView()),
                  if (_docLoading)
                    Positioned.fill(
                      child: _shownOnce
                          ? _LoadingPage(theme: theme, title: _chapterTitle)
                          : _LoadingPage(
                              theme: theme,
                              title: _info?.metadata.title ?? _fileTitle,
                              subtitle: _info?.metadata.authorLine,
                            ),
                    ),
                  if (_docError != null)
                    Positioned.fill(child: _buildDocError(theme, prev, next)),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 8,
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedSlide(
                        offset: _controlsVisible
                            ? Offset.zero
                            : const Offset(0, 0.25),
                        duration: const Duration(milliseconds: 180),
                        child: AnimatedOpacity(
                          opacity: _controlsVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 640),
                              child: ReaderControlsPanel(
                                theme: theme,
                                title: _chapterTitle,
                                detail: _docLoading
                                    ? 'Loading…'
                                    : 'Page ${_page + 1} of $_pages in this '
                                        'section · ${(overall * 100).round()}% '
                                        'of book',
                                value: _scrubValue ?? overall,
                                labelFor: (v) {
                                  final (s, _) = _fromOverall(v);
                                  return '${(v * 100).round()}% · '
                                      '${_titleForSpine(s)}';
                                },
                                onChanged: (v) =>
                                    setState(() => _scrubValue = v),
                                onChangeEnd: (v) {
                                  setState(() => _scrubValue = null);
                                  final (s, f) = _fromOverall(v);
                                  _goToPosition(s, f);
                                },
                                onPrevChapter: prev == null
                                    ? null
                                    : () => _openSpine(
                                          prev,
                                          const {'type': 'start'},
                                        ),
                                onNextChapter: next == null
                                    ? null
                                    : () => _openSpine(
                                          next,
                                          const {'type': 'start'},
                                        ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ReaderFooter(theme: theme, title: _chapterTitle, status: status),
            SizedBox(height: MediaQuery.paddingOf(context).bottom),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      key: ValueKey('ebook-webview-$_webGeneration'),
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: true,
        transparentBackground: true,
        supportZoom: false,
        builtInZoomControls: false,
        displayZoomControls: false,
        useWideViewPort: false,
        loadWithOverviewMode: false,
        textZoom: 100,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        overScrollMode: OverScrollMode.NEVER,
        disallowOverScroll: true,
        allowsLinkPreview: false,
        allowsBackForwardNavigationGestures: false,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        algorithmicDarkeningAllowed: false,
        cacheEnabled: false,
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) {
        _web = controller;
        controller.addJavaScriptHandler(
          handlerName: 'er',
          callback: _onJsMessage,
        );
        _startIfReady();
      },
      shouldOverrideUrlLoading: _shouldOverride,
      onLoadStop: _onLoadStop,
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame != true || !mounted) return;
        // Reloading the same URL while it loads cancels the first
        // navigation (reported on Apple platforms and Windows); the new
        // load carries on.
        if (error.type == WebResourceErrorType.CANCELLED) return;
        final url = request.url.toString();
        final expected = _expectedUrl;
        if (expected == null || _stripFragment(url) != _stripFragment(expected)) {
          return;
        }
        debugPrint('EPUB reader: load error ${error.type}: ${error.description}');
        setState(() {
          _docLoading = false;
          _docError = 'This section could not be loaded.';
        });
      },
      onRenderProcessGone: (controller, detail) => _recreateWebView(),
      onWebContentProcessDidTerminate: (controller) => _recreateWebView(),
      onConsoleMessage: kDebugMode
          ? (controller, message) =>
              debugPrint('EPUB reader console: ${message.message}')
          : null,
    );
  }

  /// The renderer died (crash or out of memory): start a new WebView. A
  /// section that kills it twice in a row isn't reloaded again; the error
  /// view lets the reader skip it.
  void _recreateWebView() {
    if (!mounted) return;
    _crashes = _crashSpine == _spine ? _crashes + 1 : 1;
    _crashSpine = _spine;
    final giveUp = _crashes >= 2;
    _loadId++; // ignore the dead page's messages and timers
    _readyTimer?.cancel();
    setState(() {
      _webGeneration++;
      _web = null;
      if (giveUp) {
        _pending = null;
        _docLoading = false;
        _docError =
            'This section is too large or complex to display on this device.';
      } else {
        _pending = (_spine, {'type': 'fraction', 'value': _fraction});
        _docLoading = true;
      }
    });
  }

  Widget _buildDocError(ReaderTheme theme, int? prev, int? next) {
    // A card in the app's colours, so its text and buttons stay readable
    // on every page theme.
    return ColoredBox(
      color: theme.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: AppPanel(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ViewerMessage(
              icon: LucideIcons.fileWarning,
              destructive: true,
              title: "Couldn't show this section",
              message: _docError,
              actions: [
                if (prev != null)
                  OutlinedButton.icon(
                    icon: const Icon(LucideIcons.chevronLeft, size: 16),
                    label: const Text('Previous section'),
                    onPressed: () => _openSpine(prev, const {'type': 'end'}),
                  ),
                if (next != null)
                  FilledButton.icon(
                    icon: const Icon(LucideIcons.chevronRight, size: 16),
                    label: const Text('Next section'),
                    onPressed: () => _openSpine(next, const {'type': 'start'}),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown over the WebView while a document loads: the title plus a page of
/// placeholder lines in the reader theme, so even the very first frame of
/// the screen looks like the book rather than a blank spinner.
class _LoadingPage extends StatelessWidget {
  const _LoadingPage({required this.theme, required this.title, this.subtitle});

  final ReaderTheme theme;
  final String title;
  final String? subtitle;

  static const _lines = [1.0, 0.96, 0.99, 0.93, 0.97, 0.62, 0.0, 0.98, 0.95, 0.7];

  @override
  Widget build(BuildContext context) {
    final fg = theme.foreground;
    final placeholder = fg.withValues(alpha: theme.isDark ? 0.10 : 0.07);
    final sub = subtitle;
    return ColoredBox(
      color: theme.background,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _DelayedProgress(color: fg.withValues(alpha: 0.35)),
          ),
          Align(
            alignment: const Alignment(0, -0.35),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.85),
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (sub != null && sub.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.6),
                          fontSize: 15,
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    for (final width in _lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: FractionallySizedBox(
                          widthFactor: width == 0 ? 0.01 : width,
                          child: Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: width == 0 ? null : placeholder,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A thin progress bar that only appears (and starts animating) when
/// loading takes a while: quick loads don't render frames for it, leaving
/// the CPU to the WebView and the parser.
class _DelayedProgress extends StatefulWidget {
  const _DelayedProgress({required this.color});

  final Color color;

  @override
  State<_DelayedProgress> createState() => _DelayedProgressState();
}

class _DelayedProgressState extends State<_DelayedProgress> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _visible
      ? LinearProgressIndicator(
          minHeight: 2,
          backgroundColor: Colors.transparent,
          color: widget.color,
        )
      : const SizedBox(height: 2);
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return ViewerMessage(
      icon: LucideIcons.bookX,
      destructive: true,
      title: "Couldn't open this book",
      message: message,
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('Close'),
        ),
        if (onRetry != null)
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('Try again'),
          ),
      ],
    );
  }
}
