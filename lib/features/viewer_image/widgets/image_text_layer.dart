import 'package:folders/core/services/image_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The text found in an image, laid over it and selectable: each line sits
/// on the words it was read from. Place it over the image drawn at
/// [ImageText.size]'s aspect ratio (it scales to the space it gets). While
/// not [active] it's invisible and lets gestures through to the image.
class ImageTextLayer extends StatefulWidget {
  const ImageTextLayer({super.key, required this.text, required this.active});

  final ImageText text;
  final bool active;

  @override
  State<ImageTextLayer> createState() => _ImageTextLayerState();
}

class _ImageTextLayerState extends State<ImageTextLayer> {
  final _lines = _LinesDelegate();

  @override
  void dispose() {
    _lines.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    return IgnorePointer(
      ignoring: !widget.active,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sx = constraints.maxWidth / text.size.width;
          final sy = constraints.maxHeight / text.size.height;
          return SelectionArea(
            child: SelectionContainer(
              delegate: _lines,
              child: Stack(
                children: [
                  for (final line in text.lines)
                    Positioned.fromRect(
                      rect: Rect.fromLTRB(
                        line.box.left * sx,
                        line.box.top * sy,
                        line.box.right * sx,
                        line.box.bottom * sy,
                      ),
                      child: _Line(line: line, visible: widget.active),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.line, required this.visible});

  final TextLine line;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // A faint wash shows where the text is.
      decoration: BoxDecoration(
        color: visible ? Colors.white.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(3),
      ),
      child: FittedBox(
        fit: BoxFit.fill,
        child: Text(
          line.text,
          maxLines: 1,
          softWrap: false,
          style: const TextStyle(color: Colors.transparent, fontSize: 40, height: 1.1),
        ),
      ),
    );
  }
}

/// Copies the selected lines one per line (Flutter would run them together).
class _LinesDelegate extends StaticSelectionContainerDelegate {
  @override
  SelectedContent? getSelectedContent() {
    final parts = [
      for (final selectable in selectables)
        if (selectable.getSelectedContent() case final SelectedContent content) content.plainText,
    ];
    return parts.isEmpty ? null : SelectedContent(plainText: parts.join('\n'));
  }
}
