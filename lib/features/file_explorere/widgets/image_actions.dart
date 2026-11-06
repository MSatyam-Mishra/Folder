import 'dart:io';

import 'package:folders/core/services/background_tasks.dart';
import 'package:folders/core/services/image_convert/image_converter.dart';
import 'package:folders/core/services/image_convert/image_formats.dart';
import 'package:folders/core/services/video_downloader/desktop_tools.dart';
import 'package:folders/features/file_explorere/widgets/explorer_menu.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// The icon for [format] in menus.
IconData formatIcon(ImageFormat format) => switch (format) {
      ImageFormat.svg => LucideIcons.penTool,
      ImageFormat.ico => LucideIcons.appWindow,
      ImageFormat.gif => LucideIcons.film,
      _ => LucideIcons.fileImage,
    };

/// A "Convert to" choice in a menu.
class ConvertImages {
  const ConvertImages(this.format);
  final ImageFormat format;
}

/// The "Resize…" choice in a menu.
class ResizeImages {
  const ResizeImages();
}

/// Converting and resizing pictures from the file browser's menus. The work
/// runs in the background (see [ImageConverter]).
abstract final class ImageActions {
  /// The pictures among [entities].
  static List<String> imagesIn(Iterable<FileSystemEntity> entities) => [
        for (final e in entities)
          if (e is File && isConvertibleImage(e.path)) e.path,
      ];

  /// "Convert to ▸" (every format but the pictures' own) and "Resize…".
  static Future<List<PopupMenuEntry<Object>>> menuEntries(BuildContext context, List<String> images) async {
    final targets = ImageFormat.targetsFor(images);
    final support = await ImageConverter.menuSupport(targets);
    if (!context.mounted) return const [];
    return [
      ExplorerMenu.submenu<Object>(
        context,
        label: 'Convert to',
        icon: LucideIcons.fileImage,
        items: [
          for (final f in targets)
            ExplorerMenu.item<Object>(
              context,
              value: ConvertImages(f),
              label: f.label,
              icon: formatIcon(f),
              enabled: support[f]!.usable,
              shortcut: switch (support[f]!.kind) {
                SupportKind.needsFfmpeg => 'needs FFmpeg',
                SupportKind.unavailable => 'not here',
                SupportKind.ready => null,
              },
            ),
        ],
      ),
      ExplorerMenu.item<Object>(context, value: const ResizeImages(), label: 'Resize…', icon: LucideIcons.scaling),
    ];
  }

  /// Runs a menu choice; false when [action] isn't one of these.
  static Future<bool> handle(BuildContext context, Object action, List<String> images) async {
    switch (action) {
      case ConvertImages(:final format):
        await convert(context, images, format);
        return true;
      case ResizeImages():
        await resize(context, images);
        return true;
    }
    return false;
  }

  /// Phones: the formats in a sheet, then the conversion.
  static Future<void> chooseFormat(BuildContext context, List<String> images) async {
    final targets = ImageFormat.targetsFor(images);
    final support = await ImageConverter.menuSupport(targets);
    if (!context.mounted) return;
    final format = await AppSheet.show<ImageFormat>(
      context,
      child: Builder(
        builder: (sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                images.length == 1 ? 'Convert ${p.basename(images.single)} to' : 'Convert ${images.length} images to',
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            for (final f in targets)
              ListTile(
                leading: Icon(formatIcon(f)),
                title: Text(f.label),
                subtitle: support[f]!.reason == null && support[f]!.kind != SupportKind.needsFfmpeg
                    ? null
                    : Text(support[f]!.reason ?? 'Downloads FFmpeg first'),
                enabled: support[f]!.usable,
                onTap: () => Navigator.pop(sheet, f),
              ),
          ],
        ),
      ),
    );
    if (format != null && context.mounted) await convert(context, images, format);
  }

  /// Starts converting [images] to [format], fetching FFmpeg first if it's
  /// needed (and agreed to).
  static Future<void> convert(BuildContext context, List<String> images, ImageFormat format) async {
    final support = await ImageConverter.support(format);
    if (!context.mounted) return;
    if (support.kind == SupportKind.unavailable) {
      _toast(context, support.reason ?? "${format.label} can't be written here.");
      return;
    }
    if (support.kind == SupportKind.needsFfmpeg) {
      if (!await _askForFfmpeg(context, format) || !context.mounted) return;
      final ok = await _installFfmpeg();
      if (!ok || !context.mounted) return;
    }
    ImageConverter.start(images, to: format);
    _toast(context, images.length == 1 ? 'Converting in the background' : 'Converting ${images.length} images in the background');
  }

  static Future<bool> _askForFfmpeg(BuildContext context, ImageFormat format) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Download FFmpeg for ${format.label}?'),
        content: Text(
          'Folders makes ${format.label} pictures with FFmpeg, which the video '
          'downloader uses too. It\'s about ${filesize(DesktopTools.ffmpegDownloadBytes, 0)} '
          'to download (${filesize(DesktopTools.ffmpegDiskBytes, 0)} installed), once. '
          'The download is checked before it\'s used.',
        ),
        actions: [
          OutlinedButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Download')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Downloads FFmpeg as a background task; true when it's there.
  static Future<bool> _installFfmpeg() async {
    final task = BackgroundTasks.instance.start('Downloading FFmpeg', message: 'Starting…', onCancel: () {});
    try {
      final tools = await ImageConverter.desktopTools();
      await tools.installFfmpeg(
        onProgress: (received, total) => task.update(
          progress: total == null || total == 0 ? null : received / total,
          message: total == null ? filesize(received, 1) : '${filesize(received, 1)} of ${filesize(total, 1)}',
        ),
        isCancelled: () => task.cancelRequested,
      );
      BackgroundTasks.instance.finish(task, message: 'FFmpeg is ready');
      return true;
    } catch (e) {
      if (task.cancelRequested) {
        BackgroundTasks.instance.cancelled(task);
      } else {
        BackgroundTasks.instance.fail(task, "Couldn't download FFmpeg: $e");
      }
      return false;
    }
  }

  /// Asks for the new size and starts resizing.
  static Future<void> resize(BuildContext context, List<String> images) async {
    final choice = await showDialog<(ResizeSpec, bool)>(
      context: context,
      builder: (_) => ResizeDialog(images: images),
    );
    if (choice == null || !context.mounted) return;
    ImageConverter.start(images, resize: choice.$1, replace: choice.$2);
    _toast(context, images.length == 1 ? 'Resizing in the background' : 'Resizing ${images.length} images in the background');
  }

  static void _toast(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
}

/// The new size for one or more pictures: pixels or percent, with the
/// aspect ratio locked by default. Pops `(ResizeSpec, replaceOriginals)`.
class ResizeDialog extends StatefulWidget {
  const ResizeDialog({super.key, required this.images});

  final List<String> images;

  @override
  State<ResizeDialog> createState() => _ResizeDialogState();
}

class _ResizeDialogState extends State<ResizeDialog> {
  final _width = TextEditingController();
  final _height = TextEditingController();
  bool _percent = false;
  bool _locked = true;
  bool _replace = false;

  /// The picture's size (one picture only), to keep the other side in step.
  (int, int)? _size;

  bool get _single => widget.images.length == 1;

  @override
  void initState() {
    super.initState();
    if (_single) _readSize();
  }

  Future<void> _readSize() async {
    try {
      final file = File(widget.images.single);
      final bytes = await file.openRead(0, 1 << 20).fold<List<int>>([], (a, b) => a..addAll(b));
      final decoder = img.findDecoderForNamedImage(file.path);
      final info = decoder?.startDecode(Uint8List.fromList(bytes));
      if (info != null && mounted) {
        setState(() {
          _size = (info.width, info.height);
          if (!_percent) {
            _width.text = '${info.width}';
            _height.text = '${info.height}';
          }
        });
      }
    } catch (_) {
      // Size unknown (HEIC…): both fields stay free.
    }
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  /// Keeps the other field in step while locked.
  void _changed(bool width) {
    if (!_locked) return;
    final value = double.tryParse((width ? _width : _height).text);
    final other = width ? _height : _width;
    if (_percent) {
      other.text = value == null ? '' : _format(value);
      return;
    }
    final size = _size;
    if (size == null) {
      // Several pictures: one side is enough.
      if (value != null) other.text = '';
      return;
    }
    if (value == null) return;
    other.text = width ? '${(value * size.$2 / size.$1).round()}' : '${(value * size.$1 / size.$2).round()}';
  }

  static String _format(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  void _setUnit(bool percent) {
    setState(() {
      _percent = percent;
      if (percent) {
        _width.text = '50';
        _height.text = '50';
      } else if (_size != null) {
        _width.text = '${_size!.$1}';
        _height.text = '${_size!.$2}';
      } else {
        _width.clear();
        _height.clear();
      }
    });
  }

  ResizeSpec? get _spec {
    final w = double.tryParse(_width.text), h = double.tryParse(_height.text);
    bool ok(double? v) => v != null && v > 0 && v <= (_percent ? 1000 : 30000);
    if (_percent) {
      if (!ok(w) || (!_locked && !ok(h))) return null;
      return ResizeSpec.percent(width: w!, height: _locked ? null : h, keepAspect: _locked);
    }
    if (_locked) {
      // One side is enough; with both (one picture), the width leads.
      if (ok(w)) return ResizeSpec.pixels(width: w);
      if (ok(h)) return ResizeSpec.pixels(height: h);
      return null;
    }
    if (!ok(w) || !ok(h)) return null;
    return ResizeSpec.pixels(width: w, height: h, keepAspect: false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final spec = _spec;
    final unit = _percent ? '%' : 'px';
    Widget field(TextEditingController controller, String label, bool width) => Expanded(
          child: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
            decoration: InputDecoration(
              labelText: label,
              suffixText: unit,
              hintText: _locked && !_single && !_percent ? 'auto' : null,
            ),
            onChanged: (_) => setState(() => _changed(width)),
          ),
        );
    return AlertDialog(
      title: Text(_single ? 'Resize ${p.basename(widget.images.single)}' : 'Resize ${widget.images.length} images'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Pixels')),
                ButtonSegment(value: true, label: Text('Percent')),
              ],
              selected: {_percent},
              onSelectionChanged: (s) => _setUnit(s.first),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                field(_width, 'Width', true),
                IconButton(
                  tooltip: _locked ? 'Aspect ratio locked' : 'Aspect ratio unlocked',
                  isSelected: _locked,
                  icon: Icon(_locked ? LucideIcons.link : LucideIcons.unlink, size: 18),
                  onPressed: () => setState(() => _locked = !_locked),
                ),
                field(_height, 'Height', false),
              ],
            ),
            if (_size != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Now ${_size!.$1} × ${_size!.$2} px', style: text.bodySmall),
              ),
            if (!_single && _locked && !_percent)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Give the width or the height; each picture keeps its proportions.',
                    style: text.bodySmall),
              ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _replace,
              onChanged: (v) => setState(() => _replace = v),
              title: const Text('Replace the originals'),
              subtitle: Text(_replace
                  ? 'The pictures are overwritten.'
                  : 'Saved as copies, like "photo (1280×720).jpg".'),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: spec == null ? null : () => Navigator.pop(context, (spec, _replace)),
          child: const Text('Resize'),
        ),
      ],
    );
  }
}
