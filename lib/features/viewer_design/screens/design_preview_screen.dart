import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/formats/design_preview.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/features/viewer_design/services/design_pdf_renderer.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Shows the preview embedded in design, CAD and print files (Illustrator,
/// EPS/PostScript, InDesign, Figma, AutoCAD, Sketch, Krita, OpenRaster,
/// Procreate, CorelDRAW, XD, Affinity, Pages/Numbers) with their details.
///
/// The first frame shows the title and a placeholder; the file is read in a
/// background isolate. PDF-compatible files (Illustrator) are additionally
/// rendered from their first page.
class DesignPreviewScreen extends StatefulWidget {
  const DesignPreviewScreen({super.key, required this.file});

  final File file;

  @override
  State<DesignPreviewScreen> createState() => _DesignPreviewScreenState();
}

enum _Action { openAsPdf, openEmbeddedPdf, viewSource, openWith }

class _DesignPreviewScreenState extends State<DesignPreviewScreen> {
  static const _splitWidth = 720.0;

  /// Bigger PostScript files are slow in the text editor.
  static const _maxSourceBytes = 32 << 20;

  DesignPreview? _preview;
  ui.Image? _page;
  bool _rendering = false;
  FileStat? _stat;

  /// Null until toggled: the panel is docked by default on wide screens.
  bool? _showInfo;
  Directory? _tempDir;
  File? _embeddedPdf;
  final TransformationController _transform = TransformationController();
  Offset? _doubleTapAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _page?.dispose();
    _transform.dispose();
    final dir = _tempDir;
    if (dir != null) {
      dir.delete(recursive: true).catchError((_) => dir);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final path = widget.file.path;
    widget.file.stat().then((s) {
      if (mounted) setState(() => _stat = s);
    }, onError: (_) {});

    DesignPreview preview;
    try {
      preview = await _readInBackground(path);
    } catch (e) {
      preview = DesignPreview(
        format: DesignPreviewReader.formatName(FileTypes.extensionOf(path)),
        note: "This file couldn't be read: $e",
      );
    }
    if (!mounted) return;
    setState(() => _preview = preview);

    if (preview.pdfCompatible) {
      await _renderPdf(path, preview);
    } else if (preview.embeddedPdf != null) {
      try {
        final dir = await Directory.systemTemp.createTemp('design_preview_');
        _tempDir = dir;
        final pdf = File(p.join(
          dir.path,
          '${p.basenameWithoutExtension(path)} (preview).pdf',
        ));
        await pdf.writeAsBytes(preview.embeddedPdf!, flush: true);
        if (!mounted) return;
        setState(() => _embeddedPdf = pdf);
        await _renderPdf(pdf.path, preview);
      } catch (_) {
        // The embedded thumbnail is still shown.
      }
    }
  }

  /// Static, so the isolate's closure captures only [path] (a closure made
  /// in an instance method can drag `this`, and the widget tree, along).
  static Future<DesignPreview> _readInBackground(String path) =>
      Isolate.run(() => DesignPreviewReader.read(path));

  Future<void> _renderPdf(String path, DesignPreview preview) async {
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final maxSide = (size.longestSide * dpr * 1.5).round().clamp(1200, 2560);
    double? aspect;
    if (preview.pageWidth != null && preview.pageHeight != null) {
      aspect = preview.pageWidth! / preview.pageHeight!;
    } else if (preview.imageWidth != null && preview.imageHeight != null) {
      aspect = preview.imageWidth! / preview.imageHeight!;
    }
    setState(() => _rendering = true);
    ui.Image? image;
    try {
      image = await DesignPdfRenderer.renderFirstPage(
        path,
        maxSide: maxSide,
        fallbackAspect: aspect,
      );
    } catch (_) {}
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _rendering = false;
      if (image != null) {
        _page?.dispose();
        _page = image;
        _transform.value = Matrix4.identity();
      }
    });
  }

  List<_Action> get _actions {
    final preview = _preview;
    final size = _stat?.size ?? 0;
    return [
      if (preview?.pdfCompatible ?? false) _Action.openAsPdf,
      if (_embeddedPdf != null) _Action.openEmbeddedPdf,
      if ((preview?.postScript ?? false) && size <= _maxSourceBytes)
        _Action.viewSource,
      _Action.openWith,
    ];
  }

  static (IconData, String) _describe(_Action action) => switch (action) {
        _Action.openAsPdf => (LucideIcons.fileText, 'Open as PDF'),
        _Action.openEmbeddedPdf => (
            LucideIcons.fileText,
            'Open preview PDF',
          ),
        _Action.viewSource => (LucideIcons.code, 'View source'),
        _Action.openWith => (LucideIcons.externalLink, 'Open with another app'),
      };

  Future<void> _run(_Action action) async {
    switch (action) {
      case _Action.openAsPdf:
        await FileOpener.openAs(context, widget.file, FileKind.pdf);
      case _Action.openEmbeddedPdf:
        final pdf = _embeddedPdf;
        if (pdf != null) await FileOpener.openAs(context, pdf, FileKind.pdf);
      case _Action.viewSource:
        await FileOpener.openAs(context, widget.file, FileKind.text);
      case _Action.openWith:
        await FileOpener.openExternally(context, widget.file);
    }
  }

  /// [anchor] is the share button's context: iPad (and macOS) present the
  /// share sheet as a popover and need its rect.
  Future<void> _share(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    final Rect origin;
    if (box != null && box.hasSize && box.attached) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    } else {
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
        files: [XFile(widget.file.path)],
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

  void _toggleDetails(bool split) {
    if (split) {
      setState(() => _showInfo = !(_showInfo ?? true));
      return;
    }
    AppSheet.show<void>(
      context,
    style: SheetStyle.side,
      maxHeightFraction: 0.75,
      child: _DetailsPanel(
        file: widget.file,
        preview: _preview,
        stat: _stat,
        shown: _shownLabel,
        inSheet: true,
      ),
    );
  }

  String? get _shownLabel {
    final page = _page;
    return page == null
        ? null
        : 'Page 1 rendered at ${page.width} × ${page.height} px';
  }

  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
      return;
    }
    final at = _doubleTapAt;
    if (at == null) return;
    const scale = 2.5;
    _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
      ..setTranslationRaw(-at.dx * (scale - 1), -at.dy * (scale - 1), 0);
  }

  @override
  Widget build(BuildContext context) {
    final split = AdaptiveSplitView.isSplit(
      context,
      minWidthForSplit: _splitWidth,
    );
    final showPanel = split && (_showInfo ?? true);
    final actions = _actions;
    final primary = actions.where((a) => a != _Action.openWith).toList();
    final colors = context.colors;

    final canvas = _buildCanvas(context, actions);
    final body = showPanel
        ? AdaptiveSplitView(
            minWidthForSplit: _splitWidth,
            secondaryOnLeading: false,
            secondaryWidth: 340,
            primary: canvas,
            secondary: _DetailsPanel(
              file: widget.file,
              preview: _preview,
              stat: _stat,
              shown: _shownLabel,
              onClose: () => setState(() => _showInfo = false),
            ),
          )
        : canvas;

    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final action in primary.take(split ? 2 : 1))
            AppIconButton(
              icon: Icon(_describe(action).$1),
              tooltip: _describe(action).$2,
              onPressed: () => _run(action),
            ),
          Builder(
            builder: (buttonContext) => AppIconButton(
              icon: const Icon(LucideIcons.share2),
              tooltip: 'Share',
              onPressed: () => _share(buttonContext),
            ),
          ),
          ToolButton(
            icon: split ? LucideIcons.panelRight : LucideIcons.info,
            tooltip: 'Details',
            size: 40,
            iconSize: 20,
            selected: showPanel,
            color: colors.foreground,
            onPressed: () => _toggleDetails(split),
          ),
          MenuIconButton<_Action>(
            onSelected: _run,
            itemBuilder: (_) => [
              for (final action in actions)
                menuItem(
                  value: action,
                  icon: _describe(action).$1,
                  label: _describe(action).$2,
                ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: DockedGlossyTopBar.contentTopInset(context),
        ),
        child: body,
      ),
    );
  }

  Widget _buildCanvas(BuildContext context, List<_Action> actions) {
    final preview = _preview;
    if (preview == null) {
      return const _Skeleton(label: 'Reading preview…');
    }
    final page = _page;
    final bytes = preview.image;
    if (page == null && bytes == null) {
      if (_rendering) return const _Skeleton(label: 'Rendering page 1…');
      return _EmptyState(
        preview: preview,
        actions: actions,
        describe: _describe,
        onAction: _run,
      );
    }

    final maxSide = (MediaQuery.sizeOf(context).longestSide *
            MediaQuery.devicePixelRatioOf(context) *
            2)
        .round()
        .clamp(1024, 4096);
    final double aspect;
    final Widget picture;
    if (page != null) {
      aspect = page.width / page.height;
      picture = RawImage(
        image: page,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    } else {
      aspect = (preview.imageWidth ?? 1) / (preview.imageHeight ?? 1);
      picture = Image(
        image: ResizeImage(
          MemoryImage(bytes!),
          width: maxSide,
          height: maxSide,
          policy: ResizeImagePolicy.fit,
          allowUpscaling: false,
        ),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => Center(
          child: Icon(
            LucideIcons.imageOff,
            size: 40,
            color: context.colors.mutedForeground,
          ),
        ),
      );
    }

    final label = page != null
        ? 'Page 1 · rendered'
        : '${preview.imageSource ?? 'Embedded preview'} · '
            '${preview.imageWidth} × ${preview.imageHeight}';
    final colors = context.colors;

    return ColoredBox(
      color: colors.muted.withValues(alpha: 0.6),
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: _toggleZoom,
              child: InteractiveViewer(
                transformationController: _transform,
                minScale: 1,
                maxScale: 12,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 64),
                    child: AspectRatio(
                      aspectRatio: aspect.isFinite && aspect > 0 ? aspect : 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: colors.border),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: context.isDarkMode ? 0.3 : 0.06,
                              ),
                              blurRadius: 12,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: CustomPaint(
                          painter: const _CheckerboardPainter(),
                          child: picture,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 12,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: _Chip(label: label, busy: _rendering),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small caption pill over the canvas.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.busy = false});

  final String label;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                busy ? '$label · rendering page 1…' : label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.foreground,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Transparent areas of previews show as a light checkerboard (artwork is
/// usually made for paper, so it stays light in dark mode too).
class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final dark = Paint()..color = const Color(0xFFEBEBEB);
    const cell = 10.0;
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = ((y / cell).floor().isOdd ? cell : 0.0);
          x < size.width;
          x += cell * 2) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, cell, cell).intersect(Offset.zero & size),
          dark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerboardPainter oldDelegate) => false;
}

/// Placeholder shown on the first frame while the file is read.
class _Skeleton extends StatefulWidget {
  const _Skeleton({required this.label});

  final String label;

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: colors.muted.withValues(alpha: 0.6),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeTransition(
                opacity: Tween(begin: 0.4, end: 1.0).animate(_pulse),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.background,
                        border: Border.all(color: colors.border),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.mutedForeground,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// No preview: what the file is, why there's nothing to show, and what the
/// user can do instead.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.preview,
    required this.actions,
    required this.describe,
    required this.onAction,
  });

  final DesignPreview preview;
  final List<_Action> actions;
  final (IconData, String) Function(_Action) describe;
  final ValueChanged<_Action> onAction;

  @override
  Widget build(BuildContext context) {
    const keys = [
      'Created with',
      'Saved as',
      'DWG version',
      'Artwork size',
      'Dimensions',
      'Canvas size',
      'Pages',
      'Title',
    ];
    final summary = [
      for (final k in keys)
        if (preview.details[k] != null) MapEntry(k, preview.details[k]!),
    ].take(4).toList();
    final message = preview.note ??
        (preview.pdfCompatible
            ? "The artwork couldn't be rendered here. Try opening it as a PDF."
            : null);

    return ColoredBox(
      color: context.colors.muted.withValues(alpha: 0.6),
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: AppPanel(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ViewerMessage(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(top: 20),
                    icon: LucideIcons.penTool,
                    title: 'No preview to show',
                    message: [preview.format, ?message].join('\n'),
                  ),
                  if (summary.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    DetailList(entries: summary, labelWidth: 110),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final action in actions)
                        action == actions.first
                            ? FilledButton.icon(
                                onPressed: () => onAction(action),
                                icon: Icon(describe(action).$1, size: 16),
                                label: Text(describe(action).$2),
                              )
                            : OutlinedButton.icon(
                                onPressed: () => onAction(action),
                                icon: Icon(describe(action).$1, size: 16),
                                label: Text(describe(action).$2),
                              ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// File and format details, docked beside the preview on wide screens or
/// in a bottom sheet.
class _DetailsPanel extends StatelessWidget {
  const _DetailsPanel({
    required this.file,
    required this.preview,
    required this.stat,
    this.shown,
    this.onClose,
    this.inSheet = false,
  });

  final File file;
  final DesignPreview? preview;
  final FileStat? stat;

  /// What the canvas shows when it isn't the embedded preview.
  final String? shown;
  final VoidCallback? onClose;

  /// Inside a bottom sheet, which scrolls and pads its content itself.
  final bool inSheet;

  @override
  Widget build(BuildContext context) {
    final preview = this.preview;
    final stat = this.stat;
    final entries = <String, String>{
      'Name': p.basename(file.path),
      if (stat != null && stat.type != FileSystemEntityType.directory)
        'Size': filesize(stat.size),
      if (stat != null)
        'Modified': DateFormat.yMMMd().add_jm().format(stat.modified),
      'Folder': file.parent.path,
      if (preview != null) ...preview.details,
      if (shown != null) 'Shown': shown!,
      if (preview?.note != null) 'Note': preview!.note!,
    };
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PanelHeader(
          title: 'Details',
          subtitle: preview?.format,
          onClose: onClose,
          closeTooltip: 'Hide details',
        ),
        const SizedBox(height: 8),
        if (preview == null) const LinearProgressIndicator(),
        DetailList(entries: entries.entries),
      ],
    );
    if (inSheet) return content;
    // Full height: the split view's Row centres shorter children.
    return SizedBox(
      height: double.infinity,
      child: ColoredBox(
        color: context.colors.background,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            8,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          child: content,
        ),
      ),
    );
  }
}
