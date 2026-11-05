import 'dart:io';

import 'package:folder/core/files/file_types.dart';
import 'package:folder/core/platform/desktop.dart';
import 'package:folder/core/router/file_opener.dart';
import 'package:folder/core/services/image_text.dart';
import 'package:folder/features/viewer_image/image_codec.dart';
import 'package:folder/features/viewer_image/raw_image.dart';
import 'package:folder/features/viewer_image/screens/image_editor_screen.dart';
import 'package:folder/features/viewer_image/widgets/image_text_layer.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';

/// Swipeable gallery of the images in a folder, with info and editing.
class ImageViewerScreen extends StatefulWidget {
  final File imageFile;

  const ImageViewerScreen({super.key, required this.imageFile});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  // The tapped image is shown on the first frame; the rest of the folder is
  // listed in the background and swapped in around it.
  late PageController _pageController = PageController();
  late List<File> _images = [widget.imageFile];
  int _currentIndex = 0;
  bool _showInfo = false;
  bool _changed = false;

  /// Text found in the image shown ([_textPath]), and whether it's being
  /// selected (the image then holds still).
  ImageText? _text;
  String? _textPath;
  bool _textMode = false;

  @override
  void initState() {
    super.initState();
    _loadImages();
    _readText();
  }

  /// Looks for text in the image shown, in the background.
  Future<void> _readText() async {
    if (!ImageTextReader.enabled) return;
    final file = _current;
    final text = await ImageTextReader.read(file);
    if (!mounted || !p.equals(_current.path, file.path)) return;
    setState(() {
      _text = text;
      _textPath = file.path;
    });
  }

  void _toggleTextMode() => setState(() => _textMode = !_textMode);

  Future<void> _copyText() async {
    final text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Text copied')),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  static bool _isImage(String path) {
    final kind = FileTypes.kindOf(path);
    return kind == FileKind.image ||
        kind == FileKind.rasterImage ||
        kind == FileKind.cameraRaw;
  }

  Future<void> _loadImages({String? focusPath}) async {
    final self = widget.imageFile;
    final List<File> images;
    if (!_isImage(self.path)) {
      // Forced open ("Open with → Image viewer") of a file whose extension
      // isn't an image: show that file, not the folder's other pictures.
      images = [
        self,
        if (focusPath != null && !p.equals(focusPath, self.path)) File(focusPath),
      ];
    } else {
      List<File> listed;
      try {
        listed = (await self.parent.list().toList())
            .whereType<File>()
            .where((f) => _isImage(f.path))
            .toList();
      } catch (_) {
        listed = [];
      }
      // Always include the launched file (and a just-saved edit), even if
      // listing failed or missed it.
      for (final path in [self.path, ?focusPath]) {
        if (!listed.any((f) => p.equals(f.path, path))) listed.add(File(path));
      }
      images = listed
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    }
    final target = focusPath ?? self.path;
    final index = images.indexWhere((f) => p.equals(f.path, target));
    if (!mounted) return;
    final old = _pageController;
    setState(() {
      _images = images;
      _currentIndex = index < 0 ? 0 : index;
      _pageController = PageController(initialPage: _currentIndex);
    });
    // The old controller is detached by the rebuild; dispose it after.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  File get _current => _images[_currentIndex];

  /// Shows the image at [index] (buttons and keys on desktop).
  void _goTo(int index) {
    if (index < 0 || index >= _images.length || index == _currentIndex) return;
    if (!_pageController.hasClients) return;
    if ((index - _currentIndex).abs() == 1) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(index);
    }
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_textMode) {
      // Keys go to the text being selected; Esc stops selecting.
      if (key != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      setState(() => _textMode = false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.arrowUp) {
      _goTo(_currentIndex - 1);
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.space) {
      _goTo(_currentIndex + 1);
    } else if (key == LogicalKeyboardKey.home) {
      _goTo(0);
    } else if (key == LogicalKeyboardKey.end) {
      _goTo(_images.length - 1);
    } else if (key == LogicalKeyboardKey.escape) {
      Navigator.maybePop(context);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _edit() async {
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => ImageEditorScreen(file: _current)),
    );
    if (saved == null || !mounted) return;
    _changed = true;
    imageCache.evict(FileImage(File(saved)));
    imageCache.clear();
    await _loadImages(focusPath: saved);
  }

  /// [anchor] is the share button's context: iPad (and macOS) present the
  /// share sheet as a popover and share_plus throws without an origin rect.
  Future<void> _share(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final Rect origin;
    if (box != null && box.hasSize && box.attached) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    } else {
      // Fall back to the top-right corner, where the button sits.
      final size = MediaQuery.sizeOf(context);
      origin = Rect.fromLTWH(
        size.width - 64,
        MediaQuery.paddingOf(context).top + 12,
        48,
        48,
      );
    }
    try {
      await SharePlus.instance.share(ShareParams(
        files: [XFile(_current.path)],
        sharePositionOrigin: origin,
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share: $e')),
        );
      }
    }
  }

  void _toggleDetails(BuildContext context) {
    if (AdaptiveSplitView.isSplit(context, minWidthForSplit: 720)) {
      setState(() => _showInfo = !_showInfo);
    } else {
      AppSheet.show<void>(
        context,
    style: SheetStyle.side,
        maxHeightFraction: 0.7,
        child: _ImageInfoPane(file: _current, inSheet: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ImmersiveTheme(child: Builder(builder: _build));
  }

  Widget _build(BuildContext context) {
    // Decode at about twice the screen resolution (room to zoom) instead of
    // the full sensor size.
    final maxSide = (MediaQuery.sizeOf(context).longestSide *
            MediaQuery.devicePixelRatioOf(context) *
            2)
        .round()
        .clamp(2048, 4096);
    final gallery = PhotoViewGallery.builder(
        // PhotoViewGallery keeps the first controller it sees, so a new
        // controller (gallery listed, or reloaded after an edit) needs a new
        // gallery state.
        key: ObjectKey(_pageController),
        scrollPhysics: _textMode
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        pageController: _pageController,
        itemCount: _images.length,
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (context, event) => const ViewerLoading(),
        builder: (context, index) {
          final file = _images[index];
          final text = _text;
          if (text != null && _textPath == file.path) {
            // Drawn at the size the text was read at, with the text on it.
            return PhotoViewGalleryPageOptions.customChild(
              childSize: text.size,
              initialScale: PhotoViewComputedScale.contained,
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4.0,
              heroAttributes: PhotoViewHeroAttributes(tag: file.path),
              disableGestures: _textMode,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image(
                    image: ImageCodec.displayProviderFor(file, maxSide),
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  ),
                  ImageTextLayer(text: text, active: _textMode),
                ],
              ),
            );
          }
          return PhotoViewGalleryPageOptions(
            imageProvider: ImageCodec.displayProviderFor(file, maxSide),
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4.0,
            heroAttributes: PhotoViewHeroAttributes(tag: file.path),
            errorBuilder: (context, error, stack) => _UnsupportedImage(
              file: file,
              error: error,
            ),
          );
        },
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
            _text = null;
            _textMode = false;
          });
          _readText();
        },
    );
    final raw = RawImages.isRaw(_current.path);
    final arrows = Desktop.isDesktop && _images.length > 1;
    // Always the same Stack, so swiping onto a raw doesn't re-parent (and
    // reset) the gallery mid-gesture.
    final galleryWithBadge = Stack(
      fit: StackFit.expand,
      children: [
        // A mouse can drag between images too (Flutter leaves mouse drags
        // out of scrolling by default).
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: PointerDeviceKind.values.toSet(),
          ),
          child: gallery,
        ),
        if (arrows) ...[
          Positioned(
            left: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: _NavButton(
                icon: LucideIcons.chevronLeft,
                tooltip: 'Previous (←)',
                onPressed: _currentIndex > 0
                    ? () => _goTo(_currentIndex - 1)
                    : null,
              ),
            ),
          ),
          Positioned(
            right: 12,
            top: 0,
            bottom: 0,
            child: Center(
              child: _NavButton(
                icon: LucideIcons.chevronRight,
                tooltip: 'Next (→)',
                onPressed: _currentIndex < _images.length - 1
                    ? () => _goTo(_currentIndex + 1)
                    : null,
              ),
            ),
          ),
        ],
        // Text found: select it on the image, or copy all of it.
        if (_text != null && _textPath == _current.path)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom +
                (_images.length > 1 || raw ? 56 : 16),
            child: Center(
              child: _OverlayPill(
                children: [
                  _PillButton(
                    icon: LucideIcons.scanText,
                    label: _textMode ? 'Done' : 'Select text',
                    selected: _textMode,
                    onPressed: _toggleTextMode,
                  ),
                  const _PillDivider(),
                  _PillButton(
                    icon: LucideIcons.copy,
                    label: 'Copy all text',
                    onPressed: _copyText,
                  ),
                ],
              ),
            ),
          ),
        if (_images.length > 1 || raw)
          Positioned(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 16,
            child: IgnorePointer(
              child: Center(
                child: _OverlayPill(
                  children: [
                    if (_images.length > 1)
                      Text('${_currentIndex + 1} / ${_images.length}'),
                    if (_images.length > 1 && raw)
                      const _PillDivider(),
                    if (raw) const Text('RAW · embedded preview'),
                  ],
                ),
              ),
            ),
          ),
      ],
    );

    final infoPane = SizedBox(
      height: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: context.colors.background,
          border: Border(left: BorderSide(color: context.colors.border)),
        ),
        child: _ImageInfoPane(
          key: ValueKey(_current.path),
          file: _current,
          onClose: () => setState(() => _showInfo = false),
        ),
      ),
    );

    final body = _showInfo && AdaptiveSplitView.isSplit(context, minWidthForSplit: 720)
        ? AdaptiveSplitView(
            minWidthForSplit: 720,
            secondaryOnLeading: false,
            secondaryWidth: 320,
            divider: false,
            primary: galleryWithBadge,
            secondary: Padding(
              padding: EdgeInsets.only(
                top: DockedGlossyTopBar.contentTopInset(context),
              ),
              child: infoPane,
            ),
          )
        : galleryWithBadge;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: ExplorerScaffold(
        backgroundColor: Colors.black,
        title: p.basename(_current.path),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
              icon: const Icon(LucideIcons.squarePen),
              tooltip: 'Edit',
              onPressed: _edit,
            ),
            Builder(
              builder: (buttonContext) => AppIconButton(
                icon: const Icon(LucideIcons.share2),
                tooltip: 'Share',
                onPressed: () => _share(buttonContext),
              ),
            ),
            AppIconButton(
              icon: Icon(
                LucideIcons.info,
                color: _showInfo &&
                        AdaptiveSplitView.isSplit(context, minWidthForSplit: 720)
                    ? context.colors.primary
                    : null,
              ),
              tooltip: 'Details',
              onPressed: () => _toggleDetails(context),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: Focus(
          autofocus: true,
          onKeyEvent: (_, event) => _onKey(event),
          child: body,
        ),
      ),
    );
  }
}

/// Round previous/next button over the photo (desktop).
class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !enabled,
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onPressed,
              child: SizedBox.square(
                dimension: 44,
                child: Icon(icon, color: Colors.white, size: 24),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Translucent caption over the photo (counter, raw notice).
class _OverlayPill extends StatelessWidget {
  const _OverlayPill({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: DefaultTextStyle.merge(
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
          child: Row(mainAxisSize: MainAxisSize.min, children: children),
        ),
      ),
    );
  }
}

/// A small text button inside an [_OverlayPill].
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = selected ? colors.primary : colors.foreground;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color)),
          ],
        ),
      ),
    );
  }
}

class _PillDivider extends StatelessWidget {
  const _PillDivider();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: SizedBox(
          width: 1,
          height: 12,
          child: ColoredBox(color: context.colors.border),
        ),
      );
}

class _UnsupportedImage extends StatelessWidget {
  const _UnsupportedImage({required this.file, required this.error});

  final File file;
  final Object error;

  @override
  Widget build(BuildContext context) {
    final raw = RawImages.isRaw(file.path);
    return ViewerMessage(
      icon: raw ? LucideIcons.camera : LucideIcons.imageOff,
      title: raw ? "Can't show this raw photo" : "Can't show this image",
      message: raw
          ? error is RawPreviewUnavailable
              ? "This raw photo doesn't include a preview image. "
                  'Open it in a raw editor to see it.'
              : "This raw photo's preview couldn't be read."
          : "This image format isn't supported on this device.",
      actions: [
        FilledButton.icon(
          icon: const Icon(LucideIcons.externalLink, size: 16),
          label: const Text('Open with another app'),
          onPressed: () => FileOpener.openExternally(context, file),
        ),
      ],
    );
  }
}

class _ImageInfoPane extends StatefulWidget {
  const _ImageInfoPane({
    super.key,
    required this.file,
    this.onClose,
    this.inSheet = false,
  });

  final File file;
  final VoidCallback? onClose;

  /// Inside a bottom sheet, which scrolls and pads its content itself.
  final bool inSheet;

  @override
  State<_ImageInfoPane> createState() => _ImageInfoPaneState();
}

class _ImageInfoPaneState extends State<_ImageInfoPane> {
  Map<String, String>? _details;
  String? _dimensions;
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    (info, _) {
      if (mounted) {
        setState(() => _dimensions = '${info.image.width} × ${info.image.height}');
      }
    },
    onError: (_, _) {},
  );

  @override
  void initState() {
    super.initState();
    // A raw's details carry its raw and preview sizes; don't decode the
    // full preview just to measure it.
    if (!RawImages.isRaw(widget.file.path)) {
      _stream = ImageCodec.providerFor(widget.file)
          .resolve(ImageConfiguration.empty)
        ..addListener(_listener);
    }
    _load();
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  Future<void> _load() async {
    final details = <String, String>{};
    try {
      final stat = await widget.file.stat();
      details['Name'] = p.basename(widget.file.path);
      details['Size'] = filesize(stat.size);
      details['Modified'] = DateFormat.yMMMd().add_jm().format(stat.modified);
      details['Folder'] = widget.file.parent.path;
      details.addAll(await ImageCodec.readExif(widget.file));
    } catch (_) {}
    if (mounted) setState(() => _details = details);
  }

  @override
  Widget build(BuildContext context) {
    final details = _details;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PanelHeader(
          title: 'Details',
          onClose: widget.onClose,
          closeTooltip: 'Hide details',
        ),
        const SizedBox(height: 8),
        if (details == null)
          const ViewerLoading()
        else
          DetailList(
            entries: {
              if (_dimensions != null) 'Dimensions': _dimensions!,
              ...details,
            }.entries,
          ),
      ],
    );
    if (widget.inSheet) return content;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        8,
        16 + MediaQuery.paddingOf(context).bottom,
      ),
      child: content,
    );
  }
}
