import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

/// What vector artwork and animations are drawn on.
enum CanvasBackground {
  /// Transparency grid in the app's colours.
  checker('Transparency grid', LucideIcons.grid2x2),
  light('Light', LucideIcons.sun),
  dark('Dark', LucideIcons.moon);

  const CanvasBackground(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The chosen background, shared by the vector viewers for this session.
final ValueNotifier<CanvasBackground> canvasBackground =
    ValueNotifier(CanvasBackground.checker);

/// Fills its area with [background] behind [child].
class VectorCanvas extends StatelessWidget {
  const VectorCanvas({super.key, required this.background, required this.child});

  final CanvasBackground background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dark = context.isDarkMode;
    final Widget backdrop = switch (background) {
      CanvasBackground.checker => CustomPaint(
          painter: _CheckerPainter(
            base: colors.background,
            cell: dark
                ? colors.muted.withValues(alpha: 0.55)
                : colors.muted.withValues(alpha: 0.9),
          ),
        ),
      // Artwork colours are fixed, so these are plain paper and ink.
      CanvasBackground.light => const ColoredBox(color: Color(0xFFFFFFFF)),
      CanvasBackground.dark => const ColoredBox(color: Color(0xFF0A0A0A)),
    };
    return Stack(
      fit: StackFit.expand,
      children: [Positioned.fill(child: backdrop), child],
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter({required this.base, required this.cell});

  final Color base;
  final Color cell;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final paint = Paint()..color = cell;
    const side = 12.0;
    for (var y = 0.0; y < size.height; y += side) {
      final odd = (y / side).floor().isOdd;
      for (var x = odd ? side : 0.0; x < size.width; x += side * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, side, side), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) =>
      old.base != base || old.cell != cell;
}

/// Header button choosing [canvasBackground].
class CanvasBackgroundButton extends StatelessWidget {
  const CanvasBackgroundButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CanvasBackground>(
      valueListenable: canvasBackground,
      builder: (context, current, _) => MenuIconButton<CanvasBackground>(
        tooltip: 'Background',
        icon: LucideIcons.paintBucket,
        onSelected: (b) => canvasBackground.value = b,
        itemBuilder: (_) => [
          for (final b in CanvasBackground.values)
            menuItem(
              value: b,
              icon: b.icon,
              label: b.label,
              checked: b == current,
            ),
        ],
      ),
    );
  }
}
