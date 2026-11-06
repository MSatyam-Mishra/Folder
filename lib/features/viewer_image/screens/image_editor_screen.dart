import 'dart:io';
import 'dart:math' as math;

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/files/safe_write.dart';
import 'package:folders/features/viewer_image/image_codec.dart';
import 'package:folders/features/viewer_image/raw_image.dart';
import 'package:folders/features/viewer_image/widgets/crop_frame.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Crop, rotate, flip, adjust and filter an image. Pops with the saved file
/// path, or null when nothing was saved.
class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.file});

  final File file;

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

enum _Tool { crop, adjust, filters }

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  img.Image? _source;
  String? _error;
  bool _saving = false;
  final ImageEdits _edits = ImageEdits();
  _Tool _tool = _Tool.crop;
  double? _aspect; // width / height in pixels; null = free

  late final String _ext = FileTypes.extensionOf(widget.file.path);

  /// Only formats we can write byte-for-byte as their own format are saved
  /// in place; the rest are saved as a PNG copy with a .png name.
  bool get _canOverwrite => ImageCodec.canWrite(_ext);

  /// Camera raws are edited through their embedded preview and only ever
  /// saved as a JPEG or PNG copy; the raw file is never touched.
  late final bool _isRaw = RawImages.isRaw(widget.file.path);

  @override
  void initState() {
    super.initState();
    ImageCodec.decodeForEditing(widget.file).then((image) {
      if (mounted) setState(() => _source = image);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = "This image can't be edited: $e");
    });
  }

  Size get _orientedSize {
    final s = _source!;
    return _edits.quarterTurns.isOdd
        ? Size(s.height.toDouble(), s.width.toDouble())
        : Size(s.width.toDouble(), s.height.toDouble());
  }

  void _rotate(int delta) => setState(() {
        _edits.quarterTurns = (_edits.quarterTurns + delta) % 4;
        _edits.crop = null;
        _aspect = null;
      });

  void _setAspect(double? aspect) {
    setState(() {
      _aspect = aspect;
      if (aspect == null) return;
      final size = _orientedSize;
      // Largest centred rect with this pixel aspect ratio.
      var w = 1.0;
      var h = size.width / (size.height * aspect);
      if (h > 1) {
        w = 1 / h;
        h = 1;
      }
      _edits.crop = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    });
  }

  /// [format] forces the copy's format ('jpg' or 'png').
  Future<void> _save({required bool asCopy, String? format}) async {
    final source = _source;
    if (source == null) return;
    setState(() => _saving = true);
    try {
      final ext = format ?? (_canOverwrite ? _ext : 'png');
      final bytes = await ImageCodec.applyAndEncode(source, _edits, ext);
      final File target;
      if (asCopy || !_canOverwrite || format != null) {
        final dir = widget.file.parent.path;
        final base = p.basenameWithoutExtension(widget.file.path);
        var candidate = File(p.join(dir, '${base}_edited.$ext'));
        for (var i = 2; await candidate.exists(); i++) {
          candidate = File(p.join(dir, '${base}_edited_$i.$ext'));
        }
        target = candidate;
      } else {
        target = widget.file;
      }
      if (identical(target, widget.file) && !_isRaw) {
        // Overwrite via temp file + rename: a failed write can't truncate
        // the original photo.
        await writeFileAtomically(target, bytes);
      } else {
        await target.writeAsBytes(bytes, flush: true);
      }
      if (mounted) Navigator.pop(context, target.path);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    }
  }

  /// [themed] is a context inside the editor's (dark) theme.
  Future<bool> _confirmDiscard(BuildContext themed) async {
    if (_edits.isIdentity) return true;
    final discard = await showDialog<bool>(
      context: themed,
      builder: (context) => AlertDialog(
        title: const Text('Discard edits?'),
        content: const Text('Your changes to this image will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.destructive,
              foregroundColor: context.colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  void _reset() => setState(() {
        _edits
          ..quarterTurns = 0
          ..flipHorizontal = false
          ..flipVertical = false
          ..crop = null
          ..brightness = 0
          ..contrast = 0
          ..saturation = 0
          ..filter = ImageFilterPreset.none;
        _aspect = null;
      });

  @override
  Widget build(BuildContext context) {
    return ImmersiveTheme(child: Builder(builder: _build));
  }

  Widget _build(BuildContext context) {
    final ready = _source != null && !_saving;
    // A raw's preview is worth exporting even without edits.
    final canSave = ready && (_isRaw || !_edits.isIdentity);

    return PopScope(
      canPop: _edits.isIdentity,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard(context) && context.mounted) {
          Navigator.pop(context);
        }
      },
      child: ExplorerScaffold(
        title: 'Edit ${p.basename(widget.file.path)}',
        backgroundColor: Colors.black,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIconButton(
              icon: const Icon(LucideIcons.refreshCcw),
              tooltip: 'Reset',
              onPressed: ready && !_edits.isIdentity ? _reset : null,
            ),
            const SizedBox(width: 4),
            MenuIconButton<String>(
              tooltip: 'Save',
              enabled: canSave,
              onSelected: (choice) => switch (choice) {
                'save' => _save(asCopy: false),
                'jpg' => _save(asCopy: true, format: 'jpg'),
                'png' => _save(asCopy: true, format: 'png'),
                _ => _save(asCopy: true),
              },
              itemBuilder: (_) => [
                if (_isRaw) ...[
                  menuItem(
                    value: 'jpg',
                    icon: LucideIcons.fileImage,
                    label: 'Save as JPEG copy',
                  ),
                  menuItem(
                    value: 'png',
                    icon: LucideIcons.fileImage,
                    label: 'Save as PNG copy',
                  ),
                ] else ...[
                  if (_canOverwrite)
                    menuItem(
                      value: 'save',
                      icon: LucideIcons.save,
                      label: 'Save',
                    ),
                  menuItem(
                    value: 'copy',
                    icon: LucideIcons.copy,
                    label: _canOverwrite ? 'Save as copy' : 'Save as PNG copy',
                  ),
                ],
              ],
              child: _SaveTrigger(enabled: canSave),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: ViewerMessage(
          icon: LucideIcons.imageOff,
          title: "This image can't be edited",
          details: _error,
        ),
      );
    }
    if (_source == null || _saving) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: ViewerLoading(label: _saving ? 'Saving…' : null),
      );
    }
    final wide = WindowSize.of(context).isAtLeastMedium &&
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    final preview = Padding(
      padding: const EdgeInsets.all(16),
      child: _buildPreview(),
    );
    final colors = context.colors;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final tools = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: wide
            ? Border(left: BorderSide(color: colors.border))
            : Border(top: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: _buildTools(wide),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: wide
          ? Row(
              children: [
                Expanded(child: preview),
                SizedBox(width: 340, child: tools),
              ],
            )
          : Column(
              children: [
                Expanded(child: preview),
                tools,
              ],
            ),
    );
  }

  Widget _buildPreview() {
    final matrix = _edits.colorMatrix();
    final size = _orientedSize;
    // The preview only needs screen resolution; the edits are applied to the
    // full-size pixels in [_source].
    final previewSide = (MediaQuery.sizeOf(context).longestSide *
            MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(1024, 4096);
    Widget image = RotatedBox(
      quarterTurns: _edits.quarterTurns,
      child: Image(
        image: ImageCodec.displayProviderFor(widget.file, previewSide),
        fit: BoxFit.fill,
        gaplessPlayback: true,
      ),
    );
    image = Transform.flip(
      flipX: _edits.flipHorizontal,
      flipY: _edits.flipVertical,
      child: image,
    );
    if (matrix != null) {
      image = ColorFiltered(colorFilter: ColorFilter.matrix(matrix), child: image);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Room around the image to take hold of the frame's edges at its border.
        const margin = CropFrame.margin;
        final scale = math.min(
          (constraints.maxWidth - margin * 2) / size.width,
          (constraints.maxHeight - margin * 2) / size.height,
        );
        final display = Size(size.width * scale, size.height * scale);
        final imageRect = Rect.fromCenter(
          center: constraints.biggest.center(Offset.zero),
          width: display.width,
          height: display.height,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: SizedBox.fromSize(
                size: display,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // The frame repaints as it's dragged, and this shouldn't.
                    RepaintBoundary(child: image),
                    if (_tool != _Tool.crop && _edits.crop != null)
                      CustomPaint(painter: _DimPainter(_edits.crop!)),
                  ],
                ),
              ),
            ),
            if (_tool == _Tool.crop)
              Positioned.fill(
                child: CropFrame(
                  imageRect: imageRect,
                  rect: _edits.crop ?? const Rect.fromLTWH(0, 0, 1, 1),
                  pixelSize: size,
                  aspect: _aspect == null ? null : _aspect! * size.height / size.width,
                  onChanged: (r) => setState(() {
                    final full = r.left <= 0.001 && r.top <= 0.001 && r.right >= 0.999 && r.bottom >= 0.999;
                    _edits.crop = full ? null : r;
                  }),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTools(bool wide) {
    final content = switch (_tool) {
      _Tool.crop => _buildCropTools(),
      _Tool.adjust => _buildAdjustTools(),
      _Tool.filters => _buildFilterTools(),
    };
    return Column(
      mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isRaw)
          ViewerNotice(
            icon: LucideIcons.info,
            message: 'Editing the embedded preview '
                '(${_source!.width} × ${_source!.height}). '
                'The raw file is not changed; edits are saved as a copy.',
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: SegmentedButton<_Tool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _Tool.crop,
                icon: Icon(LucideIcons.crop, size: 16),
                label: Text('Crop'),
              ),
              ButtonSegment(
                value: _Tool.adjust,
                icon: Icon(LucideIcons.slidersHorizontal, size: 16),
                label: Text('Adjust'),
              ),
              ButtonSegment(
                value: _Tool.filters,
                icon: Icon(LucideIcons.wandSparkles, size: 16),
                label: Text('Filters'),
              ),
            ],
            selected: {_tool},
            onSelectionChanged: (s) => setState(() => _tool = s.first),
          ),
        ),
        if (wide) Expanded(child: SingleChildScrollView(child: content)) else content,
      ],
    );
  }

  Widget _buildCropTools() {
    final original = _source!.width / _source!.height;
    final oriented = _edits.quarterTurns.isOdd ? 1 / original : original;
    final ratios = <String, double?>{
      'Free': null,
      'Original': oriented,
      '1:1': 1,
      '4:3': 4 / 3,
      '3:4': 3 / 4,
      '16:9': 16 / 9,
      '9:16': 9 / 16,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ToolButton(
                icon: LucideIcons.rotateCcw,
                tooltip: 'Rotate left',
                size: 44,
                iconSize: 20,
                onPressed: () => _rotate(3),
              ),
              ToolButton(
                icon: LucideIcons.rotateCw,
                tooltip: 'Rotate right',
                size: 44,
                iconSize: 20,
                onPressed: () => _rotate(1),
              ),
              // Lucide names these by their axis line: flipVertical2 draws
              // a vertical line with arrows left and right.
              ToolButton(
                icon: LucideIcons.flipVertical2,
                tooltip: 'Flip horizontally',
                size: 44,
                iconSize: 20,
                selected: _edits.flipHorizontal,
                onPressed: () => setState(
                    () => _edits.flipHorizontal = !_edits.flipHorizontal),
              ),
              ToolButton(
                icon: LucideIcons.flipHorizontal2,
                tooltip: 'Flip vertically',
                size: 44,
                iconSize: 20,
                selected: _edits.flipVertical,
                onPressed: () =>
                    setState(() => _edits.flipVertical = !_edits.flipVertical),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ratios.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final e = ratios.entries.elementAt(i);
                return Center(
                  child: ChoiceChip(
                    label: Text(e.key),
                    selected: e.value == null
                        ? _aspect == null
                        : _aspect != null && (_aspect! - e.value!).abs() < 1e-6,
                    onSelected: (_) => _setAspect(e.value),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // The tool panels read the theme from a context inside [ImmersiveTheme],
  // not the State's own (light in light mode).
  Widget _buildAdjustTools() => Builder(builder: _adjustTools);

  Widget _adjustTools(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    Widget slider(
      IconData icon,
      String label,
      double value,
      ValueChanged<double> onChanged,
    ) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(icon, size: 16, color: colors.mutedForeground),
            const SizedBox(width: 8),
            SizedBox(width: 80, child: Text(label, style: text.bodyMedium)),
            Expanded(
              child: Slider(
                value: value,
                min: -100,
                max: 100,
                divisions: 200,
                label: value.round().toString(),
                onChanged: (v) => setState(() => onChanged(v)),
              ),
            ),
            SizedBox(
              width: 36,
              child: Text(
                value.round().toString(),
                textAlign: TextAlign.right,
                style: text.labelMedium?.copyWith(
                  color: value.round() == 0
                      ? colors.mutedForeground
                      : colors.foreground,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          slider(LucideIcons.sun, 'Brightness', _edits.brightness,
              (v) => _edits.brightness = v),
          slider(LucideIcons.contrast, 'Contrast', _edits.contrast,
              (v) => _edits.contrast = v),
          slider(LucideIcons.droplet, 'Saturation', _edits.saturation,
              (v) => _edits.saturation = v),
        ],
      ),
    );
  }

  Widget _buildFilterTools() => Builder(builder: _filterTools);

  Widget _filterTools(BuildContext context) {
    const names = {
      ImageFilterPreset.none: 'Original',
      ImageFilterPreset.vivid: 'Vivid',
      ImageFilterPreset.warm: 'Warm',
      ImageFilterPreset.cool: 'Cool',
      ImageFilterPreset.grayscale: 'Mono',
      ImageFilterPreset.sepia: 'Sepia',
      ImageFilterPreset.invert: 'Invert',
    };
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: 120,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        children: [
          for (final e in names.entries)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _edits.filter = e.key),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Column(
                    children: [
                      Container(
                        width: 68,
                        height: 68,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _edits.filter == e.key
                                ? colors.primary
                                : colors.border,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: ColorFiltered(
                            colorFilter: ColorFilter.matrix(
                              (ImageEdits()..filter = e.key).colorMatrix() ??
                                  const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
                            ),
                            child: Image(
                              image: ResizeImage(
                                ImageCodec.providerFor(widget.file),
                                width: 128,
                              ),
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        e.value,
                        style: text.labelMedium?.copyWith(
                          color: _edits.filter == e.key
                              ? colors.foreground
                              : colors.mutedForeground,
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

/// The header's Save button; opens the save menu.
class _SaveTrigger extends StatelessWidget {
  const _SaveTrigger({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 12, right: 8),
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Save',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: colors.primaryForeground,
                  ),
            ),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.chevronDown,
              size: 16,
              color: colors.primaryForeground,
            ),
          ],
        ),
      ),
    );
  }
}

// Darkens everything outside a normalised crop rect.
class _DimPainter extends CustomPainter {
  _DimPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      rect.left * size.width,
      rect.top * size.height,
      rect.right * size.width,
      rect.bottom * size.height,
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(r);
    canvas.drawPath(path, Paint()..color = Colors.black.withValues(alpha: 0.6));
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.rect != rect;
}
