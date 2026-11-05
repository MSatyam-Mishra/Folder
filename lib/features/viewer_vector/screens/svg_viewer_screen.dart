import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/features/viewer_vector/svg_path_loader.dart';
import 'package:folder/features/viewer_vector/widgets/vector_canvas.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

class SvgViewerScreen extends StatefulWidget {
  const SvgViewerScreen({super.key, required this.filePath});

  final String filePath;

  @override
  State<SvgViewerScreen> createState() => _SvgViewerScreenState();
}

class _SvgViewerScreenState extends State<SvgViewerScreen> {
  String? _svg;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final markup = await loadSvgFromPath(widget.filePath);
      if (!mounted) return;
      setState(() => _svg = markup);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ExplorerScaffold(
      title: p.basename(widget.filePath),
      trailing: const Padding(
        padding: EdgeInsets.only(right: 4),
        child: CanvasBackgroundButton(),
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: DockedGlossyTopBar.contentTopInset(context),
        ),
        child: ValueListenableBuilder<CanvasBackground>(
          valueListenable: canvasBackground,
          builder: (context, background, _) => VectorCanvas(
            background: background,
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return ViewerMessage(
        icon: LucideIcons.imageOff,
        title: "Couldn't load this SVG",
        details: '$_error',
      );
    }
    if (_svg == null) return const ViewerLoading();
    return InteractiveViewer(
      maxScale: 12,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        // Fit to the window (up to a comfortable size): icons are often
        // drawn on tiny canvases.
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: SizedBox(
                width: constraints.maxWidth.clamp(0.0, 720.0),
                height: constraints.maxHeight.clamp(0.0, 560.0),
                child: SvgPicture.string(
                  _svg!,
                  fit: BoxFit.contain,
                  placeholderBuilder: (context) => const ViewerLoading(),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
