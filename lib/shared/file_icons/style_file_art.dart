import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// Folders and files as the Android and iOS styles draw them ([FolderArt],
/// [FileArt]); all drawn here, nothing taken from Google or Apple.

/// Material's folder, filled: the back with its rounded tab, the front
/// over it, both well rounded, in two tones.
class MaterialFolderPainter extends CustomPainter {
  const MaterialFolderPainter({required this.front, required this.back});

  final Color front;
  final Color back;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final left = w * 0.08;
    final right = w * 0.92;
    final top = h * 0.18;
    final bottom = h * 0.84;
    final r = w * 0.09;
    final tabEnd = left + w * 0.34;
    final shoulder = top + h * 0.08;
    final tab = Path()
      ..moveTo(left, top + r)
      ..quadraticBezierTo(left, top, left + r, top)
      ..lineTo(tabEnd - w * 0.05, top)
      ..cubicTo(tabEnd, top, tabEnd + w * 0.02, shoulder, tabEnd + w * 0.08, shoulder)
      ..lineTo(right - r, shoulder)
      ..quadraticBezierTo(right, shoulder, right, shoulder + r)
      ..lineTo(right, bottom - r)
      ..lineTo(left, bottom - r)
      ..close();
    canvas.drawPath(tab, Paint()..color = back);
    final body = RRect.fromLTRBR(left, top + h * 0.15, right, bottom, Radius.circular(r));
    canvas.drawRRect(body, Paint()..color = front);
  }

  @override
  bool shouldRepaint(MaterialFolderPainter old) => old.front != front || old.back != back;
}

/// The Files app's folder: light blue, the back a shade deeper with a wide
/// rounded tab, the front lighter at the top with a bright edge.
class FilesFolderPainter extends CustomPainter {
  const FilesFolderPainter({required this.front, required this.back});

  final Color front;
  final Color back;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final left = w * 0.07;
    final right = w * 0.93;
    final top = h * 0.19;
    final bottom = h * 0.83;
    final r = w * 0.07;
    final tabEnd = left + w * 0.38;
    final shoulder = top + h * 0.07;
    final tab = Path()
      ..moveTo(left, top + r)
      ..quadraticBezierTo(left, top, left + r, top)
      ..lineTo(tabEnd - w * 0.07, top)
      ..cubicTo(tabEnd - w * 0.02, top, tabEnd - w * 0.01, shoulder, tabEnd + w * 0.05, shoulder)
      ..lineTo(right - r, shoulder)
      ..quadraticBezierTo(right, shoulder, right, shoulder + r)
      ..lineTo(right, bottom - r)
      ..lineTo(left, bottom - r)
      ..close();
    canvas.drawPath(tab, Paint()..color = back);
    final body = RRect.fromLTRBR(left, top + h * 0.13, right, bottom, Radius.circular(r));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(front, Colors.white, 0.18)!, front],
        ).createShader(body.outerRect),
    );
    // The bright top edge of the front.
    canvas.save();
    canvas.clipRRect(body);
    canvas.drawRect(
      Rect.fromLTWH(body.left, body.top, body.width, h * 0.022),
      Paint()..color = Colors.white.withValues(alpha: 0.45),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(FilesFolderPainter old) => old.front != front || old.back != back;
}

/// A file as [art] draws it: Material's tonal page with its kind's symbol,
/// or the Files app's white page with its kind's symbol and type. [color] is
/// the kind's colour (FileIcons), [ext] the extension.
class StyleFileArt extends StatelessWidget {
  const StyleFileArt({
    super.key,
    required this.art,
    required this.kind,
    required this.ext,
    required this.color,
    required this.size,
  });

  final FileArt art;
  final FileKind kind;
  final String ext;
  final Color color;
  final double size;

  /// The symbol for a kind of file; null shows its type in letters.
  static IconData? symbolFor(FileKind kind) => switch (kind) {
        FileKind.image || FileKind.rasterImage || FileKind.svg || FileKind.cameraRaw => LucideIcons.image,
        FileKind.video => LucideIcons.film,
        FileKind.audio => LucideIcons.music,
        FileKind.word ||
        FileKind.legacyWord ||
        FileKind.richText ||
        FileKind.openDocumentText ||
        FileKind.text ||
        FileKind.markdown =>
          LucideIcons.fileText,
        FileKind.spreadsheet ||
        FileKind.legacySpreadsheet ||
        FileKind.delimited ||
        FileKind.openDocumentSpreadsheet =>
          LucideIcons.sheet,
        FileKind.presentation || FileKind.legacyPresentation || FileKind.openDocumentPresentation => LucideIcons.presentation,
        FileKind.epub || FileKind.ebook || FileKind.comic => LucideIcons.bookOpen,
        FileKind.archive || FileKind.diskImage => LucideIcons.archive,
        FileKind.package => LucideIcons.package,
        FileKind.model3d => LucideIcons.box,
        FileKind.design => LucideIcons.penTool,
        FileKind.font => LucideIcons.type,
        FileKind.code || FileKind.html || FileKind.json => LucideIcons.code,
        FileKind.lottie || FileKind.rive => LucideIcons.sparkles,
        FileKind.pdf || FileKind.unknown => null,
      };

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final symbol = symbolFor(kind);
    final label = ext.isEmpty ? '' : (ext.length > 4 ? ext.substring(0, 4) : ext).toUpperCase();
    final family = DefaultTextStyle.of(context).style.fontFamily;
    final material = art == FileArt.material;
    // Material: a container tone of the kind's colour, the symbol in a deep
    // one. Files: a white page, the symbol in the kind's colour.
    final paper = material
        ? Color.lerp(color, dark ? Colors.black : Colors.white, dark ? 0.5 : 0.82)!
        : (dark ? const Color(0xFFF2F2F5) : Colors.white);
    final ink = material ? Color.lerp(color, dark ? Colors.white : Colors.black, dark ? 0.55 : 0.25)! : color;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PagePainter(
          paper: paper,
          fold: material ? Color.lerp(paper, ink, 0.3)! : const Color(0xFFDCDCE1),
          edge: material ? null : (dark ? const Color(0x33FFFFFF) : const Color(0xFFD1D1D6)),
          round: material ? 0.16 : 0.08,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(size * 0.2, size * 0.24, size * 0.2, size * 0.08),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (symbol != null) Icon(symbol, size: size * (material || label.isEmpty ? 0.42 : 0.34), color: ink),
              if (!material || symbol == null)
                if (label.isNotEmpty)
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          fontFamily: family,
                          fontSize: size * (symbol == null ? 0.2 : 0.14),
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                          color: symbol == null ? ink : const Color(0xFF8A8A8E),
                        ),
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

/// A page with its top right corner folded over.
class _PagePainter extends CustomPainter {
  const _PagePainter({required this.paper, required this.fold, required this.edge, required this.round});

  final Color paper;
  final Color fold;
  final Color? edge;

  /// Corner radius, by the page's width.
  final double round;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final left = w * 0.17;
    final right = w * 0.83;
    final top = h * 0.07;
    final bottom = h * 0.93;
    final r = (right - left) * round;
    final f = (right - left) * 0.32;
    final page = Path()
      ..moveTo(left + r, top)
      ..lineTo(right - f, top)
      ..lineTo(right, top + f)
      ..lineTo(right, bottom - r)
      ..quadraticBezierTo(right, bottom, right - r, bottom)
      ..lineTo(left + r, bottom)
      ..quadraticBezierTo(left, bottom, left, bottom - r)
      ..lineTo(left, top + r)
      ..quadraticBezierTo(left, top, left + r, top)
      ..close();
    canvas.drawPath(page, Paint()..color = paper);
    final edge = this.edge;
    if (edge != null) {
      canvas.drawPath(
        page,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (w / 40).clamp(0.6, 1.2)
          ..color = edge,
      );
    }
    final corner = Path()
      ..moveTo(right - f, top)
      ..lineTo(right - f, top + f - r)
      ..quadraticBezierTo(right - f, top + f, right - f + r, top + f)
      ..lineTo(right, top + f)
      ..close();
    canvas.drawPath(corner, Paint()..color = fold);
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.paper != paper || old.fold != fold || old.edge != edge || old.round != round;
}
