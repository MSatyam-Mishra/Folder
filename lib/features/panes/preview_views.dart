import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/services/thumbnails/thumbnails.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/panes/audio_cover.dart';
import 'package:folders/features/viewer_office/document/doc_model.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart' show CodeFont;
import 'package:folders/features/viewer_office/document/document_loader.dart';
import 'package:folders/shared/file_icons/file_thumbnail.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:just_audio/just_audio.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// How the preview pane shows a file.
enum PreviewLook { image, picture, svg, video, audio, pdf, text, document, other }

PreviewLook previewLookOf(String path) => switch (FileTypes.kindOf(path)) {
      FileKind.image => Thumbnails.decodesDirectly(path) ? PreviewLook.image : PreviewLook.picture,
      FileKind.rasterImage || FileKind.cameraRaw => PreviewLook.picture,
      FileKind.svg => FileTypes.extensionOf(path) == 'svg' ? PreviewLook.svg : PreviewLook.other,
      FileKind.video => PreviewLook.video,
      FileKind.audio => PreviewLook.audio,
      FileKind.pdf => PreviewLook.pdf,
      FileKind.text ||
      FileKind.code ||
      FileKind.json ||
      FileKind.markdown ||
      FileKind.html ||
      FileKind.delimited =>
        PreviewLook.text,
      FileKind.word || FileKind.legacyWord || FileKind.richText || FileKind.openDocumentText => PreviewLook.document,
      _ => PreviewLook.other,
    };

/// Whether [look] fills a tall box (pages, text) rather than a square.
bool previewIsTall(PreviewLook look) =>
    look == PreviewLook.pdf || look == PreviewLook.text || look == PreviewLook.document;

/// Things the views find out about a file for the details ("Dimensions",
/// "Pages", "Duration").
typedef PreviewFacts = ValueNotifier<Map<String, String>>;

void _addFact(PreviewFacts facts, String label, String value) =>
    facts.value = {...facts.value, label: value};

/// The file's big icon, where there's nothing to show of it.
class PreviewIcon extends StatelessWidget {
  const PreviewIcon({super.key, required this.entity, this.size = 96});

  final FileSystemEntity entity;
  final double size;

  @override
  Widget build(BuildContext context) => Center(child: EntityIcon(entity: entity, size: size));
}

/// A picture Flutter decodes itself, with its size in pixels.
class ImagePreview extends StatefulWidget {
  const ImagePreview({super.key, required this.file, required this.facts});

  final File file;
  final PreviewFacts facts;

  @override
  State<ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<ImagePreview> {
  @override
  void initState() {
    super.initState();
    _measure();
  }

  /// Reads the size from the file's header, without decoding it.
  Future<void> _measure() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(widget.file.path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (mounted) _addFact(widget.facts, 'Dimensions', '${descriptor.width} × ${descriptor.height} pixels');
      descriptor.dispose();
      buffer.dispose();
    } catch (_) {
      // Not readable as a picture: no dimensions.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Its own size at most (small pictures aren't blown up), with rounded
    // corners on the picture itself.
    return LayoutBuilder(
      builder: (context, box) => Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            widget.file,
            fit: BoxFit.contain,
            cacheWidth: (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).round().clamp(64, 2048),
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => PreviewIcon(entity: widget.file),
          ),
        ),
      ),
    );
  }
}

/// What [Thumbnails] makes of a file (a video frame, a camera raw's preview,
/// an Office document's picture...), else its icon.
class ThumbnailPreview extends StatelessWidget {
  const ThumbnailPreview({super.key, required this.file, this.overlay});

  final File file;
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final side = math.min(box.maxWidth, box.maxHeight);
      final picture = Center(
        child: FileThumbnail(
          path: file.path,
          size: side,
          radius: 8,
          fallback: PreviewIcon(entity: file, size: math.min(96, side * 0.6)),
        ),
      );
      final top = overlay;
      if (top == null) return picture;
      return Stack(alignment: Alignment.center, children: [Positioned.fill(child: picture), top]);
    });
  }
}

/// A round play button over a video's frame.
class PlayBadge extends StatelessWidget {
  const PlayBadge({super.key, required this.onPressed, this.tooltip = 'Play'});

  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Icon(LucideIcons.play, color: Colors.white, size: 26),
          ),
        ),
      ),
    );
  }
}

/// An SVG drawing.
class SvgPreview extends StatelessWidget {
  const SvgPreview({super.key, required this.file});

  final File file;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(12),
        child: SvgPicture.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => PreviewIcon(entity: file),
        ),
      );
}

/// The start of a text file, in a monospace font.
class TextPreview extends StatefulWidget {
  const TextPreview({super.key, required this.file, required this.facts});

  final File file;
  final PreviewFacts facts;

  static const bytes = 16 * 1024;

  @override
  State<TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<TextPreview> {
  String? _text;
  bool _more = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var text = '';
    var more = false;
    try {
      final file = await widget.file.open();
      try {
        final bytes = await file.read(TextPreview.bytes + 1);
        more = bytes.length > TextPreview.bytes;
        text = utf8.decode(more ? bytes.sublist(0, TextPreview.bytes) : bytes, allowMalformed: true);
      } finally {
        await file.close();
      }
    } on FileSystemException {
      // Nothing to show of it.
    }
    if (!mounted) return;
    if (!more) {
      final lines = '\n'.allMatches(text).length + (text.isEmpty || text.endsWith('\n') ? 0 : 1);
      _addFact(widget.facts, 'Lines', '$lines');
    }
    setState(() {
      _text = text;
      _more = more;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context).textTheme;
    if (text.trim().isEmpty) {
      return Center(child: Text('This file is empty', style: theme.bodySmall));
    }
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: CodeFont.style(fontSize: 11.5, height: 1.4, color: context.colors.foreground),
            ),
            if (_more) ...[
              const SizedBox(height: 8),
              Text('Open the file to see the rest.', style: theme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// The start of a word-processing document (Word, OpenDocument, RTF): its
/// text, on a page.
class DocumentPreview extends StatefulWidget {
  const DocumentPreview({super.key, required this.file});

  final File file;

  /// Bigger documents aren't read for a preview.
  static const maxBytes = 40 << 20;

  @override
  State<DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<DocumentPreview> {
  List<DocParagraph>? _paragraphs;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (await widget.file.length() > DocumentPreview.maxBytes) throw const FileSystemException('too big');
      final bytes = await widget.file.readAsBytes();
      final model = await parseDocumentInBackground(
        bytes,
        FileTypes.extensionOf(widget.file.path),
        // The first pages come before the rest: that's all this needs.
        onPreview: (preview) => _show(preview),
      );
      _show(model);
    } catch (_) {
      if (mounted && _paragraphs == null) setState(() => _failed = true);
    }
  }

  void _show(DocModel model) {
    if (!mounted || (_paragraphs?.length ?? 0) >= 40) return;
    final paragraphs = <DocParagraph>[];
    void collect(List<DocBlock> blocks) {
      for (final block in blocks) {
        if (paragraphs.length >= 40) return;
        if (block is DocParagraph) {
          paragraphs.add(block);
        } else if (block is DocTable) {
          for (final row in block.rows) {
            for (final cell in row.cells) {
              collect(cell.blocks);
            }
          }
        }
      }
    }

    collect(model.blocks);
    setState(() => _paragraphs = paragraphs);
  }

  @override
  Widget build(BuildContext context) {
    final paragraphs = _paragraphs;
    if (_failed) return ThumbnailPreview(file: widget.file);
    if (paragraphs == null) return const Center(child: _Spinner());
    final shown = [for (final p in paragraphs) if (!p.isEmpty) p];
    // A page: dark text on white, as the document prints.
    return Container(
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: shown.isEmpty
            ? const Center(child: Text('No text', style: TextStyle(color: Colors.black54, fontSize: 12)))
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final p in shown)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          p.plainText.replaceAll('￼', ''),
                          style: TextStyle(
                            color: const Color(0xFF1F2328),
                            fontSize: p.headingLevel == null ? 10.5 : 13.5 - p.headingLevel!.clamp(1, 4) * 0.5,
                            fontWeight: p.headingLevel == null ? FontWeight.w400 : FontWeight.w600,
                            height: 1.35,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// A PDF's first pages, and how many it has.
class PdfPreview extends StatefulWidget {
  const PdfPreview({super.key, required this.file, required this.facts});

  final File file;
  final PreviewFacts facts;

  static const pages = 3;

  @override
  State<PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<PdfPreview> {
  final _images = <ui.Image>[];
  int _count = 0;
  bool _failed = false;
  double? _width;

  @override
  void dispose() {
    for (final image in _images) {
      image.dispose();
    }
    super.dispose();
  }

  Future<void> _load(double width) async {
    // Widget tests have no PDF engine.
    if (!Thumbnails.enabled) {
      setState(() => _failed = true);
      return;
    }
    PdfDocument? document;
    try {
      await pdfrxFlutterInitialize();
      document = await PdfDocument.openFile(widget.file.path);
      if (!mounted) return;
      _count = document.pages.length;
      _addFact(widget.facts, 'Pages', '$_count');
      final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round().clamp(200, 1600);
      for (final page in document.pages.take(PdfPreview.pages)) {
        if (page.width <= 0 || page.height <= 0) continue;
        final height = (pixels * page.height / page.width).round();
        final rendered = await page.render(
          width: pixels,
          height: height,
          fullWidth: pixels.toDouble(),
          fullHeight: height.toDouble(),
          backgroundColor: 0xFFFFFFFF,
        );
        if (rendered == null) continue;
        try {
          final image = await rendered.createImage();
          if (!mounted) {
            image.dispose();
            return;
          }
          setState(() => _images.add(image));
        } finally {
          rendered.dispose();
        }
      }
      if (_images.isEmpty && mounted) setState(() => _failed = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      await document?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return ThumbnailPreview(file: widget.file);
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth - 20;
      if (_width == null) {
        _width = width;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _load(width);
        });
      }
      if (_images.isEmpty) return const Center(child: _Spinner());
      final text = Theme.of(context).textTheme;
      return Scrollbar(
        child: ListView(
          padding: const EdgeInsets.all(10),
          children: [
            for (final (i, image) in _images.indexed) ...[
              DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: RawImage(image: image, fit: BoxFit.fitWidth, width: width),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 10),
                child: Text('Page ${i + 1} of $_count', textAlign: TextAlign.center, style: text.bodySmall),
              ),
            ],
          ],
        ),
      );
    });
  }
}

/// A song's cover and a play button: it plays right here.
class AudioPreview extends StatefulWidget {
  const AudioPreview({super.key, required this.file, required this.facts});

  final File file;
  final PreviewFacts facts;

  @override
  State<AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<AudioPreview> {
  Uint8List? _cover;
  AudioPlayer? _player;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _playing = false;
  bool _loading = false;
  String? _error;
  Duration _position = Duration.zero;
  Duration? _duration;

  @override
  void initState() {
    super.initState();
    AudioCover.find(widget.file.path).then((cover) {
      if (mounted && cover != null) setState(() => _cover = cover);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final current = _player;
    if (current != null) {
      current.playing ? await current.pause() : await current.play();
      return;
    }
    final player = _player = AudioPlayer();
    setState(() => _loading = true);
    try {
      final duration = await player.setFilePath(widget.file.path);
      if (!mounted) return;
      _subscriptions
        ..add(player.playerStateStream.listen((state) {
          if (!mounted) return;
          if (state.processingState == ProcessingState.completed) {
            player.pause();
            player.seek(Duration.zero);
          }
          setState(() => _playing = state.playing && state.processingState != ProcessingState.completed);
        }))
        ..add(player.positionStream.listen((position) {
          if (mounted) setState(() => _position = position);
        }));
      setState(() {
        _loading = false;
        _duration = duration;
      });
      if (duration != null) _addFact(widget.facts, 'Duration', formatDuration(duration));
      await player.play();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = "Can't play this file here";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final cover = _cover;
    final duration = _duration;
    return LayoutBuilder(builder: (context, box) {
      final side = math.max(0.0, math.min(box.maxWidth, box.maxHeight - 64));
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.square(
            dimension: side,
            child: cover != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      cover,
                      fit: BoxFit.cover,
                      cacheWidth: (side * MediaQuery.devicePixelRatioOf(context)).round().clamp(64, 1024),
                      errorBuilder: (_, _, _) => PreviewIcon(entity: widget.file),
                    ),
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.muted,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(LucideIcons.music, size: side * 0.35, color: colors.mutedForeground),
                  ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: _playing ? 'Pause' : 'Play',
                onPressed: _loading || _error != null ? null : _toggle,
                icon: _loading
                    ? const _Spinner()
                    : Icon(_playing ? LucideIcons.pause : LucideIcons.play, size: 18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _error != null
                    ? Text(_error!, style: text.bodySmall?.copyWith(color: colors.destructive))
                    : duration == null
                        ? Text('Play it here', style: text.bodySmall)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              LinearProgressIndicator(
                                value: duration.inMilliseconds == 0
                                    ? 0
                                    : (_position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0),
                                minHeight: 3,
                                borderRadius: BorderRadius.circular(2),
                              ),
                              const SizedBox(height: 4),
                              Text('${formatDuration(_position)} / ${formatDuration(duration)}', style: text.bodySmall),
                            ],
                          ),
              ),
            ],
          ),
        ],
      );
    });
  }
}

/// "3:07", or "1:02:03".
String formatDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(d.inHours > 0 ? 2 : 1, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2));
}
