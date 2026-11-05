import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/services/new_files.dart';
import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../common/office_files.dart';
import '../common/office_package.dart';
import '../slides/pptx_editor.dart';
import '../slides/pptx_parser.dart';
import '../slides/slide_loader.dart';
import '../slides/slide_model.dart';
import '../slides/widgets/slide_canvas.dart';
import '../slides/widgets/slide_widgets.dart';

// The file is read inside the isolate so its bytes are never copied over
// from (or held by) the UI isolate.
Future<SlideDeck> _loadInBackground(String path, String ext) =>
    Isolate.run(() => loadPresentationFile(path, ext));

Future<OfficePackage> _decodeInBackground(String path) =>
    Isolate.run(() => OfficePackage.decode(File(path).readAsBytesSync()));

Future<Uint8List> _encodeInBackground(OfficePackage pkg) =>
    Isolate.run(() => pkg.encode());

/// Viewer for presentations (PPTX family, PPT/PPS/POT, ODP/OTP) with
/// thumbnails, notes, a fullscreen slideshow and, for PPTX, editing (text,
/// duplicate/delete/reorder slides).
///
/// Pops with `true` when it created a new file (e.g. "Save as copy").
class PptViewerScreen extends StatefulWidget {
  const PptViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<PptViewerScreen> createState() => _PptViewerScreenState();
}

class _PptViewerScreenState extends State<PptViewerScreen> {
  late File _file;
  int? _fileSize;
  SlideDeck? _deck;
  SlideImageCache? _images;
  String? _error;

  /// Reads the deck slide by slide; null once everything has arrived.
  PresentationLoader? _loader;
  final Completer<void> _loaded = Completer<void>();
  bool _loadDone = false;
  bool _notesLoaded = false;

  /// Thumbnails are built a frame after the first slide so it shows first.
  bool _thumbsReady = false;

  OfficePackage? _pkg;
  int _index = 0;
  PageController _pages = PageController();
  final ScrollController _thumbs = ScrollController();
  bool _showNotes = false;
  bool _zoomed = false;

  bool _editing = false;
  bool _dirty = false;
  bool _busy = false;
  bool _createdNewFile = false;
  String? _selectedShape;

  @override
  void initState() {
    super.initState();
    _file = widget.file;
    _load();
  }

  @override
  void dispose() {
    _loader?.dispose();
    // Releases anything waiting in _whenLoaded (it then sees !mounted).
    if (!_loaded.isCompleted) _loaded.complete();
    _pages.dispose();
    _thumbs.dispose();
    super.dispose();
  }

  String get _ext =>
      p.extension(_file.path).toLowerCase().replaceFirst('.', '');

  /// Starts reading in a background isolate. The first frame (title and a
  /// slide-shaped placeholder) doesn't wait for it; slide 1 shows as soon
  /// as it's parsed and the others fill in behind it.
  void _load() {
    _file.length().then((n) => _fileSize = n, onError: (_) {});
    final loader = _loader = PresentationLoader(_file.path, _ext);
    loader.events.listen(_onLoadEvent);
    loader.start();
  }

  void _onLoadEvent(SlideLoadEvent e) {
    if (!mounted) return;
    switch (e) {
      case SlideDeckOpened(:final deck):
        setState(() {
          _setDeck(deck);
          if (deck.slides.isEmpty) _error = 'This presentation has no slides.';
        });
      case SlidesParsed(:final slides, :final images):
        final deck = _deck;
        if (deck == null) return;
        deck.images.addAll(images);
        slides.forEach((i, s) {
          if (i < deck.slides.length) deck.slides[i] = s;
        });
        if (slides.containsKey(_index)) _showThumbsAfterThisFrame();
        setState(() {});
      case SlideNotesParsed(:final notes):
        final deck = _deck;
        if (deck == null) return;
        notes.forEach((i, t) {
          if (i < deck.slides.length) deck.slides[i].notes = t;
        });
        setState(() => _notesLoaded = true);
      case SlideDeckParsed(:final deck):
        setState(() {
          _setDeck(deck);
          _notesLoaded = true;
          if (deck.slides.isEmpty) _error = 'This presentation has no slides.';
        });
        _showThumbsAfterThisFrame();
        _finishLoad();
      case SlideLoadDone():
        _finishLoad();
      case SlideLoadFailed(:final error):
        final deck = _deck;
        if (deck == null) {
          setState(() => _error = _loadErrorText(error));
        } else {
          // Lost the loader midway: keep what arrived.
          for (var i = 0; i < deck.slides.length; i++) {
            final s = deck.slides[i];
            if (s.pending) {
              deck.slides[i] = unreadableSlide(i, deck.width, deck.height)
                ..partName = s.partName
                ..relId = s.relId
                ..slideId = s.slideId;
            }
          }
          setState(() => _notesLoaded = true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Some slides couldn\'t be read.')),
          );
        }
        _finishLoad();
    }
  }

  static String _loadErrorText(Object error) => switch (error) {
    PresentationEncryptedException() =>
      'This presentation is password-protected. Open it in PowerPoint or another app that can decrypt it.',
    FormatException(:final message) =>
      'This file couldn\'t be read as a presentation.\n$message',
    _ => 'Something went wrong while opening this presentation.',
  };

  void _finishLoad() {
    _loader = null;
    if (!_loaded.isCompleted) _loaded.complete();
    if (!mounted) return;
    setState(() => _loadDone = true);
    // A new file is there to be written in.
    if (UntitledFiles.isUntitled(_file) && !_editing && _error == null) unawaited(_startEditing());
  }

  void _showThumbsAfterThisFrame() {
    if (_thumbsReady) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_thumbsReady) setState(() => _thumbsReady = true);
    });
  }

  /// Waits until every slide is parsed (actions that need the whole deck).
  Future<bool> _whenLoaded() async {
    if (!_loadDone) await _loaded.future;
    return mounted && _deck != null && _error == null;
  }

  void _setDeck(SlideDeck deck) {
    final old = _images;
    _deck = deck;
    _images = SlideImageCache(deck);
    if (old != null) _images!.adoptFrom(old);
    if (_index >= deck.slides.length) {
      _index = math.max(0, deck.slides.length - 1);
    }
  }

  /// Asks the loader for slide [i] next when it's still pending.
  void _want(int i) {
    final deck = _deck;
    if (deck != null && i < deck.slides.length && deck.slides[i].pending) {
      _loader?.prioritize(i);
    }
  }

  void _goTo(int i, {bool animate = true}) {
    final deck = _deck;
    if (deck == null || deck.slides.isEmpty) return;
    final t = i.clamp(0, deck.slides.length - 1);
    _want(t);
    if (_pages.hasClients) {
      if (animate && (t - _index).abs() <= 2) {
        _pages.animateToPage(
          t,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _pages.jumpToPage(t);
      }
    }
    setState(() {
      _index = t;
      _selectedShape = null;
    });
    _revealThumb(t);
  }

  void _revealThumb(int i) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_thumbs.hasClients) return;
      final pos = _thumbs.position;
      final extent = _thumbExtent;
      if (extent <= 0) return;
      final start = i * extent;
      final end = start + extent;
      double? target;
      if (start < pos.pixels) target = start - extent * 0.3;
      if (end > pos.pixels + pos.viewportDimension) {
        target = end - pos.viewportDimension + extent * 0.3;
      }
      if (target != null) {
        _thumbs.animateTo(
          target.clamp(0, pos.maxScrollExtent),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  double _thumbExtent = 0;

  // ---------------------------------------------------------------------------
  // Editing

  bool get _canEdit => _deck?.format == 'pptx';

  Future<void> _startEditing() async {
    if (!_canEdit) return;
    setState(() => _busy = true);
    try {
      // The package is only decoded when editing starts.
      if (!await _whenLoaded()) return;
      _pkg ??= await _decodeInBackground(_file.path);
      if (!mounted) return;
      setState(() => _editing = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tap a text box to edit it. Use the slide menu to duplicate, delete or move slides.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Can\'t edit this file: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs an edit on the package and re-reads the deck from it.
  Future<void> _apply(
    String? Function(PptxEditor editor) op, {
    int Function(SlideDeck deck, String? result)? focus,
  }) async {
    final pkg = _pkg;
    if (pkg == null || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = op(PptxEditor(pkg));
      // Parsing the in-memory package reuses media bytes, so decoded images
      // stay cached.
      final deck = PptxParser(pkg).parse();
      if (!mounted) return;
      final target = focus?.call(deck, result) ?? _index;
      setState(() {
        _setDeck(deck);
        _dirty = true;
      });
      _pages.dispose();
      _pages = PageController(
        initialPage: target.clamp(0, math.max(0, deck.slides.length - 1)),
      );
      setState(() {
        _index = target.clamp(0, math.max(0, deck.slides.length - 1));
        _selectedShape = null;
      });
      _revealThumb(_index);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is StateError ? e.message : 'Couldn\'t apply the change: $e',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editShape(SlideAutoShape shape) async {
    final deck = _deck;
    final pkg = _pkg;
    if (deck == null || pkg == null) return;
    final slide = deck.slides[_index];
    final part = slide.partName;
    final id = shape.id;
    if (part == null || id == null) return;
    setState(() => _selectedShape = id);
    final paragraphs = PptxEditor(pkg).shapeParagraphs(part, id);
    if (paragraphs == null) return;
    final result = await showShapeTextEditor(
      context,
      paragraphs: paragraphs,
      title: shape.placeholder == 'title' || shape.placeholder == 'ctrTitle'
          ? 'Edit title'
          : 'Edit text',
    );
    if (!mounted) return;
    if (result == null) {
      setState(() => _selectedShape = null);
      return;
    }
    await _apply((ed) {
      ed.setShapeText(part, id, result);
      return null;
    });
  }

  Future<void> _duplicate(int index) async {
    final rel = _deck?.slides[index].relId;
    if (rel == null) return;
    await _apply(
      (ed) => ed.duplicateSlide(rel),
      focus: (deck, newRel) => deck.slides.indexWhere((s) => s.relId == newRel),
    );
  }

  Future<void> _delete(int index) async {
    final deck = _deck;
    final rel = deck?.slides[index].relId;
    if (deck == null || rel == null) return;
    if (deck.slides.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A presentation needs at least one slide.'),
        ),
      );
      return;
    }
    final ok = await showViewerConfirm(
      context,
      title: 'Delete slide ${index + 1}?',
      message: 'The slide and its speaker notes will be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _apply((ed) {
      ed.deleteSlide(rel);
      return null;
    }, focus: (deck, _) => math.min(index, deck.slides.length - 1));
  }

  Future<void> _move(int from, int to) async {
    final deck = _deck;
    if (deck == null || to < 0 || to >= deck.slides.length || from == to) {
      return;
    }
    await _apply((ed) {
      ed.moveSlide(from, to);
      return null;
    }, focus: (_, _) => to);
  }

  Future<void> _save({required bool copy}) async {
    final pkg = _pkg;
    if (pkg == null || _busy) return;
    final named = await UntitledFiles.saveTarget(context, _file);
    if (named == null || !mounted) return;
    _file = named;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await _encodeInBackground(pkg);
      final target = copy
          ? await uniqueSibling(_file, _ext, suffix: ' copy')
          : _file;
      await writeFileSafely(target, bytes);
      if (!mounted) return;
      setState(() {
        if (!copy) {
          _dirty = false;
          _fileSize = bytes.length;
        } else {
          _createdNewFile = true;
        }
      });
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${p.basename(target.path)}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmLeaveEditing() async {
    if (!_dirty) return true;
    final choice = await askUnsavedChanges(context);
    if (!mounted || choice == UnsavedChoice.cancel) return false;
    if (choice == UnsavedChoice.save) {
      await _save(copy: false);
      return !_dirty;
    }
    // Discard: reload the file as it is on disk.
    _pkg = null;
    _dirty = false;
    try {
      final deck = await _loadInBackground(_file.path, _ext);
      if (mounted) setState(() => _setDeck(deck));
    } catch (_) {
      // Keep showing the edited deck; nothing was written.
    }
    return true;
  }

  Future<void> _finishEditing() async {
    if (!await _confirmLeaveEditing()) return;
    if (mounted) {
      setState(() {
        _editing = false;
        _selectedShape = null;
      });
    }
  }

  Future<void> _onPop() async {
    if (_dirty && !await _confirmLeaveEditing()) return;
    if (mounted) Navigator.of(context).pop(_createdNewFile);
  }

  // ---------------------------------------------------------------------------
  // Actions

  Future<void> _present() async {
    if (!await _whenLoaded()) return;
    final deck = _deck;
    final images = _images;
    if (deck == null || images == null || !mounted) return;
    final last = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            PresentationMode(deck: deck, images: images, startIndex: _index),
      ),
    );
    if (last != null && mounted) _goTo(last, animate: false);
  }

  Future<void> _showInfo() async {
    if (!await _whenLoaded()) return;
    final deck = _deck;
    if (deck == null || !mounted) return;
    String cm(double pt) => (pt / 72 * 2.54).toStringAsFixed(1);
    final notes = deck.slides.where((s) => s.notes.isNotEmpty).length;
    final rows = <(String, String)>[
      ('Name', p.basename(_file.path)),
      (
        'Format',
        switch (deck.format) {
          'pptx' => 'PowerPoint presentation',
          'ppt' => 'PowerPoint 97–2003 presentation (view only)',
          _ => 'OpenDocument presentation (view only)',
        },
      ),
      ('Size', formatBytes(_fileSize ?? 0)),
      ('Slides', '${deck.slides.length}'),
      ('Hidden slides', '${deck.slides.where((s) => s.hidden).length}'),
      ('Slides with notes', '$notes'),
      ('Slide size', '${cm(deck.width)} × ${cm(deck.height)} cm'),
    ];
    showViewerInfoSheet(
      context,
      title: 'Presentation info',
      description: p.basename(_file.path),
      rows: rows,
    );
  }

  Future<void> _askGoTo() async {
    final deck = _deck;
    if (deck == null) return;
    final i = await showGoToSlide(context, deck.slides.length);
    if (i != null && mounted) _goTo(i, animate: false);
  }

  Future<void> _onMenu(String action) async {
    switch (action) {
      case 'goto':
        await _askGoTo();
      case 'info':
        await _showInfo();
      case 'notes':
        setState(() => _showNotes = !_showNotes);
      case 'share':
        await _share();
      case 'open':
        await OpenFilex.open(_file.path);
    }
  }

  Future<void> _share() async {
    // iPad presents the share sheet as a popover and requires an anchor;
    // use the top bar's trailing corner, where the menu was opened.
    final size = MediaQuery.sizeOf(context);
    final origin = Rect.fromLTWH(
      math.max(0, size.width - 64),
      MediaQuery.paddingOf(context).top + 12,
      48,
      48,
    );
    final messenger = ScaffoldMessenger.of(context);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(_file.path)], sharePositionOrigin: origin),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t share: $e')));
    }
  }

  void _openLink(String url) => showLinkSheet(context, url);

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty && !_createdNewFile,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPop();
      },
      child: ExplorerScaffold(
        title: p.basename(_file.path) + (_dirty ? ' •' : ''),
        trailing: _deck == null || _error != null
            ? null
            : (_editing ? _editActions(context) : _viewActions(context)),
        body: _body(context),
      ),
    );
  }

  Widget _viewActions(BuildContext context) {
    return ViewerActions(
      children: [
        ViewerAction(
          icon: LucideIcons.presentation,
          tooltip: 'Present',
          onPressed: _present,
        ),
        if (_canEdit)
          ViewerAction(
            icon: LucideIcons.penLine,
            tooltip: 'Edit',
            busy: _busy,
            onPressed: _startEditing,
          ),
        ViewerMenuButton<String>(
          onSelected: _onMenu,
          itemBuilder: (context) => [
            viewerMenuItem(
              value: 'goto',
              icon: LucideIcons.hash,
              label: 'Go to slide…',
            ),
            viewerMenuItem(
              value: 'notes',
              icon: LucideIcons.stickyNote,
              label: 'Speaker notes',
              checked: _showNotes,
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: 'info',
              icon: LucideIcons.info,
              label: 'Presentation info',
            ),
            viewerMenuItem(
              value: 'share',
              icon: LucideIcons.share2,
              label: 'Share',
            ),
            viewerMenuItem(
              value: 'open',
              icon: LucideIcons.externalLink,
              label: 'Open with…',
            ),
          ],
        ),
      ],
    );
  }

  Widget _editActions(BuildContext context) {
    return ViewerActions(
      children: [
        ViewerMenuButton<bool>(
          tooltip: 'Save',
          icon: LucideIcons.save,
          badge: _dirty,
          busy: _busy,
          onSelected: (copy) => _save(copy: copy),
          itemBuilder: (context) => [
            viewerMenuItem(
              value: false,
              icon: LucideIcons.save,
              label: 'Save',
              enabled: _dirty || UntitledFiles.isUntitled(_file),
            ),
            viewerMenuItem(
              value: true,
              icon: LucideIcons.copy,
              label: 'Save as copy',
            ),
          ],
        ),
        ViewerAction(
          icon: LucideIcons.check,
          tooltip: 'Done',
          selected: true,
          onPressed: _busy ? null : _finishEditing,
        ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final deck = _deck;
    if (_error == null && deck == null) return _skeleton(context, top);
    if (_error != null || deck == null) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: ViewerMessage(
          icon: LucideIcons.presentation,
          destructive: _error != null,
          title: "Couldn't open this presentation",
          message: _error ?? 'Nothing to show.',
          actions: [
            OutlinedButton.icon(
              onPressed: () => OpenFilex.open(_file.path),
              icon: const Icon(LucideIcons.externalLink, size: 16),
              label: const Text('Open with another app'),
            ),
          ],
        ),
      );
    }

    return _layout(
      context,
      top,
      main: _mainArea(context, deck),
      thumbnails: (axis) => _thumbnailList(context, deck, axis),
    );
  }

  /// Phone: slide over a thumbnail strip. Tablet/unfolded: thumbnails on
  /// the side. The body is drawn edge to edge, so keep clear of the system
  /// bars on every side.
  Widget _layout(
    BuildContext context,
    double top, {
    required Widget main,
    required Widget Function(Axis axis) thumbnails,
  }) {
    final colors = context.colors;
    final pad = MediaQuery.paddingOf(context);
    final insets = EdgeInsets.fromLTRB(pad.left, top, pad.right, pad.bottom);
    final canvas = ColoredBox(color: ViewerSurface.canvas(context), child: main);
    if (AdaptiveSplitView.isSplit(context)) {
      return ColoredBox(
        color: colors.background,
        child: Padding(
          padding: insets,
          child: AdaptiveSplitView(
            secondaryWidth: 240,
            secondary: thumbnails(Axis.vertical),
            primary: canvas,
          ),
        ),
      );
    }
    return ColoredBox(
      color: colors.background,
      child: Padding(
        padding: insets,
        child: Column(
          children: [
            Expanded(child: canvas),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.border)),
              ),
              child: SizedBox(height: 92, child: thumbnails(Axis.horizontal)),
            ),
          ],
        ),
      ),
    );
  }

  /// First frame, before the slide size is known: a 16:9 slide-shaped
  /// placeholder and empty thumbnail cards.
  Widget _skeleton(BuildContext context, double top) {
    const aspect = 16 / 9;
    return _layout(
      context,
      top,
      main: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: _pendingSlide(context, spinner: true),
                ),
              ),
            ),
          ),
          const SizedBox(height: 48),
        ],
      ),
      thumbnails: (axis) => _thumbnailSkeleton(axis, aspect, 6),
    );
  }

  Widget _pendingSlide(BuildContext context, {bool spinner = false}) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.border),
      ),
      child: spinner
          ? const Center(child: ViewerSpinner(size: 22))
          : const SizedBox.expand(),
    );
  }

  /// Empty thumbnail cards (cheap to build) shown until the first slide is
  /// on screen.
  Widget _thumbnailSkeleton(Axis axis, double aspect, int count) {
    final vertical = axis == Axis.vertical;
    return LayoutBuilder(
      builder: (context, c) {
        final extent = vertical
            ? (c.maxWidth - 44) / aspect + 8
            : (c.maxHeight - 8) * aspect + 36;
        return ListView.builder(
          scrollDirection: axis,
          padding: const EdgeInsets.all(4),
          physics: const NeverScrollableScrollPhysics(),
          itemExtent: extent,
          itemCount: count,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.fromLTRB(32, 4, 4, 4),
            child: _pendingSlide(context),
          ),
        );
      },
    );
  }

  Widget _mainArea(BuildContext context, SlideDeck deck) {
    final slide = deck.slides[_index.clamp(0, deck.slides.length - 1)];
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _pages,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
            itemCount: deck.slides.length,
            onPageChanged: (i) {
              _want(i);
              setState(() {
                _index = i;
                _selectedShape = null;
                _zoomed = false;
              });
              _revealThumb(i);
            },
            itemBuilder: (context, i) => _ZoomableSlide(
              onZoomChanged: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: deck.slides[i].pending
                      ? AspectRatio(
                          aspectRatio: deck.aspect,
                          child: _pendingSlide(context, spinner: true),
                        )
                      : DecoratedBox(
                          position: DecorationPosition.foreground,
                          decoration: BoxDecoration(
                            border: ViewerSurface.page(context).border,
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              boxShadow: ViewerSurface.page(context).boxShadow,
                            ),
                            child: SlideFit.builder(
                              deck: deck,
                              builder: (context, scale) => SlideCanvas(
                                deck: deck,
                                slide: deck.slides[i],
                                images: _images!,
                                onShapeTap: _editing && i == _index
                                    ? _editShape
                                    : null,
                                onLink: _openLink,
                                selectedShapeId: i == _index
                                    ? _selectedShape
                                    : null,
                                // Decode pictures at screen size; sharper
                                // once the user zooms in.
                                pixelScale: _zoomed && i == _index
                                    ? scale * 4
                                    : scale,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
        if (_showNotes)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.25,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.background,
                border: Border(top: BorderSide(color: colors.border)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            LucideIcons.stickyNote,
                            size: 14,
                            color: colors.mutedForeground,
                          ),
                          const SizedBox(width: 6),
                          Text('Speaker notes', style: text.labelMedium),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SelectableText(
                        slide.notes.isNotEmpty
                            ? slide.notes
                            : _notesLoaded
                            ? 'No notes for this slide.'
                            : 'Loading notes…',
                        style: text.bodyMedium?.copyWith(
                          color: slide.notes.isEmpty
                              ? colors.mutedForeground
                              : colors.foreground,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        _bottomBar(context, deck),
      ],
    );
  }

  Widget _bottomBar(BuildContext context, SlideDeck deck) {
    final colors = context.colors;
    final n = deck.slides.length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            const SizedBox(width: 4),
            ViewerAction(
              tooltip: 'Previous slide',
              icon: LucideIcons.chevronLeft,
              onPressed: _index > 0 ? () => _goTo(_index - 1) : null,
            ),
            Tooltip(
              message: 'Go to slide',
              child: TextButton(
                onPressed: _askGoTo,
                style: TextButton.styleFrom(
                  minimumSize: const Size(56, 36),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                child: Text('${_index + 1} / $n'),
              ),
            ),
            ViewerAction(
              tooltip: 'Next slide',
              icon: LucideIcons.chevronRight,
              onPressed: _index < n - 1 ? () => _goTo(_index + 1) : null,
            ),
            const Spacer(),
            ViewerAction(
              tooltip: _showNotes ? 'Hide notes' : 'Show notes',
              icon: LucideIcons.stickyNote,
              selected: _showNotes,
              onPressed: () => setState(() => _showNotes = !_showNotes),
            ),
            if (_editing)
              _slideMenu(_index, n, icon: LucideIcons.galleryVerticalEnd),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _slideMenu(int index, int count, {IconData? icon}) {
    return ViewerMenuButton<String>(
      tooltip: 'Slide actions',
      enabled: !_busy,
      icon: icon ?? LucideIcons.ellipsisVertical,
      size: icon == null ? 32 : 40,
      onSelected: (a) {
        switch (a) {
          case 'dup':
            _duplicate(index);
          case 'del':
            _delete(index);
          case 'up':
            _move(index, index - 1);
          case 'down':
            _move(index, index + 1);
        }
      },
      itemBuilder: (context) => [
        viewerMenuItem(
          value: 'dup',
          icon: LucideIcons.copyPlus,
          label: 'Duplicate slide',
        ),
        viewerMenuItem(
          value: 'up',
          icon: LucideIcons.arrowUp,
          label: 'Move earlier',
          enabled: index > 0,
        ),
        viewerMenuItem(
          value: 'down',
          icon: LucideIcons.arrowDown,
          label: 'Move later',
          enabled: index < count - 1,
        ),
        viewerMenuDivider(),
        viewerMenuItem(
          value: 'del',
          icon: LucideIcons.trash2,
          label: 'Delete slide',
          enabled: count > 1,
          destructive: true,
        ),
      ],
    );
  }

  Widget _thumbnailList(BuildContext context, SlideDeck deck, Axis axis) {
    if (!_thumbsReady) {
      return _thumbnailSkeleton(axis, deck.aspect, deck.slides.length);
    }
    final vertical = axis == Axis.vertical;
    return LayoutBuilder(
      builder: (context, c) {
        // Fixed extents so the current slide can be scrolled into view.
        final extent = vertical
            ? (c.maxWidth - 44) / deck.aspect + 8
            : (c.maxHeight - 8) * deck.aspect + 36;
        _thumbExtent = extent;
        Widget item(BuildContext context, int i) {
          final slide = deck.slides[i];
          final thumb = SlideThumbnail(
            key: ValueKey('${slide.relId ?? slide.index}-$i'),
            deck: deck,
            slide: slide,
            images: _images!,
            selected: i == _index,
            onTap: () => _goTo(i),
            trailing: _editing && vertical
                ? _slideMenu(i, deck.slides.length)
                : null,
          );
          return SizedBox(
            key: ValueKey('thumb-${slide.relId ?? i}'),
            width: vertical ? null : extent,
            height: vertical ? extent : null,
            child: thumb,
          );
        }

        return Material(
          type: MaterialType.transparency,
          child: _thumbnailScroller(deck, axis, extent, item),
        );
      },
    );
  }

  Widget _thumbnailScroller(
    SlideDeck deck,
    Axis axis,
    double extent,
    Widget Function(BuildContext, int) item,
  ) {
    if (_editing) {
      return ReorderableListView.builder(
        scrollController: _thumbs,
        scrollDirection: axis,
        padding: const EdgeInsets.all(4),
        itemCount: deck.slides.length,
        buildDefaultDragHandles: true,
        onReorderItem: (from, to) => _move(from, to),
        itemBuilder: item,
      );
    }
    return ListView.builder(
      controller: _thumbs,
      scrollDirection: axis,
      padding: const EdgeInsets.all(4),
      itemExtent: extent,
      itemCount: deck.slides.length,
      itemBuilder: item,
    );
  }
}

/// Pinch-to-zoom wrapper that tells the pager when it's zoomed in so swipes
/// pan the slide instead of changing pages.
class _ZoomableSlide extends StatefulWidget {
  const _ZoomableSlide({required this.child, required this.onZoomChanged});
  final Widget child;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomableSlide> createState() => _ZoomableSlideState();
}

class _ZoomableSlideState extends State<_ZoomableSlide> {
  final TransformationController _t = TransformationController();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () {
        _t.value = Matrix4.identity();
        widget.onZoomChanged(false);
      },
      child: InteractiveViewer(
        transformationController: _t,
        minScale: 1,
        maxScale: 5,
        onInteractionEnd: (_) =>
            widget.onZoomChanged(_t.value.getMaxScaleOnAxis() > 1.01),
        child: widget.child,
      ),
    );
  }
}
