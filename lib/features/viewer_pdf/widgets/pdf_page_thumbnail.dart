import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:folder/features/viewer_pdf/services/pdf_page_rasterizer.dart';
import 'package:flutter/material.dart';

/// Small rendered preview of one page, shown with an optional pending
/// rotation. Blank pages (no [pageNumber]) render as an empty sheet.
class PdfPageThumbnail extends StatefulWidget {
  const PdfPageThumbnail({
    super.key,
    required this.rasterizer,
    required this.pageNumber,
    required this.displaySize,
    this.width = 72,
    this.quarterTurns = 0,
    this.highlighted = false,
  });

  final PdfPageRasterizer? rasterizer;

  /// 1-based page number in the rasterized document, or null for blank.
  final int? pageNumber;

  /// Page size as displayed (rotation applied), any unit.
  final Size displaySize;
  final double width;
  final int quarterTurns;
  final bool highlighted;

  /// Box size the thumbnail occupies once [quarterTurns] is applied.
  static Size boxSize(Size displaySize, double width, int quarterTurns) {
    final aspect = displaySize.isEmpty
        ? 1 / math.sqrt2
        : displaySize.width / displaySize.height;
    final sideways = quarterTurns.isOdd;
    final pageHeight = width / aspect;
    return sideways ? Size(pageHeight, width) : Size(width, pageHeight);
  }

  @override
  State<PdfPageThumbnail> createState() => _PdfPageThumbnailState();
}

class _PdfPageThumbnailState extends State<PdfPageThumbnail> {
  ui.Image? _image;
  int _request = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_image == null) _load();
  }

  @override
  void didUpdateWidget(PdfPageThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rasterizer != widget.rasterizer ||
        oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.width != widget.width) {
      _image?.dispose();
      _image = null;
      _load();
    }
  }

  Future<void> _load() async {
    final rasterizer = widget.rasterizer;
    final page = widget.pageNumber;
    if (rasterizer == null || page == null || rasterizer.isClosed) return;
    final request = ++_request;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = widget.displaySize.isEmpty
        ? const Size(1, math.sqrt2)
        : widget.displaySize;
    final width = (widget.width * dpr).clamp(32, 600).round();
    final height = (width * size.height / size.width).round().clamp(32, 1200);
    final image = await rasterizer.render(page, width, height);
    if (!mounted || request != _request) {
      image?.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  @override
  void dispose() {
    _request++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pageSize = PdfPageThumbnail.boxSize(
      widget.displaySize,
      widget.width,
      0,
    );
    final sheet = Container(
      width: pageSize.width,
      height: pageSize.height,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: widget.highlighted
              ? scheme.primary
              : Colors.black.withValues(alpha: 0.15),
          width: widget.highlighted ? 2 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: _image != null
          ? RawImage(image: _image, fit: BoxFit.fill)
          : widget.pageNumber == null
          ? null
          : Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.black.withValues(alpha: 0.3),
                ),
              ),
            ),
    );
    return RotatedBox(quarterTurns: widget.quarterTurns % 4, child: sheet);
  }
}
