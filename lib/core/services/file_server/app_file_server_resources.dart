import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:folders/core/services/file_server/http_file_server.dart';
import 'package:folders/core/theme/app_color_theme.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:shadcn_ui/shadcn_ui.dart' show ShadColorScheme;

/// [FileServerResources] from the app: the user's file icon set, Geist and
/// thumbnails decoded by the engine.
class AppFileServerResources implements FileServerResources {
  AppFileServerResources({required this.iconStyle});

  final FileIconStyle iconStyle;

  final _icons = <String, FileIconSpec>{};
  final _thumbnails = <String, Uint8List>{};
  int _thumbnailBytes = 0;
  int _decoding = 0;
  final _waiting = Queue<Completer<void>>();

  static const _maxDecoding = 2;
  static const _thumbnailCacheBytes = 24 << 20;

  @override
  String get folderIcon => 'folder';

  @override
  String iconFor(String name, {required bool dark}) {
    final spec = FileIcons.forFile(name, iconStyle, dark: dark);
    final id = switch (spec) {
      // icon_2 pages are nearly transparent on dark pages: those get a white
      // page underneath, as in the app.
      AssetFileIcon(:final asset) =>
        '${dark && asset.contains('/icon_2/') ? 'u' : 'a'}${_hash(asset)}',
      LabelFileIcon(:final label, :final color, :final outline) =>
        'l${outline ? 'o' : 's'}${_hex(color)}${_hash(label)}',
    };
    _icons[id] = spec;
    return id;
  }

  @override
  Future<String?> iconSvg(String id) async {
    if (id == folderIcon) return _loadString(FileIcons.folderAsset);
    final spec = _icons[id];
    switch (spec) {
      case AssetFileIcon(:final asset):
        final svg = await _loadString(asset);
        return svg != null && id.startsWith('u') ? _withPage(svg) : svg;
      case LabelFileIcon(:final label, :final color, :final outline):
        return _labelIcon(label, color, outline: outline);
      case null:
        return null;
    }
  }

  @override
  Future<Uint8List?> font() async {
    try {
      final data = await rootBundle.load(
        'packages/shadcn_ui/fonts/Geist[wght].ttf',
      );
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> thumbnail(File file, int size) async {
    final FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      return null;
    }
    final key =
        '${file.path}|$size|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    final cached = _thumbnails.remove(key);
    if (cached != null) return _thumbnails[key] = cached;

    // Decoding big photos is heavy: a couple at a time.
    while (_decoding >= _maxDecoding) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _decoding++;
    try {
      final jpeg = await _encode(await file.readAsBytes(), size);
      if (jpeg != null) {
        _thumbnails[key] = jpeg;
        _thumbnailBytes += jpeg.length;
        while (_thumbnailBytes > _thumbnailCacheBytes &&
            _thumbnails.isNotEmpty) {
          final oldest = _thumbnails.keys.first;
          _thumbnailBytes -= _thumbnails.remove(oldest)!.length;
        }
      }
      return jpeg;
    } catch (_) {
      return null;
    } finally {
      _decoding--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  static Future<Uint8List?> _encode(Uint8List bytes, int size) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Only the long side is given, so the engine keeps the aspect ratio
    // (including EXIF rotation).
    final landscape = descriptor.width >= descriptor.height;
    final longSide = max(descriptor.width, descriptor.height);
    final target = min(size, longSide);
    final codec = await descriptor.instantiateCodec(
      targetWidth: landscape ? target : null,
      targetHeight: landscape ? null : target,
    );
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
    try {
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rgba == null) return null;
      final width = image.width, height = image.height;
      final pixels = rgba.buffer.asUint8List(
        rgba.offsetInBytes,
        rgba.lengthInBytes,
      );
      return await Isolate.run(() {
        final frame = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: pixels.buffer,
          numChannels: 4,
        );
        return img.encodeJpg(frame, quality: 82);
      });
    } finally {
      image.dispose();
    }
  }

  static Future<String?> _loadString(String asset) async {
    try {
      return await rootBundle.loadString(asset);
    } catch (_) {
      return null;
    }
  }

  /// Puts a white page (the icon_2 outline, 200×240) under [svg].
  static String _withPage(String svg) {
    final open = svg.indexOf('<svg');
    final end = open < 0 ? -1 : svg.indexOf('>', open);
    if (end < 0) return svg;
    return '${svg.substring(0, end + 1)}'
        '<path d="M26.92 0H119.05L164.43 49.25V189.13A26.91 26.91 0 0 1 137.52 216.04H26.92A26.91 26.91 0 0 1 0 189.13V26.91A26.91 26.91 0 0 1 26.92 0Z" fill="#F5F7FA"/>'
        '${svg.substring(end + 1)}';
  }

  /// SVG version of the label icons the app paints for types without an
  /// icon of their own (see `_LabelIconPainter`).
  static String _labelIcon(String label, Color color, {required bool outline}) {
    final fill = '#${_hex(color)}';
    final text = const HtmlEscape().convert(label);
    final fontSize = switch (label.length) {
      <= 3 => 9.0,
      4 => 8.0,
      _ => 7.0,
    };
    final width = label.length * fontSize * 0.64;
    if (outline) {
      final textWidth = min(width, 32.0);
      final tag = (textWidth + 8).clamp(15.0, 37.0);
      return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">'
          '<path d="M12.6943 0.5H26.793L38.5 12.207V34.793C38.4998 37.3646 36.2642 39.4999 33.4404 39.5H12.5703C9.73516 39.5 7.50023 37.364 7.5 34.793V5.20703C7.50013 2.64972 9.84436 0.500142 12.6943 0.5Z" fill="#fff" stroke="#DBDBDB"/>'
          '<path d="M27.0257 8.16V0L39 12H31.0171C27.4248 12 26.8593 9.44 27.0257 8.16Z" fill="#D4D4D8"/>'
          '<rect x="1" y="19" width="${_n(tag)}" height="15" rx="3" fill="$fill"/>'
          '${_text(text, 1 + tag / 2, 26.5, fontSize, width > 32 ? 32 : null)}'
          '</svg>';
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">'
        '<path d="M9.57031 0H24L36 12V34.7926C36 37.6712 33.5088 40 30.4403 40H9.57031C6.49114 40 4 37.6712 4 34.7926V5.20738C3.99995 2.32883 6.49108 0 9.57031 0Z" fill="$fill"/>'
        '<path d="M24.0257 8.16V0L36 12H28.0171C24.4248 12 23.8593 9.44 24.0257 8.16Z" fill="#fff" fill-opacity="0.3"/>'
        '${_text(text, 20, 28.7, fontSize, width > 26 ? 26 : null)}'
        '</svg>';
  }

  static String _text(
    String text,
    double x,
    double centerY,
    double size,
    double? squeezeTo,
  ) =>
      '<text x="${_n(x)}" y="${_n(centerY + size * 0.36)}" text-anchor="middle" '
      'font-family="Geist,Inter,Segoe UI,Roboto,Arial,sans-serif" font-weight="700" '
      'font-size="${_n(size)}" fill="#fff"'
      '${squeezeTo == null ? '' : ' textLength="${_n(squeezeTo)}" lengthAdjust="spacingAndGlyphs"'}'
      '>$text</text>';

  static String _n(double v) =>
      v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

  static String _hex(Color color) =>
      (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0');

  /// FNV-1a, as a short stable id.
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(36);
  }
}

/// The page colours for the app's colour [theme].
WebTheme webThemeFor(AppColorThemeSpec theme) => WebTheme(
  light: _cssVariables(theme.schemeFor(Brightness.light)),
  dark: _cssVariables(theme.schemeFor(Brightness.dark)),
);

Map<String, String> _cssVariables(ShadColorScheme c) => {
  'background': _css(c.background),
  'foreground': _css(c.foreground),
  'card': _css(c.card),
  'card-foreground': _css(c.cardForeground),
  'popover': _css(c.popover),
  'popover-foreground': _css(c.popoverForeground),
  'primary': _css(c.primary),
  'primary-foreground': _css(c.primaryForeground),
  'muted': _css(c.muted),
  'muted-foreground': _css(c.mutedForeground),
  'accent': _css(c.accent),
  'accent-foreground': _css(c.accentForeground),
  'destructive': _css(c.destructive),
  'border': _css(c.border),
  'input': _css(c.input),
  'ring': _css(c.ring),
};

String _css(Color color) {
  final argb = color.toARGB32();
  final rgb = '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  final alpha = argb >>> 24;
  if (alpha == 0xFF) return rgb;
  return 'color-mix(in srgb,$rgb ${(alpha / 255 * 100).toStringAsFixed(1)}%,transparent)';
}
