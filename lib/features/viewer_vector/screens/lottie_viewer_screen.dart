import 'dart:io';

import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/features/viewer_vector/widgets/vector_canvas.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:path/path.dart' as p;

/// Plays a Lottie animation; swipe for the other .json animations in its
/// folder.
class LottieViewerScreen extends StatefulWidget {
  final File file;

  const LottieViewerScreen({super.key, required this.file});

  @override
  State<LottieViewerScreen> createState() => _LottieViewerScreenState();
}

class _LottieViewerScreenState extends State<LottieViewerScreen> {
  late PageController _pageController;
  List<File> _files = [];
  int _index = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSiblingFiles();
  }

  Future<void> _loadSiblingFiles() async {
    try {
      final parentDir = widget.file.parent;
      final entities = parentDir.listSync();
      final files = entities
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();

      // Sort to ensure consistent order
      files.sort((a, b) => a.path.compareTo(b.path));

      final initialIndex = files.indexWhere((f) => f.path == widget.file.path);
      final safeIndex = initialIndex != -1 ? initialIndex : 0;

      setState(() {
        _files = files.isEmpty ? [widget.file] : files;
        _index = safeIndex;
        _isLoading = false;
        _pageController = PageController(initialPage: safeIndex);
      });
    } catch (e) {
      debugPrint('Error loading sibling files: $e');
      setState(() {
        _files = [widget.file]; // Fallback to just opening the single file
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
    final current = _isLoading ? widget.file : _files[_index];
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
                  return LottiePlayerPage(file: _files[index]);
                },
              ),
      ),
    );
  }
}

class LottiePlayerPage extends StatefulWidget {
  final File file;

  const LottiePlayerPage({super.key, required this.file});

  @override
  State<LottiePlayerPage> createState() => _LottiePlayerPageState();
}

class _LottiePlayerPageState extends State<LottiePlayerPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isPlaying = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _togglePlay() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _controller.repeat();
      } else {
        _controller.stop();
      }
    });
  }

  static String _time(Duration d) {
    final s = d.inMilliseconds / 1000;
    return '${s.toStringAsFixed(1)} s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return ValueListenableBuilder<CanvasBackground>(
      valueListenable: canvasBackground,
      builder: (context, background, _) => VectorCanvas(
        background: background,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 24, 24, 104 + bottom),
                child: Center(
                  child: Lottie.file(
                    widget.file,
                    controller: _controller,
                    errorBuilder: (context, error, stack) => ViewerMessage(
                      icon: LucideIcons.fileX2,
                      title: "Couldn't play this animation",
                      message: "It isn't a valid Lottie file.",
                      details: '$error',
                    ),
                    onLoaded: (composition) {
                      setState(() {
                        _loaded = true;
                        _controller.duration = composition.duration;
                        if (_isPlaying) {
                          _controller.forward();
                          _controller.repeat();
                        }
                      });
                    },
                  ),
                ),
              ),
            ),
            if (_loaded)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16 + bottom,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: AppPanel(
                      padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                      child: Row(
                        children: [
                          ToolButton(
                            icon: _isPlaying
                                ? LucideIcons.pause
                                : LucideIcons.play,
                            tooltip: _isPlaying ? 'Pause' : 'Play',
                            size: 40,
                            onPressed: _togglePlay,
                          ),
                          Expanded(
                            child: AnimatedBuilder(
                              animation: _controller,
                              builder: (context, child) => ShadSliderTheme(
                                child: Slider(
                                  value: _controller.value,
                                  onChanged: (value) {
                                    if (_isPlaying) _togglePlay();
                                    _controller.value = value;
                                  },
                                ),
                              ),
                            ),
                          ),
                          AnimatedBuilder(
                            animation: _controller,
                            builder: (context, _) => Text(
                              _time((_controller.duration ?? Duration.zero) *
                                  _controller.value),
                              style: text.labelMedium?.copyWith(
                                color: colors.foreground,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
