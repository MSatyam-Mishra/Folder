import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:folders/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:folders/features/viewer_pdf/services/pdf_document_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdf_page_rasterizer.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_dialogs.dart';
import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

enum PageCanvasTool { hand, select, pen, highlighter, eraser, text }

/// What to do as soon as the canvas opens.
enum PageCanvasStart { none, image, signature }

/// Draw, type and place images/signatures on one page.
///
/// Pops with the list of [PageMark]s to burn into the page, or null when
/// cancelled. Geometry is in PDF points in the page's display orientation.
class PdfPageCanvasScreen extends StatefulWidget {
  const PdfPageCanvasScreen({
    super.key,
    required this.documentBytes,
    required this.pageNumber,
    required this.meta,
    this.initialTool = PageCanvasTool.pen,
    this.start = PageCanvasStart.none,
    this.initialColor = const Color(0xFFF44336),
    this.onApply,
  });

  final Uint8List documentBytes;

  /// 1-based.
  final int pageNumber;
  final PdfPageMeta meta;
  final PageCanvasTool initialTool;
  final PageCanvasStart start;
  final Color initialColor;

  /// Burns the marks into the document. The canvas only closes when this
  /// returns true, so nothing drawn is lost when applying fails.
  final Future<bool> Function(List<PageMark> marks)? onApply;

  @override
  State<PdfPageCanvasScreen> createState() => _PdfPageCanvasScreenState();
}

// ---------------------------------------------------------------------------
// Items
// ---------------------------------------------------------------------------

sealed class _Item {
  const _Item();
}

class _StrokeItem extends _Item {
  const _StrokeItem(this.points, this.color, this.width, this.opacity);

  final List<Offset> points;
  final Color color;
  final double width;
  final double opacity;
}

class _TextItem extends _Item {
  const _TextItem(this.position, this.text, this.fontSize, this.color);

  final Offset position;
  final String text;
  final double fontSize;
  final Color color;

  static const lineHeight = 1.15;

  TextPainter painter() => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(fontSize: fontSize, height: lineHeight, color: color),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  Rect get rect {
    final p = painter();
    final size = p.size;
    p.dispose();
    return position & size;
  }
}

class _ImageItem extends _Item {
  const _ImageItem(this.rect, this.bytes, this.image);

  final Rect rect;
  final Uint8List bytes;
  final ui.Image image;
}

class _SignatureItem extends _Item {
  const _SignatureItem(
    this.rect,
    this.strokes,
    this.color,
    this.strokeFraction,
  );

  final Rect rect;

  /// Points normalised to 0..1 within [rect].
  final List<List<Offset>> strokes;
  final Color color;

  /// Stroke width as a fraction of [rect]'s width.
  final double strokeFraction;

  Iterable<List<Offset>> absoluteStrokes() => strokes.map(
    (stroke) => [
      for (final p in stroke)
        rect.topLeft + Offset(p.dx * rect.width, p.dy * rect.height),
    ],
  );
}

Rect? _boxOf(_Item item) => switch (item) {
  _StrokeItem() => null,
  _TextItem() => item.rect,
  _ImageItem() => item.rect,
  _SignatureItem() => item.rect,
};

_Item _moved(_Item item, Offset delta) => switch (item) {
  _StrokeItem() => item,
  _TextItem() => _TextItem(
    item.position + delta,
    item.text,
    item.fontSize,
    item.color,
  ),
  _ImageItem() => _ImageItem(item.rect.shift(delta), item.bytes, item.image),
  _SignatureItem() => _SignatureItem(
    item.rect.shift(delta),
    item.strokes,
    item.color,
    item.strokeFraction,
  ),
};

/// Scales a box item so its width becomes [width], keeping its aspect ratio.
_Item _resized(_Item item, double width) {
  switch (item) {
    case _StrokeItem():
      return item;
    case _TextItem():
      final ratio = width / math.max(1, item.rect.width);
      final size = (item.fontSize * ratio).clamp(4.0, 200.0);
      return _TextItem(item.position, item.text, size, item.color);
    case _ImageItem():
      final aspect = item.rect.width / item.rect.height;
      return _ImageItem(
        Rect.fromLTWH(item.rect.left, item.rect.top, width, width / aspect),
        item.bytes,
        item.image,
      );
    case _SignatureItem():
      final aspect = item.rect.width / item.rect.height;
      return _SignatureItem(
        Rect.fromLTWH(item.rect.left, item.rect.top, width, width / aspect),
        item.strokes,
        item.color,
        item.strokeFraction,
      );
  }
}

class _Drag {
  _Drag(this.index, this.resize, this.start, this.original);

  final int index;
  final bool resize;
  final Offset start;
  final _Item original;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class _PdfPageCanvasScreenState extends State<PdfPageCanvasScreen> {
  static const _penWidths = [1.0, 2.0, 4.0, 8.0];
  static const _highlighterWidths = [8.0, 14.0, 22.0];
  static const _fontSizes = [10.0, 14.0, 20.0, 28.0, 40.0];

  PdfPageRasterizer? _rasterizer;
  ui.Image? _pageImage;
  String? _error;
  bool _started = false;

  final List<_Item> _items = [];
  final List<List<_Item>> _undo = [];
  final List<ui.Image> _ownedImages = [];
  final TransformationController _zoom = TransformationController();
  int _revision = 0;
  int? _selected;
  late PageCanvasTool _tool = widget.initialTool;
  late Color _color = widget.initialColor;
  double _penWidth = 2;
  double _highlighterWidth = 14;
  double _fontSize = 14;
  List<Offset>? _activeStroke;
  _Drag? _drag;
  bool _erasedInGesture = false;
  bool _applying = false;

  /// Logical pixels per PDF point for the current layout.
  double _scale = 1;

  Size get _pageSize => widget.meta.displaySize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _renderPage();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        switch (widget.start) {
          case PageCanvasStart.image:
            _addImage();
          case PageCanvasStart.signature:
            _addSignature();
          case PageCanvasStart.none:
            break;
        }
      });
    }
  }

  Future<void> _renderPage() async {
    final media = MediaQuery.of(context);
    final longest =
        (math.max(media.size.width, media.size.height) * media.devicePixelRatio)
            .clamp(1000.0, 2600.0);
    final ratio = longest / math.max(_pageSize.width, _pageSize.height);
    final width = (_pageSize.width * ratio).round();
    final height = (_pageSize.height * ratio).round();
    try {
      final rasterizer = await PdfPageRasterizer.open(widget.documentBytes);
      if (!mounted) {
        await rasterizer.close();
        return;
      }
      _rasterizer = rasterizer;
      final image = await rasterizer.render(widget.pageNumber, width, height);
      if (!mounted) {
        image?.dispose();
        return;
      }
      setState(() {
        _pageImage = image;
        if (image == null) _error = 'The page preview could not be rendered.';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'The page preview could not be rendered.');
      }
    }
  }

  @override
  void dispose() {
    _rasterizer?.close();
    _pageImage?.dispose();
    for (final image in _ownedImages) {
      image.dispose();
    }
    _zoom.dispose();
    super.dispose();
  }

  // ---- editing helpers ----------------------------------------------------

  void _pushUndo() {
    _undo.add(List.of(_items));
    if (_undo.length > 60) _undo.removeAt(0);
  }

  void _changed() => setState(() => _revision++);

  void _undoLast() {
    if (_undo.isEmpty) return;
    _items
      ..clear()
      ..addAll(_undo.removeLast());
    _selected = null;
    _changed();
  }

  void _deleteSelected() {
    final index = _selected;
    if (index == null || index >= _items.length) return;
    _pushUndo();
    _items.removeAt(index);
    _selected = null;
    _changed();
  }

  void _setTool(PageCanvasTool tool) {
    setState(() {
      _tool = tool;
      if (tool != PageCanvasTool.select && tool != PageCanvasTool.text) {
        _selected = null;
      }
    });
  }

  ({int index, bool resize})? _hitTest(Offset point) {
    final slop = 8 / _scale;
    final selected = _selected;
    if (selected != null && selected < _items.length) {
      final box = _boxOf(_items[selected]);
      if (box != null && (point - box.bottomRight).distance <= 22 / _scale) {
        return (index: selected, resize: true);
      }
    }
    for (var i = _items.length - 1; i >= 0; i--) {
      final box = _boxOf(_items[i]);
      if (box != null && box.inflate(slop).contains(point)) {
        return (index: i, resize: false);
      }
    }
    return null;
  }

  void _eraseAt(Offset point) {
    final radius = 10 / _scale;
    final before = _items.length;
    _items.removeWhere((item) {
      if (item is! _StrokeItem) return false;
      final reach = radius + item.width / 2;
      final points = item.points;
      if (points.length == 1) return (points.first - point).distance <= reach;
      for (var i = 1; i < points.length; i++) {
        if (_segmentDistance(point, points[i - 1], points[i]) <= reach) {
          return true;
        }
      }
      return false;
    });
    if (_items.length != before) {
      _erasedInGesture = true;
      _selected = null;
      _changed();
    }
  }

  static double _segmentDistance(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared).clamp(
      0.0,
      1.0,
    );
    return (p - (a + ab * t)).distance;
  }

  Offset _toPage(Offset local) => Offset(
    (local.dx / _scale).clamp(0, _pageSize.width),
    (local.dy / _scale).clamp(0, _pageSize.height),
  );

  // ---- gestures -----------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    final point = _toPage(details.localPosition);
    switch (_tool) {
      case PageCanvasTool.pen:
      case PageCanvasTool.highlighter:
        setState(() => _activeStroke = [point]);
      case PageCanvasTool.eraser:
        _pushUndo();
        _erasedInGesture = false;
        _eraseAt(point);
      case PageCanvasTool.select:
      case PageCanvasTool.text:
        final hit = _hitTest(point);
        if (hit == null) {
          if (_selected != null) setState(() => _selected = null);
          return;
        }
        _pushUndo();
        _drag = _Drag(hit.index, hit.resize, point, _items[hit.index]);
        setState(() => _selected = hit.index);
      case PageCanvasTool.hand:
        break;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final point = _toPage(details.localPosition);
    final stroke = _activeStroke;
    if (stroke != null) {
      if ((stroke.last - point).distance * _scale >= 1.5) {
        stroke.add(point);
        _changed();
      }
      return;
    }
    if (_tool == PageCanvasTool.eraser) {
      _eraseAt(point);
      return;
    }
    final drag = _drag;
    if (drag == null) return;
    final delta = point - drag.start;
    final original = drag.original;
    if (drag.resize) {
      final box = _boxOf(original)!;
      final width = math.max(12 / _scale, box.width + delta.dx);
      _items[drag.index] = _resized(original, width);
    } else {
      _items[drag.index] = _moved(original, delta);
    }
    _changed();
  }

  void _onPanEnd() {
    final stroke = _activeStroke;
    if (stroke != null) {
      _activeStroke = null;
      _addStroke(stroke);
      return;
    }
    if (_tool == PageCanvasTool.eraser &&
        !_erasedInGesture &&
        _undo.isNotEmpty) {
      _undo.removeLast();
    }
    _drag = null;
  }

  void _addStroke(List<Offset> points) {
    final highlighter = _tool == PageCanvasTool.highlighter;
    _pushUndo();
    _items.add(
      _StrokeItem(
        points,
        _color,
        highlighter ? _highlighterWidth : _penWidth,
        highlighter ? 0.4 : 1,
      ),
    );
    _changed();
  }

  Future<void> _onTapUp(TapUpDetails details) async {
    final point = _toPage(details.localPosition);
    switch (_tool) {
      case PageCanvasTool.pen:
      case PageCanvasTool.highlighter:
        _addStroke([point]);
      case PageCanvasTool.eraser:
        _pushUndo();
        _erasedInGesture = false;
        _eraseAt(point);
        if (!_erasedInGesture) _undo.removeLast();
      case PageCanvasTool.select:
        final hit = _hitTest(point);
        setState(() => _selected = hit?.index);
      case PageCanvasTool.text:
        final hit = _hitTest(point);
        if (hit != null && _items[hit.index] is _TextItem) {
          setState(() => _selected = hit.index);
          await _editText(hit.index);
        } else {
          await _addText(point);
        }
      case PageCanvasTool.hand:
        break;
    }
  }

  // ---- adding content -----------------------------------------------------

  Future<void> _addText(Offset at) async {
    final text = await showPdfTextInputDialog(
      context,
      title: 'Add text',
      hint: 'Type the text to place on the page',
      confirmLabel: 'Add',
      multiline: true,
    );
    if (text == null || text.isEmpty || !mounted) return;
    _pushUndo();
    var item = _TextItem(at, text, _fontSize, _color);
    // Keep the box on the page.
    final rect = item.rect;
    final dx = math.min(0.0, _pageSize.width - rect.right);
    final dy = math.min(0.0, _pageSize.height - rect.bottom);
    if (dx != 0 || dy != 0) {
      item = _moved(item, Offset(dx, dy)) as _TextItem;
    }
    _items.add(item);
    _selected = _items.length - 1;
    _changed();
  }

  Future<void> _editText(int index) async {
    final item = _items[index];
    if (item is! _TextItem) return;
    final text = await showPdfTextInputDialog(
      context,
      title: 'Edit text',
      initialText: item.text,
      confirmLabel: 'Save',
      multiline: true,
    );
    if (text == null || !mounted || index >= _items.length) return;
    _pushUndo();
    if (text.isEmpty) {
      _items.removeAt(index);
      _selected = null;
    } else {
      _items[index] = _TextItem(item.position, text, item.fontSize, item.color);
    }
    _changed();
  }

  Future<void> _addImage() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
    } catch (e) {
      _showMessage('Could not open the image picker');
      return;
    }
    final file = result?.files.singleOrNull;
    if (file == null || !mounted) return;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (_) {}
    }
    if (bytes == null) {
      _showMessage('Could not read that image');
      return;
    }
    ui.Image image;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
      codec.dispose();
    } catch (_) {
      _showMessage('That image format is not supported');
      return;
    }
    if (!mounted) {
      image.dispose();
      return;
    }
    _ownedImages.add(image);
    final aspect = image.width / math.max(1, image.height);
    var width = _pageSize.width * 0.4;
    var height = width / aspect;
    if (height > _pageSize.height * 0.5) {
      height = _pageSize.height * 0.5;
      width = height * aspect;
    }
    final rect = Rect.fromCenter(
      center: _pageSize.center(Offset.zero),
      width: width,
      height: height,
    );
    _pushUndo();
    _items.add(_ImageItem(rect, bytes, image));
    _selected = _items.length - 1;
    _tool = PageCanvasTool.select;
    _changed();
  }

  Future<void> _addSignature() async {
    final signature = await showDialog<_SignatureResult>(
      context: context,
      builder: (context) => _SignaturePadDialog(color: _color),
    );
    if (signature == null || !mounted) return;
    var width = _pageSize.width * 0.35;
    var height = width / signature.aspect;
    if (height > _pageSize.height * 0.3) {
      height = _pageSize.height * 0.3;
      width = height * signature.aspect;
    }
    final rect = Rect.fromCenter(
      center: _pageSize.center(Offset.zero),
      width: width,
      height: height,
    );
    _pushUndo();
    _items.add(
      _SignatureItem(
        rect,
        signature.strokes,
        signature.color,
        signature.strokeFraction,
      ),
    );
    _selected = _items.length - 1;
    _tool = PageCanvasTool.select;
    _changed();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickColor() async {
    final color = await showPdfColorPicker(context, _color);
    if (color == null || !mounted) return;
    setState(() => _color = color);
    final index = _selected;
    if (index == null || index >= _items.length) return;
    final item = _items[index];
    _pushUndo();
    _items[index] = switch (item) {
      _TextItem() => _TextItem(item.position, item.text, item.fontSize, color),
      _SignatureItem() => _SignatureItem(
        item.rect,
        item.strokes,
        color,
        item.strokeFraction,
      ),
      _ => item,
    };
    _changed();
  }

  Future<List<PageMark>> _marks() async {
    final marks = <PageMark>[];
    for (final item in _items) {
      switch (item) {
        case _StrokeItem():
          marks.add(
            InkMark(
              points: item.points,
              color: item.color,
              width: item.width,
              opacity: item.opacity,
            ),
          );
        case _TextItem():
          marks.add(
            PdfDocumentOps.canEmbedText(item.text)
                ? TextMark(
                    position: item.position,
                    text: item.text,
                    fontSize: item.fontSize,
                    color: item.color,
                  )
                : await _textAsImage(item),
          );
        case _ImageItem():
          marks.add(
            ImageMark(
              rect: item.rect,
              bytes: await PdfDocumentOps.imageForPdf(item.bytes, item.image),
            ),
          );
        case _SignatureItem():
          for (final stroke in item.absoluteStrokes()) {
            marks.add(
              InkMark(
                points: stroke,
                color: item.color,
                width: math.max(0.5, item.strokeFraction * item.rect.width),
              ),
            );
          }
      }
    }
    return marks;
  }

  /// Text the PDF fonts can't show (non-Latin scripts, emoji, or anything
  /// beyond Latin-1 on iOS) is placed as an image drawn exactly like the
  /// preview, at about 300 dpi.
  static Future<ImageMark> _textAsImage(_TextItem item) async {
    final painter = item.painter();
    final size = painter.size;
    final scale = math.min(
      300 / 72,
      4096 / math.max(1.0, math.max(size.width, size.height)),
    );
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder)..scale(scale), Offset.zero);
    painter.dispose();
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      math.max(1, (size.width * scale).ceil()),
      math.max(1, (size.height * scale).ceil()),
    );
    picture.dispose();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw const FormatException('Text could not be drawn');
      return ImageMark(
        rect: item.position & size,
        bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  }

  Future<void> _apply() async {
    if (_applying || _items.isEmpty) return;
    setState(() {
      _applying = true;
      _activeStroke = null;
      _drag = null;
    });
    List<PageMark>? marks;
    var applied = false;
    try {
      marks = await _marks();
      final onApply = widget.onApply;
      applied = onApply == null || await onApply(marks);
    } catch (e) {
      debugPrint('PdfPageCanvasScreen: preparing the page failed: $e');
      _showMessage("Couldn't prepare what you added. Nothing was lost.");
    }
    if (!mounted) return;
    if (applied) {
      Navigator.pop(context, marks);
      return;
    }
    // The owner reported the failure; keep everything so the user can retry
    // or remove the item that fails.
    setState(() => _applying = false);
  }

  Future<bool> _confirmDiscard() async {
    if (_items.isEmpty) return true;
    return showPdfConfirmDialog(
      context,
      title: 'Discard changes?',
      message: 'What you added to this page will be lost.',
      confirmLabel: 'Discard',
      destructive: true,
    );
  }

  // ---- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _items.isEmpty && !_applying,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _applying) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: ExplorerScaffold(
        title: 'Page ${widget.pageNumber}',
        trailing: ViewerActions(
          children: [
            ViewerAction(
              icon: LucideIcons.scan,
              tooltip: 'Reset zoom',
              onPressed: () => setState(() => _zoom.value = Matrix4.identity()),
            ),
            const SizedBox(width: 4),
            Tooltip(
              message: 'Apply to page',
              child: FilledButton.icon(
                onPressed: _items.isEmpty || _applying ? null : _apply,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                icon: _applying
                    ? ViewerSpinner(
                        size: 14,
                        color: context.colors.primaryForeground,
                      )
                    : const Icon(LucideIcons.check, size: 16),
                label: const Text('Apply'),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: AbsorbPointer(absorbing: _applying, child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final padding = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: ViewerSurface.canvas(context),
      child: Padding(
        padding: EdgeInsets.only(
          top: top,
          left: padding.left,
          right: padding.right,
        ),
        child: Column(
          children: [
            Expanded(child: _buildPageArea(context)),
            Padding(
              padding: EdgeInsets.fromLTRB(8, 4, 8, 8 + padding.bottom),
              child: Center(child: _buildToolbar(context)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageArea(BuildContext context) {
    if (_error != null) {
      return ViewerMessage(
        icon: LucideIcons.fileWarning,
        title: "Couldn't show this page",
        message: _error,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = 16.0;
        final available = Size(
          math.max(1, constraints.maxWidth - margin * 2),
          math.max(1, constraints.maxHeight - margin * 2),
        );
        _scale = math.min(
          available.width / _pageSize.width,
          available.height / _pageSize.height,
        );
        final pageSize = _pageSize * _scale;
        final hand = _tool == PageCanvasTool.hand;
        final colors = context.colors;

        final page = Container(
          width: pageSize.width,
          height: pageSize.height,
          decoration: ViewerSurface.page(context),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: hand ? null : _onPanStart,
            onPanUpdate: hand ? null : _onPanUpdate,
            onPanEnd: hand ? null : (_) => _onPanEnd(),
            onPanCancel: hand ? null : _onPanEnd,
            onTapUp: hand ? null : _onTapUp,
            onDoubleTap: _tool == PageCanvasTool.select
                ? () {
                    final index = _selected;
                    if (index != null && _items[index] is _TextItem) {
                      _editText(index);
                    }
                  }
                : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_pageImage != null)
                  RawImage(image: _pageImage, fit: BoxFit.fill)
                else
                  const Center(
                    child: ViewerSpinner(size: 22, color: Color(0xFF9CA3AF)),
                  ),
                CustomPaint(
                  painter: _CanvasPainter(
                    items: _items,
                    revision: _revision,
                    active: _activeStroke,
                    activeColor: _color,
                    activeWidth: _tool == PageCanvasTool.highlighter
                        ? _highlighterWidth
                        : _penWidth,
                    activeOpacity: _tool == PageCanvasTool.highlighter
                        ? 0.4
                        : 1,
                    selected: _selected,
                    scale: _scale,
                    selectionColor: colors.ring,
                  ),
                ),
              ],
            ),
          ),
        );

        final content = Center(child: page);
        if (hand) {
          return InteractiveViewer(
            transformationController: _zoom,
            minScale: 1,
            maxScale: 6,
            child: SizedBox.expand(child: content),
          );
        }
        return ClipRect(
          child: Transform(
            transform: _zoom.value,
            child: SizedBox.expand(child: content),
          ),
        );
      },
    );
  }

  Widget _buildToolbar(BuildContext context) {
    final colors = context.colors;
    final compact = MediaQuery.sizeOf(context).width < 480;
    final size = compact ? 34.0 : 40.0;
    final iconSize = compact ? 18.0 : 20.0;
    final gap = compact ? 2.0 : 4.0;
    final selected = _selected != null && _selected! < _items.length
        ? _items[_selected!]
        : null;

    Widget tool(PageCanvasTool value, IconData icon, String tooltip) {
      return ViewerAction(
        tooltip: tooltip,
        icon: icon,
        size: size,
        iconSize: iconSize,
        selected: _tool == value,
        onPressed: () => _setTool(value),
      );
    }

    Widget action(
      IconData icon,
      String tooltip,
      VoidCallback? onPressed, {
      bool destructive = false,
    }) {
      return ViewerAction(
        tooltip: tooltip,
        icon: icon,
        size: size,
        iconSize: iconSize,
        color: destructive && onPressed != null ? colors.destructive : null,
        onPressed: onPressed,
      );
    }

    final textTool = _tool == PageCanvasTool.text;
    final sizeOptions = switch (_tool) {
      PageCanvasTool.highlighter => _highlighterWidths,
      PageCanvasTool.text => _fontSizes,
      _ => _penWidths,
    };
    final currentSize = switch (_tool) {
      PageCanvasTool.highlighter => _highlighterWidth,
      PageCanvasTool.text => _fontSize,
      _ => _penWidth,
    };
    String sizeLabel(double size) =>
        '${size % 1 == 0 ? size.round() : size} pt';

    final sizeMenu = ViewerMenuButton<double>(
      tooltip: textTool ? 'Text size' : 'Line width',
      minMenuWidth: 140,
      onSelected: (value) => setState(() {
        switch (_tool) {
          case PageCanvasTool.highlighter:
            _highlighterWidth = value;
          case PageCanvasTool.text:
            _fontSize = value;
          default:
            _penWidth = value;
        }
      }),
      itemBuilder: (context) => [
        for (final size in sizeOptions)
          viewerMenuItem(
            value: size,
            label: textTool
                ? '${sizeLabel(size)} text'
                : '${sizeLabel(size)} line',
            icon: textTool ? LucideIcons.type : LucideIcons.penLine,
            checked: size == currentSize,
          ),
      ],
      child: SizedBox(
        height: size,
        width: compact ? size : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                textTool
                    ? LucideIcons.aLargeSmall
                    : LucideIcons.slidersHorizontal,
                size: compact ? iconSize : 16,
                color: colors.foreground,
              ),
              // Phones: the size shows in the menu.
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(
                  sizeLabel(currentSize),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: colors.foreground),
                ),
                Icon(
                  LucideIcons.chevronDown,
                  size: 14,
                  color: colors.mutedForeground,
                ),
              ],
            ],
          ),
        ),
      ),
    );

    final addMenu = ViewerMenuButton<VoidCallback>(
      tooltip: 'Add to page',
      icon: LucideIcons.plus,
      size: size,
      minMenuWidth: 200,
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        viewerMenuItem(
          value: _addImage,
          icon: LucideIcons.imagePlus,
          label: 'Add image or stamp',
        ),
        viewerMenuItem(
          value: _addSignature,
          icon: LucideIcons.signature,
          label: 'Add signature',
        ),
      ],
    );

    return AppPanel(
      translucent: true,
      padding: const EdgeInsets.all(4),
      child: Material(
        type: MaterialType.transparency,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    tool(
                      PageCanvasTool.hand,
                      LucideIcons.hand,
                      'Move and zoom',
                    ),
                    tool(
                      PageCanvasTool.select,
                      LucideIcons.mousePointer2,
                      'Select',
                    ),
                    tool(PageCanvasTool.pen, LucideIcons.penTool, 'Pen'),
                    tool(
                      PageCanvasTool.highlighter,
                      LucideIcons.highlighter,
                      'Highlighter',
                    ),
                    tool(PageCanvasTool.eraser, LucideIcons.eraser, 'Eraser'),
                    tool(PageCanvasTool.text, LucideIcons.type, 'Text'),
                    ViewerToolDivider(spacing: gap),
                    if (compact)
                      addMenu
                    else ...[
                      action(
                        LucideIcons.imagePlus,
                        'Add image or stamp',
                        _addImage,
                      ),
                      action(
                        LucideIcons.signature,
                        'Add signature',
                        _addSignature,
                      ),
                    ],
                    ViewerToolDivider(spacing: gap),
                    IconButton(
                      tooltip: 'Colour',
                      constraints: BoxConstraints.tightFor(
                        width: size,
                        height: size,
                      ),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: _pickColor,
                      icon: ViewerSwatch(color: _color, size: iconSize),
                    ),
                    sizeMenu,
                  ],
                ),
              ),
            ),
            ViewerToolDivider(spacing: gap),
            if (selected is _TextItem)
              action(
                LucideIcons.squarePen,
                'Edit text',
                () => _editText(_selected!),
              ),
            if (selected != null)
              action(
                LucideIcons.trash2,
                'Delete',
                _deleteSelected,
                destructive: true,
              ),
            action(LucideIcons.undo2, 'Undo', _undo.isEmpty ? null : _undoLast),
          ],
        ),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  _CanvasPainter({
    required this.items,
    required this.revision,
    required this.active,
    required this.activeColor,
    required this.activeWidth,
    required this.activeOpacity,
    required this.selected,
    required this.scale,
    required this.selectionColor,
  });

  final List<_Item> items;
  final int revision;
  final List<Offset>? active;
  final Color activeColor;
  final double activeWidth;
  final double activeOpacity;
  final int? selected;
  final double scale;
  final Color selectionColor;

  static void _paintStroke(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
    double opacity,
  ) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * opacity)
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    if (points.length == 1) {
      canvas.drawCircle(
        points.first,
        width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    for (final item in items) {
      switch (item) {
        case _StrokeItem():
          _paintStroke(
            canvas,
            item.points,
            item.color,
            item.width,
            item.opacity,
          );
        case _TextItem():
          final painter = item.painter();
          painter.paint(canvas, item.position);
          painter.dispose();
        case _ImageItem():
          canvas.drawImageRect(
            item.image,
            Rect.fromLTWH(
              0,
              0,
              item.image.width.toDouble(),
              item.image.height.toDouble(),
            ),
            item.rect,
            Paint()..filterQuality = FilterQuality.medium,
          );
        case _SignatureItem():
          final width = math.max(0.5, item.strokeFraction * item.rect.width);
          for (final stroke in item.absoluteStrokes()) {
            _paintStroke(canvas, stroke, item.color, width, 1);
          }
      }
    }
    final stroke = active;
    if (stroke != null) {
      _paintStroke(canvas, stroke, activeColor, activeWidth, activeOpacity);
    }
    canvas.restore();

    final index = selected;
    if (index != null && index < items.length) {
      final box = _boxOf(items[index]);
      if (box != null) {
        final rect = Rect.fromLTRB(
          box.left * scale,
          box.top * scale,
          box.right * scale,
          box.bottom * scale,
        ).inflate(4);
        canvas.drawRect(
          rect,
          Paint()
            ..color = selectionColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        canvas.drawCircle(
          rect.bottomRight,
          8,
          Paint()..color = const Color(0xFFFFFFFF),
        );
        canvas.drawCircle(
          rect.bottomRight,
          8,
          Paint()
            ..color = selectionColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CanvasPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.scale != scale ||
      oldDelegate.selected != selected ||
      oldDelegate.active != active ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.selectionColor != selectionColor;
}

// ---------------------------------------------------------------------------
// Signature pad
// ---------------------------------------------------------------------------

class _SignatureResult {
  const _SignatureResult(
    this.strokes,
    this.aspect,
    this.strokeFraction,
    this.color,
  );

  final List<List<Offset>> strokes;
  final double aspect;
  final double strokeFraction;
  final Color color;
}

class _SignaturePadDialog extends StatefulWidget {
  const _SignaturePadDialog({required this.color});

  final Color color;

  @override
  State<_SignaturePadDialog> createState() => _SignaturePadDialogState();
}

class _SignaturePadDialogState extends State<_SignaturePadDialog> {
  static const _strokeWidth = 3.0;
  final List<List<Offset>> _strokes = [];
  late Color _color = widget.color.computeLuminance() > 0.8
      ? const Color(0xFF1A237E)
      : widget.color;

  _SignatureResult? _result() {
    final points = _strokes.expand((s) => s).toList();
    if (points.isEmpty) return null;
    var bounds = Rect.fromPoints(points.first, points.first);
    for (final p in points) {
      bounds = bounds.expandToInclude(Rect.fromPoints(p, p));
    }
    bounds = bounds.inflate(_strokeWidth);
    final width = math.max(1.0, bounds.width);
    final height = math.max(1.0, bounds.height);
    return _SignatureResult(
      [
        for (final stroke in _strokes)
          [
            for (final p in stroke)
              Offset(
                (p.dx - bounds.left) / width,
                (p.dy - bounds.top) / height,
              ),
          ],
      ],
      width / height,
      _strokeWidth / width,
      _color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      title: const Text('Draw your signature'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Signing happens on paper: white in both modes.
            AspectRatio(
              aspectRatio: 2.4,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.input),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (d) =>
                        setState(() => _strokes.add([d.localPosition])),
                    onPanUpdate: (d) =>
                        setState(() => _strokes.last.add(d.localPosition)),
                    child: CustomPaint(
                      painter: _SignaturePainter(
                        List.of(_strokes),
                        _color,
                        _strokeWidth,
                      ),
                      child: _strokes.isEmpty
                          ? const Center(
                              child: Text(
                                'Sign here',
                                style: TextStyle(color: Color(0xFF9CA3AF)),
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Compact swatches that wrap: a 360dp phone leaves ~248dp here.
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    children: [
                      for (final color in const [
                        Color(0xFF000000),
                        Color(0xFF1A237E),
                        Color(0xFF2196F3),
                        Color(0xFFF44336),
                      ])
                        IconButton(
                          tooltip: 'Ink colour',
                          constraints: const BoxConstraints.tightFor(
                            width: 40,
                            height: 40,
                          ),
                          padding: EdgeInsets.zero,
                          onPressed: () => setState(() => _color = color),
                          icon: ViewerSwatch(
                            color: color,
                            size: 22,
                            selected: _color == color,
                          ),
                        ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: _strokes.isEmpty
                      ? null
                      : () => setState(_strokes.clear),
                  icon: const Icon(LucideIcons.eraser, size: 16),
                  label: const Text('Clear'),
                ),
              ],
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
          onPressed: _strokes.isEmpty
              ? null
              : () => Navigator.pop(context, _result()),
          child: const Text('Place'),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.strokes, this.color, this.width);

  final List<List<Offset>> strokes;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _CanvasPainter._paintStroke(canvas, stroke, color, width, 1);
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) => true;
}
