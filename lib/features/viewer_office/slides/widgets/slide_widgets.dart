import 'dart:io';
import 'dart:math' as math;

import 'package:folder/core/platform/system_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/viewer_ui.dart';
import '../slide_model.dart';
import 'slide_canvas.dart';

/// A slide preview card.
class SlideThumbnail extends StatelessWidget {
  const SlideThumbnail({
    super.key,
    required this.deck,
    required this.slide,
    required this.images,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final SlideDeck deck;
  final Slide slide;
  final SlideImageCache images;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label:
          'Slide ${slide.index + 1}${slide.title.isEmpty ? '' : ': ${slide.title}'}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${slide.index + 1}',
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected ? colors.foreground : colors.mutedForeground,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected ? colors.ring : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: colors.border),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: Stack(
                        children: [
                          RepaintBoundary(
                            child: SlideFit.builder(
                              deck: deck,
                              builder: (context, scale) => SlideCanvas(
                                deck: deck,
                                slide: slide,
                                images: images,
                                pixelScale: scale,
                              ),
                            ),
                          ),
                          if (slide.hidden)
                            Positioned.fill(
                              child: ColoredBox(
                                color: Colors.white.withValues(alpha: 0.6),
                                child: const Center(
                                  child: Icon(
                                    LucideIcons.eyeOff,
                                    size: 16,
                                    color: Color(0xFF374151),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// Fullscreen slideshow: immersive, tap right/left (or arrows/space) to
/// navigate. Hidden slides are skipped (unless the show starts on one, as
/// in PowerPoint). Pops with the deck index of the last slide shown.
class PresentationMode extends StatefulWidget {
  const PresentationMode({
    super.key,
    required this.deck,
    required this.images,
    required this.startIndex,
  });

  final SlideDeck deck;
  final SlideImageCache images;
  final int startIndex;

  @override
  State<PresentationMode> createState() => _PresentationModeState();
}

class _PresentationModeState extends State<PresentationMode> {
  late final PageController _pages;

  /// Deck indices of the slides shown, and the position in that list.
  late final List<int> _shown;
  late int _index;
  bool _showHud = true;
  bool _restored = false;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    final slides = widget.deck.slides;
    _shown = [
      for (var i = 0; i < slides.length; i++)
        if (!slides[i].hidden || i == widget.startIndex) i,
    ];
    _index = math.max(0, _shown.indexOf(widget.startIndex));
    _pages = PageController(initialPage: _index);
    SystemBars.hide();
    if (Platform.isAndroid || Platform.isIOS) {
      final landscape = widget.deck.width >= widget.deck.height;
      SystemChrome.setPreferredOrientations(
        landscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      );
    }
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showHud = false);
    });
  }

  @override
  void dispose() {
    _restoreSystemUi();
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Brings the status and navigation bars back.
  void _restoreSystemUi() {
    if (_restored) return;
    _restored = true;
    SystemBars.show();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setPreferredOrientations(const []);
    }
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, _shown.length - 1);
    if (next == _index) {
      if (delta > 0 && _index == _shown.length - 1) _exit();
      return;
    }
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _exit() {
    _restoreSystemUi();
    Navigator.of(context).pop(_shown[_index]);
  }

  @override
  Widget build(BuildContext context) {
    final deck = widget.deck;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: KeyboardListener(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: (e) {
            if (e is! KeyDownEvent) return;
            final k = e.logicalKey;
            if (k == LogicalKeyboardKey.arrowRight ||
                k == LogicalKeyboardKey.space ||
                k == LogicalKeyboardKey.pageDown ||
                k == LogicalKeyboardKey.enter) {
              _go(1);
            } else if (k == LogicalKeyboardKey.arrowLeft ||
                k == LogicalKeyboardKey.pageUp ||
                k == LogicalKeyboardKey.backspace) {
              _go(-1);
            } else if (k == LogicalKeyboardKey.escape) {
              _exit();
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final w = MediaQuery.sizeOf(context).width;
              if (d.globalPosition.dx < w * 0.3) {
                _go(-1);
              } else {
                _go(1);
              }
            },
            onLongPress: () => setState(() => _showHud = !_showHud),
            child: Stack(
              children: [
                PageView.builder(
                  controller: _pages,
                  itemCount: _shown.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => Center(
                    child: SlideFit.builder(
                      deck: deck,
                      builder: (context, scale) => SlideCanvas(
                        deck: deck,
                        slide: deck.slides[_shown[i]],
                        images: widget.images,
                        pixelScale: scale,
                      ),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: _showHud ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // The slideshow is always on black.
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                child: Text(
                                  '${_index + 1} / ${_shown.length}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            ViewerAction(
                              tooltip: 'Exit slideshow',
                              color: Colors.white,
                              icon: LucideIcons.x,
                              onPressed: _exit,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

//// Edits the text of one shape: one line per paragraph. Returns the new
/// paragraphs or null when cancelled.
Future<List<String>?> showShapeTextEditor(
  BuildContext context, {
  required List<String> paragraphs,
  String? title,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => _ShapeTextDialog(paragraphs: paragraphs, title: title),
  );
}

/// Owns its text controller, so it lives as long as the dialog (including
/// its closing animation).
class _ShapeTextDialog extends StatefulWidget {
  const _ShapeTextDialog({required this.paragraphs, this.title});

  final List<String> paragraphs;
  final String? title;

  @override
  State<_ShapeTextDialog> createState() => _ShapeTextDialogState();
}

class _ShapeTextDialogState extends State<_ShapeTextDialog> {
  late final _controller = TextEditingController(
    text: widget.paragraphs.join('\n'),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return AlertDialog(
      // Scrolls instead of overflowing once the keyboard is up on phones.
      scrollable: true,
      title: Text(widget.title ?? 'Edit text'),
      content: SizedBox(
        width: width < 600 ? width : 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Each line is a paragraph. Formatting of unchanged text is kept.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _controller.text.split('\n')),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Asks for a slide number (1-based); returns a 0-based index.
Future<int?> showGoToSlide(BuildContext context, int count) {
  return showDialog<int>(
    context: context,
    builder: (_) => _GoToSlideDialog(count: count),
  );
}

class _GoToSlideDialog extends StatefulWidget {
  const _GoToSlideDialog({required this.count});

  final int count;

  @override
  State<_GoToSlideDialog> createState() => _GoToSlideDialogState();
}

class _GoToSlideDialogState extends State<_GoToSlideDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_controller.text.trim());
    if (n != null && n >= 1 && n <= widget.count) {
      Navigator.pop(context, n - 1);
    } else {
      setState(() => _error = 'Enter 1 to ${widget.count}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Go to slide'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: 'Slide (1–${widget.count})',
          prefixIcon: const Icon(LucideIcons.hash, size: 16),
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Go')),
      ],
    );
  }
}
