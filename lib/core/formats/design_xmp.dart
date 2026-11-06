import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folders/core/formats/exif_bytes.dart';

/// A thumbnail stored in XMP (`xmpGImg:image`, base64 JPEG), as Illustrator
/// and InDesign write them.
class XmpThumbnail {
  const XmpThumbnail(this.bytes, {this.width, this.height});

  final Uint8List bytes;
  final int? width;
  final int? height;
}

/// An XMP packet, queried with regular expressions: enough for the simple
/// properties and thumbnails the previews need, tolerant of the element and
/// attribute forms both found in the wild.
class XmpPacket {
  XmpPacket(this.xml);

  final String xml;

  static final _packet = RegExp(
    r'<x:xmpmeta[\s\S]*?</x:xmpmeta>|<rdf:RDF[\s\S]*?</rdf:RDF>',
  );

  /// The packets in [text], in order.
  static List<XmpPacket> allIn(String text) =>
      [for (final m in _packet.allMatches(text)) XmpPacket(m[0]!)];

  /// Searches [src] for XMP packets, looking in [regions] (start, length)
  /// first and then, if [fullScan] allows, the whole file in chunks.
  static List<XmpPacket> findIn(
    RandomBytes src, {
    List<(int, int)> regions = const [],
    bool fullScan = true,
    int maxScan = 256 << 20,
  }) {
    for (final (start, length) in regions) {
      final s = math.max(0, start);
      final found = _scan(src, s, math.min(src.length, s + length));
      if (found.isNotEmpty) return found;
    }
    if (!fullScan) return const [];
    return _scan(src, 0, math.min(src.length, maxScan));
  }

  static final _open = ascii.encode('<x:xmpmeta');
  static final _close = ascii.encode('</x:xmpmeta>');

  static List<XmpPacket> _scan(RandomBytes src, int start, int end) {
    final out = <XmpPacket>[];
    var pos = start;
    while (pos < end && out.length < 8) {
      final open = src.indexOf(_open, start: pos, end: end);
      if (open < 0) break;
      // Packets are rarely over a few MB, even with many thumbnails.
      final close = src.indexOf(_close, start: open, end: math.min(end, open + (32 << 20)));
      if (close < 0) break;
      final bytes = src.read(open, close + _close.length - open);
      out.add(XmpPacket(utf8.decode(bytes, allowMalformed: true)));
      pos = close + _close.length;
    }
    return out;
  }

  /// First value of property [name] (e.g. "xmp:CreatorTool"): element text,
  /// the first rdf:li of an Alt/Seq/Bag, or an attribute. Files from before
  /// 2004 use "xap" prefixes, which are tried too.
  String? value(String name) {
    final legacy = _legacy(name);
    return _value(name) ?? (legacy == null ? null : _value(legacy));
  }

  static String? _legacy(String name) {
    for (final (now, old) in const [
      ('xmp:', 'xap:'),
      ('xmpMM:', 'xapMM:'),
      ('xmpGImg:', 'xapGImg:'),
      ('xmpTPg:', 'xapTPg:'),
    ]) {
      if (name.startsWith(now)) return old + name.substring(now.length);
    }
    return null;
  }

  String? _value(String name) {
    final q = RegExp.escape(name);
    final element = RegExp('<$q(?:\\s[^>]*)?>([\\s\\S]*?)</$q>').firstMatch(xml);
    if (element != null) {
      final inner = element[1]!;
      final li = RegExp(r'<rdf:li(?:\s[^>]*)?>([\s\S]*?)</rdf:li>')
          .firstMatch(inner);
      final text = _clean(li != null ? li[1]! : inner);
      if (text.isNotEmpty && !text.startsWith('<')) return _unescape(text);
    }
    final attr =
        RegExp('\\s$q=(?:"([^"]*)"|\'([^\']*)\')').firstMatch(xml);
    if (attr != null) {
      final text = _clean(attr[1] ?? attr[2]!);
      if (text.isNotEmpty) return _unescape(text);
    }
    return null;
  }

  /// Every rdf:li value (or nested [field] value) inside property [name].
  List<String> values(String name, {String? field}) {
    final q = RegExp.escape(name);
    final element = RegExp('<$q(?:\\s[^>]*)?>([\\s\\S]*?)</$q>').firstMatch(xml);
    if (element == null) return const [];
    final inner = element[1]!;
    final out = <String>[];
    if (field != null) {
      final f = RegExp.escape(field);
      for (final m in RegExp('<$f>([^<]*)</$f>').allMatches(inner)) {
        out.add(_unescape(_clean(m[1]!)));
      }
      for (final m in RegExp('\\s$f="([^"]*)"').allMatches(inner)) {
        out.add(_unescape(_clean(m[1]!)));
      }
    } else {
      for (final m in RegExp(r'<rdf:li(?:\s[^>]*)?>([^<]*)</rdf:li>')
          .allMatches(inner)) {
        out.add(_unescape(_clean(m[1]!)));
      }
    }
    return out.where((s) => s.isNotEmpty).toList();
  }

  /// Number of rdf:li items directly inside property [name].
  int count(String name) {
    final q = RegExp.escape(name);
    final element = RegExp('<$q(?:\\s[^>]*)?>([\\s\\S]*?)</$q>').firstMatch(xml);
    if (element == null) return 0;
    return RegExp(r'<rdf:li[\s>]').allMatches(element[1]!).length;
  }

  /// The base64 JPEG thumbnails in the packet (element or attribute form,
  /// current or legacy prefix), largest first.
  List<XmpThumbnail> thumbnails() {
    final out = <XmpThumbnail>[];
    final seen = <String>{};
    void add(String data) {
      final key = data.length > 96 ? data.substring(0, 96) : data;
      if (!seen.add(key)) return;
      final bytes = _decodeBase64(data);
      if (bytes == null || bytes.length < 64) return;
      out.add(XmpThumbnail(bytes));
    }

    for (final m
        in RegExp(r'<(x[am]pGImg):image>([\s\S]*?)</\1:image>').allMatches(xml)) {
      add(m[2]!);
    }
    for (final m in RegExp(r'''x[am]pGImg:image=(?:"([^"]*)"|'([^']*)')''')
        .allMatches(xml)) {
      add(m[1] ?? m[2]!);
    }
    out.sort((a, b) => b.bytes.length.compareTo(a.bytes.length));
    return out;
  }

  static Uint8List? _decodeBase64(String text) {
    var s = text
        .replaceAll(RegExp(r'&#x[aAdD];|&#1[03];'), '')
        .replaceAll(RegExp(r'\s+'), '');
    if (s.isEmpty) return null;
    s = s.replaceAll(RegExp(r'[^A-Za-z0-9+/=]'), '');
    final pad = s.length % 4;
    if (pad == 1) return null;
    if (pad > 0) s = s.padRight(s.length + 4 - pad, '=');
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#xA;', ' ')
      .replaceAll('&amp;', '&');
}
