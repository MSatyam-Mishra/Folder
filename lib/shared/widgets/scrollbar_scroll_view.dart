import 'package:flutter/material.dart';

/// A [CustomScrollView] with a scrollbar whose thumb can be dragged. The
/// scrollbar needs the view's controller for that: without it, on
/// computers, only the wheel and the touchpad scrolled.
class ScrollbarScrollView extends StatefulWidget {
  const ScrollbarScrollView({
    super.key,
    required this.slivers,
    this.storageKey,
    this.physics,
  });

  final List<Widget> slivers;

  /// Remembers the scroll position under this key (see [PageStorageKey]).
  final String? storageKey;
  final ScrollPhysics? physics;

  @override
  State<ScrollbarScrollView> createState() => _ScrollbarScrollViewState();
}

class _ScrollbarScrollViewState extends State<ScrollbarScrollView> {
  var _controller = ScrollController();

  @override
  void didUpdateWidget(ScrollbarScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Another folder: a new view, with a controller of its own (the old
    // view holds on to its controller until the frame ends).
    if (oldWidget.storageKey != widget.storageKey) {
      final old = _controller;
      _controller = ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.storageKey;
    return Scrollbar(
      controller: _controller,
      child: CustomScrollView(
        key: key == null ? null : PageStorageKey<String>(key),
        controller: _controller,
        // This scrollbar only: the one computers add by default would sit
        // on top of it.
        scrollBehavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        physics: widget.physics,
        slivers: widget.slivers,
      ),
    );
  }
}
