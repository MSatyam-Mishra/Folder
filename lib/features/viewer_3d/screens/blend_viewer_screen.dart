import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:folders/core/formats/blend/blend_to_gltf.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/features/viewer_3d/screens/three_d_viewer_screen.dart';
import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Opens a Blender .blend file: its meshes are converted to glTF (cached)
/// and shown in the 3D viewer. Files without meshes show their saved
/// preview image instead.
class BlendViewerScreen extends StatefulWidget {
  const BlendViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<BlendViewerScreen> createState() => _BlendViewerScreenState();
}

/// What the converter found, small enough to send between isolates.
typedef _Summary = ({
  String? glbPath,
  String version,
  int meshes,
  int others,
  bool truncated,
  Uint8List? thumbnailPng,
  String? error,
});

class _BlendViewerScreenState extends State<BlendViewerScreen> {
  _Summary? _summary;

  String get _name => p.basename(widget.file.path);

  @override
  void initState() {
    super.initState();
    _convert();
  }

  Future<void> _convert() async {
    final file = widget.file;
    _Summary summary;
    try {
      final stat = await file.stat();
      final cacheDir = Directory(
        p.join((await getTemporaryDirectory()).path, 'blend_previews'),
      );
      final key = _hash(
        '${file.absolute.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
      );
      final cached = File(p.join(cacheDir.path, '$key.glb'));
      if (await cached.exists()) {
        summary = (
          glbPath: cached.path,
          version: '',
          meshes: 1,
          others: 0,
          truncated: false,
          thumbnailPng: null,
          error: null,
        );
      } else {
        summary = await _convertInBackground(file.path, cached.path);
        _trimCache(cacheDir);
      }
    } catch (e, st) {
      debugPrint('BlendViewerScreen: $e\n$st');
      summary = (
        glbPath: null,
        version: '',
        meshes: 0,
        others: 0,
        truncated: false,
        thumbnailPng: null,
        error: 'something went wrong while reading it.',
      );
    }
    if (!mounted) return;
    setState(() => _summary = summary);
    if (summary.truncated) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'This scene is very large: showing ${summary.meshes} of its '
            'meshes.',
          ),
        ),
      );
    }
  }

  /// Static, so the isolate's closure captures only the two paths.
  static Future<_Summary> _convertInBackground(String source, String target) =>
      Isolate.run(() => _convertInIsolate(source, target));

  static Future<_Summary> _convertInIsolate(
    String source,
    String target,
  ) async {
    final BlendExport result;
    try {
      result = BlendToGltf.convert(await File(source).readAsBytes());
    } on FormatException catch (e) {
      return (
        glbPath: null,
        version: '',
        meshes: 0,
        others: 0,
        truncated: false,
        thumbnailPng: null,
        error: e.message,
      );
    }
    final glb = result.glb;
    if (glb != null) {
      final out = File(target);
      await out.parent.create(recursive: true);
      // Written whole then renamed, so a half-written file is never used.
      final temp = File('$target.part');
      await temp.writeAsBytes(glb, flush: true);
      await temp.rename(out.path);
    }
    final thumb = result.thumbnail;
    return (
      glbPath: glb == null ? null : target,
      version: result.version,
      meshes: result.meshes.length,
      others: result.otherObjects,
      truncated: result.truncated,
      thumbnailPng: thumb == null
          ? null
          : img.encodePng(
              img.Image.fromBytes(
                width: thumb.width,
                height: thumb.height,
                bytes: thumb.rgba.buffer,
                numChannels: 4,
              ),
            ),
      error: null,
    );
  }

  /// Keeps the most recent few conversions.
  static Future<void> _trimCache(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.glb'))
          .cast<File>()
          .toList();
      if (files.length <= 8) return;
      final dated = [for (final f in files) (f, (await f.stat()).modified)]
        ..sort((a, b) => b.$2.compareTo(a.$2));
      for (final (file, _) in dated.skip(8)) {
        await file.delete();
      }
    } catch (_) {}
  }

  static String _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
    }
    return h.toRadixString(36);
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final glb = summary?.glbPath;
    if (glb != null) {
      return ThreeDViewerScreen(file: File(glb), originalFile: widget.file);
    }
    final top = AppTopBarScaffold.contentTopInset(context);
    return ExplorerScaffold(
      title: _name,
      body: Padding(
        padding: EdgeInsets.only(top: top),
        child: summary == null
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(height: 12),
                    Text('Reading Blender file…'),
                  ],
                ),
              )
            : _Unavailable(file: widget.file, summary: summary),
      ),
    );
  }
}

/// No meshes, or a file that couldn't be read: the saved preview (if any),
/// what the file holds and a way to open it elsewhere.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.file, required this.summary});

  final File file;
  final _Summary summary;

  @override
  Widget build(BuildContext context) {
    final error = summary.error;
    final thumb = summary.thumbnailPng;
    final details = error != null
        ? "Folders couldn't read this file: $error"
        : [
            if (summary.version.isNotEmpty)
              'Saved with Blender ${summary.version}.',
            summary.others > 0
                ? 'It has ${summary.others} object${summary.others == 1 ? '' : 's'} '
                      'without a mesh (cameras, lights, curves…), which the 3D '
                      'viewer can\'t show.'
                : 'It has no objects to show.',
          ].join(' ');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (thumb != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    thumb,
                    width: 256,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                const SizedBox(height: 20),
              ],
              ViewerMessage(
                icon: error != null ? LucideIcons.fileX : LucideIcons.box,
                destructive: error != null,
                title: error != null
                    ? "Couldn't open this Blender file"
                    : 'Nothing to show in 3D',
                message: details,
                actions: [
                  OutlinedButton.icon(
                    onPressed: () => FileOpener.showOpenWith(context, file),
                    icon: const Icon(
                      LucideIcons.squareArrowOutUpRight,
                      size: 16,
                    ),
                    label: const Text('Open with…'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
