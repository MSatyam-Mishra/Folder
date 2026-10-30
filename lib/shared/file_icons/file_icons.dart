import 'package:explorer/shared/file_icons/place_icon.dart';
import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/core/theme/app_style.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/shared/file_icons/file_icon_catalog.g.dart';
import 'package:explorer/shared/file_icons/file_icon_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

export 'package:explorer/shared/file_icons/file_icon_style.dart';

/// What to draw for a file.
sealed class FileIconSpec {
  const FileIconSpec();
}

/// One of the bundled SVGs in assets/iocns.
final class AssetFileIcon extends FileIconSpec {
  const AssetFileIcon(this.asset);
  final String asset;
}

/// The icon_1 page drawn with [label], for types without their own icon.
final class LabelFileIcon extends FileIconSpec {
  const LabelFileIcon(this.label, this.color, {required this.outline});
  final String label;
  final Color color;
  final bool outline;
}

/// Picks icons from the user's icon sets in assets/iocns.
///
/// Code and config files get language/tool logos (programming/), everything
/// else the selected [FileIconStyle]; types a set has no icon for get the
/// same page shape with their extension, in their category's colour.
abstract final class FileIcons {
  static const _base = 'assets/iocns';
  static const folderAsset = '$_base/glass/Folder.svg';

  static final _cache = <(String, FileIconStyle, bool), FileIconSpec>{};
  static final _packageCache = <(String, FileIconStyle, bool), FileIconSpec>{};

  /// [dark]: on a dark background, which picks the `_dark` variants of
  /// logos that would otherwise be black.
  static FileIconSpec forFile(
    String path,
    FileIconStyle style, {
    bool dark = false,
  }) {
    final name = p.basename(path).toLowerCase();
    final byName = kCodeIconByName[name];
    if (byName != null) return AssetFileIcon(_logo(byName, dark));
    final ext = FileTypes.extensionOf(path);
    if (ext.isEmpty) return _resolve(ext, FileTypes.kindOf(path), style, dark);
    return _cache.putIfAbsent(
      (ext, style, dark),
      () => _resolve(ext, FileTypes.kindOf(path), style, dark),
    );
  }

  /// Icon for a macOS package (an app, installer or document package),
  /// which Finder shows as one item rather than a folder: Xcode's logo for
  /// Xcode projects, otherwise a page labelled with the extension ("APP",
  /// "PKG") in the colour of what it holds.
  static FileIconSpec forPackage(
    String path,
    FileIconStyle style, {
    bool dark = false,
  }) {
    final ext = FileTypes.extensionOf(path);
    return _packageCache.putIfAbsent((ext, style, dark), () {
      if (_xcodePackages.contains(ext)) return AssetFileIcon(_logo('xcode', dark));
      return _labelled(ext, _packageKinds[ext] ?? FileKind.package, style);
    });
  }

  /// Packages Xcode opens.
  static const _xcodePackages = {
    'xcodeproj', 'xcworkspace', 'playground', 'xcarchive',
  };

  /// Document packages coloured like their kind of document; apps,
  /// installers and plug-ins are [FileKind.package]. Their names ("Keynote
  /// presentation") are in `EntityFormat.kind`.
  static const _packageKinds = {
    'rtfd': FileKind.richText,
    'pages': FileKind.word,
    'numbers': FileKind.spreadsheet,
    'key': FileKind.presentation,
    'photoslibrary': FileKind.image,
    'photolibrary': FileKind.image,
    'musiclibrary': FileKind.audio,
    'logicx': FileKind.audio,
    'band': FileKind.audio,
    'imovielibrary': FileKind.video,
    'theater': FileKind.video,
    'fcpbundle': FileKind.video,
  };

  static String _logo(String name, bool dark) {
    final variant = dark && kProgrammingIcons.contains('${name}_dark')
        ? '${name}_dark'
        : name;
    return '$_base/programming/$variant.svg';
  }

  static FileIconSpec _resolve(
    String ext,
    FileKind kind,
    FileIconStyle style,
    bool dark,
  ) {
    final codeLogo = kCodeIconByExtension[ext] ??
        (_codeLike.contains(kind) && kProgrammingIcons.contains(ext)
            ? ext
            : null);
    // Source and config files: language logos in every style.
    if (codeLogo != null && _codeLike.contains(kind)) {
      return AssetFileIcon(_logo(codeLogo, dark));
    }
    final styled = _styled(ext, kind, style);
    if (styled != null) return styled;
    // Binaries with a tool logo (APK, DLL, ISO, databases…).
    if (codeLogo != null) return AssetFileIcon(_logo(codeLogo, dark));
    return _labelled(ext, kind, style);
  }

  /// A page labelled with a short [ext] in [kind]'s colour, or [kind]'s
  /// category icon for long or missing extensions.
  static FileIconSpec _labelled(String ext, FileKind kind, FileIconStyle style) {
    final color = Color(_colorFor(kind));
    if (ext.isNotEmpty && ext.length <= 5) {
      return LabelFileIcon(
        ext.toUpperCase(),
        color,
        outline: style != FileIconStyle.solid,
      );
    }
    final category = _categoryFor(kind);
    return AssetFileIcon(
      style == FileIconStyle.solid
          ? '$_base/file_type/icon_1/Color=Icon + Solid, File Type=$category.svg'
          : '$_base/file_type/icon_1/Color=Icon + Outline, File Type=$category.svg',
    );
  }

  static AssetFileIcon? _styled(String ext, FileKind kind, FileIconStyle style) {
    final label = _labelAliases[ext] ?? ext.toUpperCase();
    switch (style) {
      case FileIconStyle.solid:
        if (kSolidLabelColors.containsKey(label)) {
          return AssetFileIcon(
              '$_base/file_type/icon_1/Color=Solid, File Type=$label.svg');
        }
      case FileIconStyle.classic:
        final classic = kind == FileKind.cameraRaw
            ? 'RAW'
            : _classicAliases[ext] ?? ext.toUpperCase();
        if (kClassicLabels.contains(classic)) {
          return AssetFileIcon('$_base/file_type/icon_2/$classic.svg');
        }
        continue outline;
      outline:
      case FileIconStyle.outline:
        if (kOutlineLabels.contains(label)) {
          return AssetFileIcon(
              '$_base/file_type/icon_1/Color=Outline + Color, File Type=$label.svg');
        }
    }
    return null;
  }

  static const _codeLike = {
    FileKind.code,
    FileKind.text,
    FileKind.json,
    FileKind.markdown,
    FileKind.html,
    FileKind.unknown,
  };

  /// Extensions sharing another extension's icon_1 icon.
  static const _labelAliases = {
    'jpeg': 'JPG', 'jfif': 'JPG', 'pjpeg': 'JPG', 'mpg': 'MPEG',
    'docm': 'DOCX', 'dotx': 'DOCX', 'dotm': 'DOCX', 'dot': 'DOC',
    'xlsm': 'XLSX', 'xltx': 'XLSX', 'xltm': 'XLSX', 'xlt': 'XLS',
    'pptm': 'PPTX', 'ppsx': 'PPTX', 'potx': 'PPTX', 'ppsm': 'PPTX',
    'pps': 'PPT', 'pot': 'PPT', 'svgz': 'SVG', 'indt': 'INDD',
  };

  /// Extensions sharing another extension's icon_2 icon.
  static const _classicAliases = {
    'jpeg': 'JPG', 'jfif': 'JPG', 'gif': 'GIFF', 'tif': 'TIFF',
    'mid': 'MID', 'midi': 'MID', 'mpg': 'MPEG', 'docm': 'DOCX',
    'dotx': 'DOCX', 'dot': 'DOC', 'pptx': 'PPT', 'pptm': 'PPT',
    'pps': 'PPT', 'ppsx': 'PPT', 'pot': 'PPT', 'potx': 'PPT',
    'epsf': 'EPS', 'epsi': 'EPS', 'msi': 'EXE', 'accdb': 'MDB',
    'qt': 'MOV', 'svgz': 'SVG',
  };

  static int _colorFor(FileKind kind) => switch (kind) {
        FileKind.pdf => 0xFFD92D20,
        FileKind.word ||
        FileKind.legacyWord ||
        FileKind.richText ||
        FileKind.openDocumentText ||
        FileKind.video =>
          0xFF155EEF,
        FileKind.spreadsheet ||
        FileKind.legacySpreadsheet ||
        FileKind.delimited ||
        FileKind.openDocumentSpreadsheet =>
          0xFF079455,
        FileKind.presentation ||
        FileKind.legacyPresentation ||
        FileKind.openDocumentPresentation =>
          0xFFE62E05,
        FileKind.image ||
        FileKind.rasterImage ||
        FileKind.svg ||
        FileKind.cameraRaw =>
          0xFF7F56D9,
        FileKind.audio => 0xFFDD2590,
        FileKind.epub || FileKind.ebook || FileKind.comic => 0xFFE04F16,
        FileKind.design => 0xFFBA24D5,
        FileKind.model3d => 0xFF0E9384,
        FileKind.font || FileKind.lottie || FileKind.rive => 0xFF6938EF,
        FileKind.archive || FileKind.diskImage || FileKind.package =>
          0xFF414651,
        FileKind.code ||
        FileKind.json ||
        FileKind.html ||
        FileKind.markdown ||
        FileKind.text =>
          0xFF343A3E,
        FileKind.unknown => 0xFF667085,
      };

  static String _categoryFor(FileKind kind) => switch (kind) {
        FileKind.image ||
        FileKind.rasterImage ||
        FileKind.svg ||
        FileKind.cameraRaw =>
          'Image',
        FileKind.video => 'Video',
        FileKind.audio => 'Audio',
        FileKind.pdf => 'PDF',
        FileKind.spreadsheet ||
        FileKind.legacySpreadsheet ||
        FileKind.delimited ||
        FileKind.openDocumentSpreadsheet =>
          'Excel',
        FileKind.code || FileKind.json || FileKind.html => 'Code',
        _ => 'Documents',
      };
}

/// Icon for a file or folder from the user's icon sets.
class FileIcon extends StatelessWidget {
  const FileIcon({
    super.key,
    required this.path,
    this.size = 40,
    this.isDirectory = false,
    this.isPackage = false,
    this.style,
  });

  final String path;
  final double size;
  final bool isDirectory;

  /// A macOS package (an app, installer or document package), drawn like
  /// a file with [FileIcons.forPackage]. [isDirectory] wins over it.
  final bool isPackage;

  /// Defaults to the style chosen in Options.
  final FileIconStyle? style;

  @override
  Widget build(BuildContext context) {
    if (isDirectory) return FolderIcon(size: size, path: path);
    final style =
        this.style ??
        context.select<ThemeCubit, FileIconStyle>((c) => c.state.fileIconStyle);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final spec = isPackage
        ? FileIcons.forPackage(path, style, dark: dark)
        : FileIcons.forFile(path, style, dark: dark);
    return switch (spec) {
      // icon_2 pages are tinted at ~9% opacity and vanish on dark
      // backgrounds; give them the white page they have in light mode.
      AssetFileIcon(:final asset) when dark && asset.contains('/icon_2/') =>
        CustomPaint(
          size: Size.square(size),
          painter: const _ClassicPageUnderlay(),
          child: SvgPicture.asset(
            asset,
            width: size,
            height: size,
            fit: BoxFit.contain,
          ),
        ),
      AssetFileIcon(:final asset) => SvgPicture.asset(
          asset,
          width: size,
          height: size,
          fit: BoxFit.contain,
        ),
      LabelFileIcon(:final label, :final color, :final outline) => CustomPaint(
          size: Size.square(size),
          painter: _LabelIconPainter(
            label,
            color,
            outline: outline,
            fontFamily: DefaultTextStyle.of(context).style.fontFamily,
          ),
        ),
    };
  }
}

/// The glass folder from assets/iocns/glass, or a folder in the colours of
/// the style chosen (Finder's blue, Windows' yellow...).
class FolderIcon extends StatelessWidget {
  const FolderIcon({super.key, this.size = 40, this.path});

  final double size;

  /// The folder: the home folder, Documents, Downloads... get their own
  /// icon in styles with an icon theme, a symbol on the folder in others.
  final String? path;

  @override
  Widget build(BuildContext context) {
    final look = context.look;
    final folder = look.folder;
    final path = this.path;
    final place = path == null ? null : Place.of(path);
    final Widget art;
    if (look.iconPack != null) {
      art = SvgPicture.asset(
        place?.assetFor(look) ?? 'assets/icon_themes/${look.iconPack}/folder.svg',
        fit: BoxFit.contain,
      );
    } else if (folder != null) {
      art = CustomPaint(
        painter: _FolderPainter(front: folder.$1, back: folder.$2),
        child: place == null
            ? null
            : Align(
                alignment: const Alignment(0, 0.42),
                child: Icon(place.glyph, size: size * 0.32, color: Color.lerp(folder.$2, Colors.black, 0.18)),
              ),
      );
    } else {
      art = SvgPicture.asset(FileIcons.folderAsset, fit: BoxFit.contain);
    }
    // The folder art isn't square; keep it inside a size×size box.
    return SizedBox.square(dimension: size, child: art);
  }
}

/// A flat folder: the back with its tab, and the front a little lower.
class _FolderPainter extends CustomPainter {
  const _FolderPainter({required this.front, required this.back});

  final Color front;
  final Color back;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // As wide as the glass folder, and as tall: about 80% by 64%.
    final left = w * 0.08;
    final right = w * 0.92;
    final top = h * 0.2;
    final bottom = h * 0.84;
    final r = w * 0.06;
    final tab = Path()
      ..moveTo(left, top + r)
      ..quadraticBezierTo(left, top, left + r, top)
      ..lineTo(left + w * 0.3, top)
      ..quadraticBezierTo(left + w * 0.34, top, left + w * 0.37, top + h * 0.05)
      ..lineTo(left + w * 0.4, top + h * 0.08)
      ..lineTo(right - r, top + h * 0.08)
      ..quadraticBezierTo(right, top + h * 0.08, right, top + h * 0.08 + r)
      ..lineTo(right, bottom - r)
      ..lineTo(left, bottom - r)
      ..close();
    canvas.drawPath(tab, Paint()..color = back);
    final body = RRect.fromLTRBR(left, top + h * 0.17, right, bottom, Radius.circular(r));
    canvas.drawRRect(
      body,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(front, Colors.white, 0.12)!, front],
        ).createShader(body.outerRect),
    );
  }

  @override
  bool shouldRepaint(_FolderPainter old) => old.front != front || old.back != back;
}

/// White page behind an icon_2 SVG (201×240 view box, drawn with
/// BoxFit.contain): the page body minus its folded corner.
class _ClassicPageUnderlay extends CustomPainter {
  const _ClassicPageUnderlay();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.height / 240;
    canvas.save();
    canvas.translate((size.width - 201 * scale) / 2, 0);
    canvas.scale(scale);
    final page = Path()
      ..moveTo(26.92, 0)
      ..lineTo(119.05, 0)
      ..lineTo(164.43, 49.25)
      ..lineTo(164.43, 189.13)
      ..arcToPoint(const Offset(137.52, 216.04),
          radius: const Radius.circular(26.91))
      ..lineTo(26.92, 216.04)
      ..arcToPoint(const Offset(0, 189.13), radius: const Radius.circular(26.91))
      ..lineTo(0, 26.91)
      ..arcToPoint(const Offset(26.92, 0), radius: const Radius.circular(26.91))
      ..close();
    canvas.drawPath(page, Paint()..color = const Color(0xFFF5F7FA));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClassicPageUnderlay old) => false;
}

/// Draws icon_1's page (40×40 view box) with a text label, matching the
/// "Solid" and "Outline + Color" SVGs for extensions they don't include.
class _LabelIconPainter extends CustomPainter {
  _LabelIconPainter(
    this.label,
    this.color, {
    required this.outline,
    this.fontFamily,
  });

  final String label;
  final Color color;
  final bool outline;
  final String? fontFamily;

  static final Path _solidPage = Path()
    ..moveTo(9.57031, 0)
    ..lineTo(24, 0)
    ..lineTo(36, 12)
    ..lineTo(36, 34.7926)
    ..cubicTo(36, 37.6712, 33.5088, 40, 30.4403, 40)
    ..lineTo(9.57031, 40)
    ..cubicTo(6.49114, 40, 4, 37.6712, 4, 34.7926)
    ..lineTo(4, 5.20738)
    ..cubicTo(3.99995, 2.32883, 6.49108, 0, 9.57031, 0)
    ..close();

  static final Path _solidFold = Path()
    ..moveTo(24.0257, 8.16)
    ..lineTo(24.0257, 0)
    ..lineTo(36, 12)
    ..lineTo(28.0171, 12)
    ..cubicTo(24.4248, 12, 23.8593, 9.44, 24.0257, 8.16)
    ..close();

  static final Path _outlinePage = Path()
    ..moveTo(12.6943, 0.5)
    ..lineTo(26.793, 0.5)
    ..lineTo(38.5, 12.207)
    ..lineTo(38.5, 34.793)
    ..cubicTo(38.4998, 37.3646, 36.2642, 39.4999, 33.4404, 39.5)
    ..lineTo(12.5703, 39.5)
    ..cubicTo(9.73516, 39.5, 7.50023, 37.364, 7.5, 34.793)
    ..lineTo(7.5, 5.20703)
    ..cubicTo(7.50013, 2.64972, 9.84436, 0.500142, 12.6943, 0.5)
    ..close();

  static final Path _outlineFold = Path()
    ..moveTo(27.0257, 8.16)
    ..lineTo(27.0257, 0)
    ..lineTo(39, 12)
    ..lineTo(31.0171, 12)
    ..cubicTo(27.4248, 12, 26.8593, 9.44, 27.0257, 8.16)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 40;
    canvas.save();
    canvas.translate(
      (size.width - 40 * scale) / 2,
      (size.height - 40 * scale) / 2,
    );
    canvas.scale(scale);
    if (outline) {
      canvas
        ..drawPath(_outlinePage, Paint()..color = Colors.white)
        ..drawPath(
          _outlinePage,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0xFFDBDBDB),
        )
        ..drawPath(_outlineFold, Paint()..color = const Color(0xFFD4D4D8));
      final text = _text(maxWidth: 32);
      final tagWidth = (text.width + 8).clamp(15.0, 37.0);
      canvas.drawRRect(
        RRect.fromLTRBR(1, 19, 1 + tagWidth, 34, const Radius.circular(3)),
        Paint()..color = color,
      );
      text.paint(canvas, Offset(1 + (tagWidth - text.width) / 2, 26.5 - text.height / 2));
    } else {
      canvas
        ..drawPath(_solidPage, Paint()..color = color)
        ..drawPath(
          _solidFold,
          Paint()..color = Colors.white.withValues(alpha: 0.3),
        );
      final text = _text(maxWidth: 26);
      text.paint(canvas, Offset(20 - text.width / 2, 28.7 - text.height / 2));
    }
    canvas.restore();
  }

  /// White bold label, shrunk to fit [maxWidth] view-box units.
  TextPainter _text({required double maxWidth}) {
    var fontSize = 9.0;
    while (true) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: 0,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      if (painter.width <= maxWidth || fontSize <= 5) return painter;
      fontSize -= 0.5;
    }
  }

  @override
  bool shouldRepaint(_LabelIconPainter old) =>
      old.label != label ||
      old.color != color ||
      old.outline != outline ||
      old.fontFamily != fontFamily;
}
