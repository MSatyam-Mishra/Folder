import 'dart:io';
import 'dart:typed_data';

import 'package:explorer/core/services/thumbnails/thumbnails.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// A file's picture in a [size]×[size] box: the image itself, or what
/// [Thumbnails] finds (a video frame, a PDF's first page, a document's
/// preview...). [fallback], the file's icon, shows until then, when there
/// is none, and with thumbnails turned off in Options.
class FileThumbnail extends StatefulWidget {
  const FileThumbnail({
    super.key,
    required this.path,
    required this.size,
    required this.fallback,
    this.cover = false,
    this.radius = 4,
  });

  final String path;
  final double size;
  final Widget fallback;

  /// Fills the box (gallery tiles); else the whole picture fits in it.
  final bool cover;
  final double radius;

  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  Future<Uint8List?>? _picture;
  String? _for;

  int get _pixels => (widget.size * MediaQuery.devicePixelRatioOf(context)).round().clamp(32, 1024);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _request();
  }

  @override
  void didUpdateWidget(FileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.size != widget.size) _request();
  }

  void _request() {
    final key = '${widget.path}|$_pixels';
    if (key == _for) return;
    _for = key;
    _picture = Thumbnails.decodesDirectly(widget.path) || !Thumbnails.mayHave(widget.path)
        ? null
        : Thumbnails.load(widget.path, _pixels, wanted: () => mounted);
  }

  Widget _frame(Widget picture) => ClipRRect(
        borderRadius: BorderRadius.circular(widget.radius),
        child: picture,
      );

  @override
  Widget build(BuildContext context) {
    final show = context.select<ThemeCubit, bool>((c) => c.state.showThumbnails);
    final fit = widget.cover ? BoxFit.cover : BoxFit.contain;
    Widget box(Widget child) => SizedBox.square(dimension: widget.size, child: child);
    if (!show) return box(widget.fallback);
    if (Thumbnails.decodesDirectly(widget.path)) {
      return box(Image.file(
        File(widget.path),
        key: ValueKey(widget.path),
        fit: fit,
        cacheWidth: _pixels,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => widget.fallback,
        frameBuilder: (context, child, frame, wasSync) =>
            wasSync || frame != null ? _frame(child) : widget.fallback,
      ));
    }
    final picture = _picture;
    if (picture == null) return box(widget.fallback);
    return box(FutureBuilder<Uint8List?>(
      future: picture,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return widget.fallback;
        return _frame(Image.memory(
          bytes,
          fit: fit,
          cacheWidth: _pixels,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => widget.fallback,
        ));
      },
    ));
  }
}
