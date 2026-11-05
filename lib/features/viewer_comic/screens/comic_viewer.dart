import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:folder/core/formats/archive_backend.dart';
import 'package:folder/core/platform/system_bars.dart';
import 'package:folder/core/router/file_opener.dart';
import 'package:folder/core/services/bookmark_service.dart';
import 'package:folder/features/viewer_archive/archive_ui_utils.dart';
import 'package:folder/features/viewer_archive/widgets/archive_dialogs.dart';
import 'package:folder/features/viewer_comic/comic_book.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

enum _Layout { auto, single, double }

/// Reads CBZ/CBR/CB7/CBT comics (any archive with images, detected by
/// content): lazy page loading, pinch zoom, swipe/tap navigation, page
/// slider, right-to-left mode and two-page spreads on wide screens.
class ComicViewerScreen extends StatefulWidget {
  final File comicFile;

  const ComicViewerScreen({super.key, required this.comicFile});

  @override
  State<ComicViewerScreen> createState() => _ComicViewerScreenState();
}

class _ComicViewerScreenState extends State<ComicViewerScreen> {
  late final ComicBook _book = ComicBook(widget.comicFile);
  PageController? _controller;
  bool? _controllerDouble;

  bool _rtl = false;
  _Layout _layout = _Layout.auto;
  bool _chrome = true;
  int _page = 0;
  int? _savedPage;
  bool _restored = false;
  bool _askingPassword = false;
  Timer? _saveTimer;
  final _focusNode = FocusNode();

  String get _name => p.basename(widget.comicFile.path);

  @override
  void initState() {
    super.initState();
    _book.addListener(_onBook);
    _book.open();
    BookmarkService()
        .getLastReadPosition(widget.comicFile.path)
        .timeout(const Duration(seconds: 2))
        .then<void>((v) {
          _savedPage = v is int ? v : int.tryParse('$v');
        })
        .catchError((Object _) {})
        .whenComplete(() {
          _bookmarkLoaded = true;
          if (mounted) setState(_maybeRestore);
        });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePosition();
    _book.removeListener(_onBook);
    _book.dispose();
    _controller?.dispose();
    _focusNode.dispose();
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(SystemBars.show());
    }
    super.dispose();
  }

  void _onBook() {
    if (!mounted) return;
    final err = _book.error;
    if (err != null &&
        (err.kind == ArcErrorKind.needPassword ||
            err.kind == ArcErrorKind.wrongPassword) &&
        !_askingPassword) {
      _askPassword(err);
    }
    _maybeRestore();
    setState(() {});
  }

  Future<void> _askPassword(ArcException err) async {
    _askingPassword = true;
    final pw = await showArchivePasswordDialog(
      context,
      archiveName: _name,
      wrongPassword: err.kind == ArcErrorKind.wrongPassword,
      detail: err.message,
    );
    _askingPassword = false;
    if (pw != null && mounted) _book.open(password: pw);
  }

  void _maybeRestore() {
    if (_restored || !_bookmarkLoaded || _book.loading || _book.pages.isEmpty) {
      return;
    }
    _restored = true;
    final saved = _savedPage;
    if (saved != null && saved > 0 && saved < _book.pages.length) {
      _page = saved;
      _retireController();
    }
    _book.focus(_page, visible: _isDouble ? 2 : 1);
  }

  bool _bookmarkLoaded = false;

  /// Drops the page controller after the frame (a gallery may still be
  /// attached to it during this one).
  void _retireController() {
    final c = _controller;
    _controller = null;
    _controllerDouble = null;
    if (c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => c.dispose());
    }
  }

  void _savePosition() {
    if (_book.pages.isEmpty) return;
    BookmarkService()
        .saveLastReadPosition(widget.comicFile.path, _page)
        .catchError((Object _) {});
  }

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  bool _isDouble = false;

  bool _computeDouble(BuildContext context) {
    switch (_layout) {
      case _Layout.single:
        return false;
      case _Layout.double:
        return true;
      case _Layout.auto:
        final size = MediaQuery.sizeOf(context);
        final fold = FoldInfo.of(context);
        if (fold != null && fold.isVertical) return true;
        return size.width > size.height && size.width >= 600;
    }
  }

  List<List<int>> _spreads(int count, bool dbl) {
    if (!dbl) return [for (var i = 0; i < count; i++) [i]];
    final out = <List<int>>[];
    if (count > 0) out.add([0]); // the cover stands alone
    for (var i = 1; i < count; i += 2) {
      out.add(i + 1 < count ? [i, i + 1] : [i]);
    }
    return out;
  }

  int _spreadOf(int page, bool dbl) => dbl ? (page == 0 ? 0 : (page + 1) ~/ 2) : page;

  PageController _controllerFor(bool dbl) {
    if (_controller == null || _controllerDouble != dbl) {
      _retireController();
      _controller = PageController(initialPage: _spreadOf(_page, dbl));
      _controllerDouble = dbl;
    }
    return _controller!;
  }

  void _go(int delta) {
    final c = _controller;
    if (c == null || !c.hasClients) return;
    final count = _spreads(_book.pages.length, _isDouble).length;
    final current = c.page?.round() ?? 0;
    final target = (current + delta).clamp(0, count - 1);
    if (target == current) return;
    c.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _jumpToSpread(int spread) {
    final c = _controller;
    if (c == null || !c.hasClients) return;
    c.jumpToPage(spread);
  }

  void _onSpreadChanged(int spread, List<List<int>> spreads) {
    final s = spreads[spread];
    setState(() => _page = s.first);
    _book.focus(s.first, visible: s.length);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _savePosition);
  }

  void _setChrome(bool visible) {
    setState(() => _chrome = visible);
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(visible ? SystemBars.show() : SystemBars.hide());
    }
  }

  void _onTapUp(BuildContext context, TapUpDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final x = details.globalPosition.dx;
    if (x < width * 0.3) {
      _go(_rtl ? 1 : -1);
    } else if (x > width * 0.7) {
      _go(_rtl ? -1 : 1);
    } else {
      _setChrome(!_chrome);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final dbl = _computeDouble(context);
    if (dbl != _isDouble) {
      _isDouble = dbl;
      if (_book.pages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _book.focus(_page, visible: dbl ? 2 : 1),
        );
      }
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            _go(_rtl ? -1 : 1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            _go(_rtl ? 1 : -1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.space): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _jumpToSpread(0),
        const SingleActivator(LogicalKeyboardKey.end): () => _jumpToSpread(
          _spreads(_book.pages.length, _isDouble).length - 1,
        ),
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        // Pages sit on black: the reader's chrome uses the dark palette.
        child: ImmersiveTheme(
          child: Builder(
            builder: (context) => Scaffold(
              backgroundColor: Colors.black,
              body: Stack(
                children: [
                  Positioned.fill(child: _content(context)),
                  _topBar(context),
                  if (_book.pages.isNotEmpty) _bottomBar(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final err = _book.error;
    if (err != null) return _errorView(context, err);
    if (_book.loading || (_book.pages.isNotEmpty && !_restored)) {
      return const ViewerLoading(label: 'Opening comic…');
    }
    final spreads = _spreads(_book.pages.length, _isDouble);
    final controller = _controllerFor(_isDouble);
    final mq = MediaQuery.of(context);
    final maxPx = (math.max(mq.size.width, mq.size.height) *
            mq.devicePixelRatio *
            2)
        .clamp(1024, 4096)
        .round();
    return PhotoViewGallery.builder(
      key: ValueKey('gallery-$_isDouble'),
      pageController: controller,
      reverse: _rtl,
      itemCount: spreads.length,
      backgroundDecoration: const BoxDecoration(color: Colors.black),
      onPageChanged: (i) => _onSpreadChanged(i, spreads),
      builder: (context, i) {
        final spread = spreads[i];
        final pages = _rtl ? spread.reversed.toList() : spread;
        Widget child;
        if (pages.length == 1) {
          child = _ComicPage(
            book: _book,
            index: pages.first,
            maxPx: maxPx,
            alignment: Alignment.center,
          );
        } else {
          child = Row(
            children: [
              Expanded(
                child: _ComicPage(
                  book: _book,
                  index: pages[0],
                  maxPx: maxPx,
                  alignment: Alignment.centerRight,
                ),
              ),
              Expanded(
                child: _ComicPage(
                  book: _book,
                  index: pages[1],
                  maxPx: maxPx,
                  alignment: Alignment.centerLeft,
                ),
              ),
            ],
          );
        }
        return PhotoViewGalleryPageOptions.customChild(
          child: child,
          minScale: PhotoViewComputedScale.contained,
          initialScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.contained * 5,
          onTapUp: (context, details, _) => _onTapUp(context, details),
        );
      },
    );
  }

  /// Black-to-clear gradient behind the floating bars, so their white
  /// controls stay readable over any page.
  static const _scrimTop = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xCC000000), Color(0x00000000)],
    ),
  );

  static const _scrimBottom = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [Color(0xCC000000), Color(0x00000000)],
    ),
  );

  Widget _topBar(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final count = _book.pages.length;
    final spread = _spreads(count, _isDouble);
    final current = count == 0 ? null : spread[_spreadOf(_page, _isDouble).clamp(0, spread.length - 1)];
    final label = current == null
        ? _book.formatLabel
        : current.length == 2
        ? 'Pages ${current[0] + 1}–${current[1] + 1} of $count'
        : 'Page ${current[0] + 1} of $count';
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      top: _chrome || _book.error != null || _book.loading ? 0 : -120,
      left: 0,
      right: 0,
      child: DecoratedBox(
        decoration: _scrimTop,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
            child: Row(
              children: [
                AppIconButton(
                  icon: const Icon(LucideIcons.arrowLeft),
                  tooltip: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
                      if (label.isNotEmpty)
                        Text(
                          label,
                          style: text.bodySmall?.copyWith(
                            color: colors.foreground.withValues(alpha: 0.7),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                    ],
                  ),
                ),
                ToolButton(
                  tooltip: _rtl ? 'Reading right to left' : 'Reading left to right',
                  icon: _rtl
                      ? LucideIcons.arrowLeftFromLine
                      : LucideIcons.arrowRightFromLine,
                  size: 40,
                  iconSize: 20,
                  selected: _rtl,
                  onPressed: count == 0 ? null : () => setState(() => _rtl = !_rtl),
                ),
                MenuIconButton<Object>(
                  tooltip: 'Page layout',
                  icon: _isDouble ? LucideIcons.bookOpen : LucideIcons.rectangleVertical,
                  onSelected: (v) {
                    if (v is _Layout) {
                      setState(() {
                        _layout = v;
                        _retireController();
                      });
                    } else if (v == 'external') {
                      FileOpener.openExternally(context, widget.comicFile);
                    }
                  },
                  itemBuilder: (context) => [
                    for (final (value, text, icon) in [
                      (_Layout.auto, 'Automatic', LucideIcons.sparkles),
                      (_Layout.single, 'Single page', LucideIcons.rectangleVertical),
                      (_Layout.double, 'Two pages', LucideIcons.bookOpen),
                    ])
                      menuItem<Object>(
                        value: value,
                        icon: icon,
                        label: text,
                        checked: _layout == value,
                      ),
                    const PopupMenuDivider(),
                    menuItem<Object>(
                      value: 'external',
                      icon: LucideIcons.externalLink,
                      label: 'Open with another app',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final spreads = _spreads(_book.pages.length, _isDouble);
    final current = _spreadOf(_page, _isDouble).clamp(0, spreads.length - 1);
    final waiting = _book.sequential && _book.unpacked < _book.pages.length;
    final numberStyle = text.labelMedium?.copyWith(
      color: colors.foreground,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      bottom: _chrome ? 0 : -140,
      left: 0,
      right: 0,
      child: DecoratedBox(
        decoration: _scrimBottom,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (waiting)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Unpacking pages… ${_book.unpacked} of ${_book.pages.length}',
                      style: text.bodySmall?.copyWith(
                        color: colors.foreground.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${spreads[current].first + 1}',
                        textAlign: TextAlign.center,
                        style: numberStyle,
                      ),
                    ),
                    Expanded(
                      child: Directionality(
                        textDirection:
                            _rtl ? TextDirection.rtl : TextDirection.ltr,
                        child: spreads.length > 1
                            ? Slider(
                                value: current.toDouble(),
                                min: 0,
                                max: (spreads.length - 1).toDouble(),
                                divisions: spreads.length - 1,
                                label: '${spreads[current].first + 1}',
                                onChanged: (v) => _jumpToSpread(v.round()),
                              )
                            : const SizedBox(height: 48),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text(
                        '${_book.pages.length}',
                        textAlign: TextAlign.center,
                        style: numberStyle,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorView(BuildContext context, ArcException err) {
    final needsPassword = err.kind == ArcErrorKind.needPassword ||
        err.kind == ArcErrorKind.wrongPassword;
    return ViewerMessage(
      icon: needsPassword ? LucideIcons.lock : LucideIcons.bookImage,
      title: errorTitle(err.kind),
      message: err.message,
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      actions: [
        if (needsPassword)
          FilledButton.icon(
            onPressed: () => _askPassword(err),
            icon: const Icon(LucideIcons.keyRound, size: 16),
            label: const Text('Enter password'),
          )
        else
          FilledButton.icon(
            onPressed: () => _book.open(password: _book.password),
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('Try again'),
          ),
        OutlinedButton.icon(
          onPressed: () =>
              FileOpener.openExternally(context, widget.comicFile),
          icon: const Icon(LucideIcons.externalLink, size: 16),
          label: const Text('Open with another app'),
        ),
      ],
    );
  }
}

/// One page image, loaded on demand.
class _ComicPage extends StatelessWidget {
  const _ComicPage({
    required this.book,
    required this.index,
    required this.maxPx,
    required this.alignment,
  });

  final ComicBook book;
  final int index;
  final int maxPx;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ComicPageState>(
      valueListenable: book.page(index),
      builder: (context, state, _) {
        ImageProvider? provider;
        if (state.bytes != null) {
          provider = MemoryImage(state.bytes!);
        } else if (state.file != null) {
          provider = FileImage(state.file!);
        }
        if (provider != null) {
          return Image(
            image: ResizeImage(
              provider,
              width: maxPx,
              height: maxPx,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            alignment: alignment,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => ViewerMessage(
              icon: LucideIcons.imageOff,
              title: "Page ${index + 1} can't be displayed",
            ),
          );
        }
        final err = state.error;
        if (err != null) {
          return ViewerMessage(
            icon: LucideIcons.imageOff,
            title: "Page ${index + 1} can't be displayed",
            message: err.message,
            actions: [
              OutlinedButton.icon(
                onPressed: () => book.retry(index),
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('Retry'),
              ),
            ],
          );
        }
        return ViewerLoading(
          label: state.waiting
              ? 'Unpacking… ${book.unpacked} of ${book.pages.length} pages ready'
              : null,
        );
      },
    );
  }
}
