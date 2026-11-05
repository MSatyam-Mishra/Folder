import 'dart:io' as io;
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/features/viewer_vector/widgets/vector_canvas.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:rive/rive.dart';

class RiveViewerScreen extends StatefulWidget {
  final io.File riveFile;

  const RiveViewerScreen({super.key, required this.riveFile});

  @override
  State<RiveViewerScreen> createState() => _RiveViewerScreenState();
}

class _RiveViewerScreenState extends State<RiveViewerScreen> {
  late PageController _pageController;
  List<io.File> _files = [];
  int _index = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSiblingFiles();
  }

  Future<void> _loadSiblingFiles() async {
    try {
      final parentDir = widget.riveFile.parent;
      final entities = parentDir.listSync();
      final files = entities
          .whereType<io.File>()
          .where((f) => f.path.toLowerCase().endsWith('.riv'))
          .toList();

      // Sort to ensure consistent order
      files.sort((a, b) => a.path.compareTo(b.path));

      final initialIndex = files.indexWhere(
        (f) => f.path == widget.riveFile.path,
      );
      final safeIndex = initialIndex != -1 ? initialIndex : 0;

      setState(() {
        _files = files.isEmpty ? [widget.riveFile] : files;
        _index = safeIndex;
        _isLoading = false;
        _pageController = PageController(initialPage: safeIndex);
      });
    } catch (e) {
      debugPrint('Error loading sibling files: $e');
      setState(() {
        _files = [widget.riveFile]; // Fallback
        _isLoading = false;
        _pageController = PageController();
      });
    }
  }

  @override
  void dispose() {
    if (!_isLoading) _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _isLoading ? widget.riveFile : _files[_index];
    return ExplorerScaffold(
      title: p.basename(current.path),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_files.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: CountPill('${_index + 1} / ${_files.length}'),
            ),
          const CanvasBackgroundButton(),
          const SizedBox(width: 4),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: DockedGlossyTopBar.contentTopInset(context),
        ),
        child: _isLoading
            ? const ViewerLoading()
            : PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.horizontal,
                itemCount: _files.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, index) {
                  return RivePlayerPage(file: _files[index]);
                },
              ),
      ),
    );
  }
}

class RivePlayerPage extends StatefulWidget {
  final io.File file;

  const RivePlayerPage({super.key, required this.file});

  @override
  State<RivePlayerPage> createState() => _RivePlayerPageState();
}

class _RivePlayerPageState extends State<RivePlayerPage> {
  RiveWidgetController? _controller;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRiveFile();
  }

  Future<void> _loadRiveFile() async {
    try {
      final bytes = await widget.file.readAsBytes();
      // Decode the Rive file from bytes using the 0.14.x Factory
      final file = await File.decode(bytes, riveFactory: Factory.rive);
      if (file == null) {
        throw Exception('Failed to decode Rive file');
      }

      _controller = RiveWidgetController(file);

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading Rive file: $e');
      if (mounted) {
        setState(() {
          _error = '$e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (_isLoading) {
      content = const ViewerLoading();
    } else if (_error != null) {
      content = ViewerMessage(
        icon: LucideIcons.fileX2,
        title: "Couldn't play this animation",
        message: "It isn't a valid Rive file, or it needs a newer player.",
        details: _error,
      );
    } else if (_controller == null) {
      content = const ViewerMessage(
        icon: LucideIcons.fileX2,
        title: "Couldn't play this animation",
        message: 'Unable to initialize the Rive player.',
      );
    } else {
      content = Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        child: RiveWidget(controller: _controller!, fit: Fit.contain),
      );
    }
    return ValueListenableBuilder<CanvasBackground>(
      valueListenable: canvasBackground,
      builder: (context, background, _) =>
          VectorCanvas(background: background, child: content),
    );
  }
}
