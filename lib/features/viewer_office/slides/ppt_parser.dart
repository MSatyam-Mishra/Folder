import 'dart:math' as math;
import 'dart:typed_data';

import 'package:folder/core/formats/cfb_reader.dart';

import '../common/office_package.dart';
import 'slide_model.dart';

/// Thrown for password-protected presentations.
class PresentationEncryptedException implements Exception {
  const PresentationEncryptedException();
  @override
  String toString() => 'This presentation is password-protected.';
}

/// Parses PowerPoint 97–2003 (`.ppt`, `.pps`, `.pot`) into a view-only deck
/// of positioned text boxes and pictures.
SlideDeck parsePptBytes(Uint8List bytes) =>
    _PptParser(CfbReader(bytes)).parse();

class _Rec {
  _Rec(this.ver, this.instance, this.type, this.offset, this.length);
  final int ver;
  final int instance;
  final int type;

  /// Offset of the record body (after the 8-byte header).
  final int offset;
  final int length;
  bool get isContainer => ver == 0xF;
  int get end => offset + length;
}

class _Text {
  _Text(this.type, this.text);
  final int type;
  final String text;
}

class _PptParser {
  _PptParser(this.cfb);

  final CfbReader cfb;
  late final Uint8List s;
  late final ByteData bd;
  Uint8List? pictures;
  final Map<int, int> persist = {};
  final List<int> blipOffsets = []; // BStore index → offset in Pictures (or -1)
  final List<Uint8List?> blipEmbedded = [];
  final Map<String, SlideImageData> images = {};

  int u16(int o) => o + 2 <= s.length ? bd.getUint16(o, Endian.little) : 0;
  int u32(int o) => o + 4 <= s.length ? bd.getUint32(o, Endian.little) : 0;
  int i32(int o) => o + 4 <= s.length ? bd.getInt32(o, Endian.little) : 0;
  int i16(int o) => o + 2 <= s.length ? bd.getInt16(o, Endian.little) : 0;

  _Rec? rec(int o) {
    if (o < 0 || o + 8 > s.length) return null;
    final vi = u16(o);
    final len = u32(o + 4);
    if (o + 8 + len > s.length + 8) return null;
    return _Rec(
      vi & 0xF,
      vi >> 4,
      u16(o + 2),
      o + 8,
      math.min(len, s.length - o - 8),
    );
  }

  Iterable<_Rec> children(_Rec r) sync* {
    var o = r.offset;
    while (o + 8 <= r.end) {
      final c = rec(o);
      if (c == null) return;
      yield c;
      o = c.end;
    }
  }

  _Rec? child(_Rec r, int type, {int? instance}) {
    for (final c in children(r)) {
      if (c.type == type && (instance == null || c.instance == instance)) {
        return c;
      }
    }
    return null;
  }

  Iterable<_Rec> descendants(_Rec r, int type) sync* {
    for (final c in children(r)) {
      if (c.type == type) yield c;
      if (c.isContainer) yield* descendants(c, type);
    }
  }

  SlideDeck parse() {
    if (cfb.find('EncryptedSummary') != null) {
      throw const PresentationEncryptedException();
    }
    final doc = cfb.readStream('PowerPoint Document');
    if (doc == null) {
      throw const FormatException('Not a PowerPoint presentation.');
    }
    s = doc;
    bd = ByteData.sublistView(s);
    pictures = cfb.readStream('Pictures');

    final cu = cfb.readStream('Current User');
    var editOffset = -1;
    if (cu != null && cu.length >= 20) {
      final cbd = ByteData.sublistView(cu);
      final token = cbd.getUint32(12, Endian.little);
      if (token == 0xF3D1C4DF) throw const PresentationEncryptedException();
      editOffset = cbd.getUint32(16, Endian.little);
    }

    _Rec? docRec;
    if (editOffset >= 0) {
      try {
        docRec = _readPersist(editOffset);
      } catch (_) {
        docRec = null;
      }
    }
    if (docRec == null) {
      // Fall back to the first DocumentContainer in the stream.
      var o = 0;
      while (o + 8 <= s.length) {
        final r = rec(o);
        if (r == null) break;
        if (r.type == 0x03E8) {
          docRec = r;
          break;
        }
        o = r.end;
      }
    }
    if (docRec == null) {
      throw const FormatException('This presentation has no slides.');
    }

    var width = 720.0, height = 540.0;
    final atom = child(docRec, 0x03E9);
    if (atom != null) {
      final w = i32(atom.offset) / 8, h = i32(atom.offset + 4) / 8;
      if (w > 50 && h > 50) {
        width = w;
        height = h;
      }
    }
    _readBStore(docRec);

    // Notes: notes id → persist id.
    final notesById = <int, int>{};
    final notesList = child(docRec, 0x0FF0, instance: 2);
    if (notesList != null) {
      for (final c in children(notesList)) {
        if (c.type == 0x03F3) notesById[u32(c.offset + 12)] = u32(c.offset);
      }
    }

    final slides = <Slide>[];
    final slideList = child(docRec, 0x0FF0, instance: 0);
    if (slideList != null) {
      int? currentPersist;
      var texts = <_Text>[];
      void flush() {
        if (currentPersist == null) return;
        slides.add(
          _slide(
            slides.length,
            currentPersist,
            texts,
            width,
            height,
            notesById,
          ),
        );
      }

      int? textType;
      for (final c in children(slideList)) {
        switch (c.type) {
          case 0x03F3:
            flush();
            currentPersist = u32(c.offset);
            texts = <_Text>[];
          case 0x0F9F:
            textType = u32(c.offset);
          case 0x0FA0:
            texts.add(
              _Text(
                textType ?? 4,
                decodeUtf16le(Uint8List.sublistView(s, c.offset, c.end)),
              ),
            );
          case 0x0FA8:
            texts.add(
              _Text(
                textType ?? 4,
                decodeCp1252(Uint8List.sublistView(s, c.offset, c.end)),
              ),
            );
        }
      }
      flush();
    }
    if (slides.isEmpty) {
      // No persist info: scan for slide containers.
      var o = 0;
      while (o + 8 <= s.length) {
        final r = rec(o);
        if (r == null) break;
        if (r.type == 0x03EE) {
          slides.add(
            _slideFromContainer(slides.length, r, const [], width, height, ''),
          );
        }
        o = r.isContainer && r.type != 0x03EE ? r.offset : r.end;
      }
    }
    return SlideDeck(
      format: 'ppt',
      width: width,
      height: height,
      slides: slides,
      images: images,
    );
  }

  _Rec? _readPersist(int editOffset) {
    final edits = <int>[];
    var o = editOffset;
    final seen = <int>{};
    int? docRef;
    while (o > 0 && o + 8 < s.length && seen.add(o)) {
      final r = rec(o);
      if (r == null || r.type != 0x0FF5) break;
      edits.add(o);
      // UserEditAtom: lastSlideIdRef, version, offsetLastEdit,
      // offsetPersistDirectory, docPersistIdRef (+16), persistIdSeed (+20).
      docRef ??= u32(r.offset + 16);
      o = u32(r.offset + 8);
    }
    for (final e in edits.reversed) {
      final r = rec(e)!;
      final dirOff = u32(r.offset + 12);
      final dir = rec(dirOff);
      if (dir == null || dir.type != 0x1772) continue;
      var p = dir.offset;
      while (p + 4 <= dir.end) {
        final v = u32(p);
        final id = v & 0xFFFFF;
        final count = v >> 20;
        p += 4;
        for (var k = 0; k < count && p + 4 <= dir.end; k++) {
          persist[id + k] = u32(p);
          p += 4;
        }
      }
    }
    if (docRef == null) return null;
    final off = persist[docRef];
    if (off == null) return null;
    final r = rec(off);
    return r != null && r.type == 0x03E8 ? r : null;
  }

  void _readBStore(_Rec docRec) {
    final group = child(docRec, 0x040B);
    if (group == null) return;
    final dgg = child(group, 0xF000);
    final store = dgg == null ? null : child(dgg, 0xF001);
    if (store == null) return;
    for (final fbse in children(store)) {
      if (fbse.type != 0xF007) {
        blipOffsets.add(-1);
        blipEmbedded.add(null);
        continue;
      }
      final size = u32(fbse.offset + 20);
      final foDelay = u32(fbse.offset + 28);
      final cbName = s[fbse.offset + 33];
      final blipStart = fbse.offset + 36 + cbName;
      if (fbse.length > 36 + cbName + 8) {
        blipOffsets.add(-1);
        blipEmbedded.add(_blipData(s, blipStart));
      } else {
        blipOffsets.add(size > 0 ? foDelay : -1);
        blipEmbedded.add(null);
      }
    }
  }

  /// Image bytes from a BLIP record at [o] in [data].
  Uint8List? _blipData(Uint8List data, int o) {
    if (o + 8 > data.length) return null;
    final b = ByteData.sublistView(data);
    final inst = b.getUint16(o, Endian.little) >> 4;
    final type = b.getUint16(o + 2, Endian.little);
    final len = b.getUint32(o + 4, Endian.little);
    final body = o + 8;
    if (body + len > data.length) return null;
    int header;
    switch (type) {
      case 0xF01D:
      case 0xF02A:
        header = (inst == 0x46B || inst == 0x6E3) ? 33 : 17;
      case 0xF01E:
        header = inst == 0x6E1 ? 33 : 17;
      case 0xF01F:
        header = inst == 0x7A9 ? 33 : 17;
      case 0xF029:
        header = inst == 0x6E5 ? 33 : 17;
      default:
        return null; // EMF/WMF/PICT aren't displayable.
    }
    if (header >= len) return null;
    var bytes = Uint8List.fromList(
      Uint8List.sublistView(data, body + header, body + len),
    );
    if (type == 0xF01F) {
      // DIB: add a BMP file header.
      final h = ByteData(14)
        ..setUint8(0, 0x42)
        ..setUint8(1, 0x4D)
        ..setUint32(2, 14 + bytes.length, Endian.little);
      final bb = ByteData.sublistView(bytes);
      final infoSize = bytes.length >= 4 ? bb.getUint32(0, Endian.little) : 40;
      final bits = bytes.length >= 16 ? bb.getUint16(14, Endian.little) : 24;
      var colors = bytes.length >= 36 ? bb.getUint32(32, Endian.little) : 0;
      if (colors == 0 && bits <= 8) colors = 1 << bits;
      h.setUint32(10, 14 + infoSize + colors * 4, Endian.little);
      bytes = Uint8List.fromList([...h.buffer.asUint8List(), ...bytes]);
    }
    return bytes;
  }

  String? _image(int pib) {
    final idx = pib - 1;
    if (idx < 0 || idx >= blipOffsets.length) return null;
    final key = 'ppt_blip_$pib';
    if (images.containsKey(key)) return key;
    Uint8List? data = blipEmbedded[idx];
    final off = blipOffsets[idx];
    if (data == null && off >= 0 && pictures != null) {
      data = _blipData(pictures!, off);
    }
    if (data == null) return null;
    final ext = sniffImageExtension(data) ?? 'png';
    images[key] = SlideImageData(data, ext);
    return key;
  }

  Slide _slide(
    int index,
    int persistId,
    List<_Text> texts,
    double w,
    double h,
    Map<int, int> notesById,
  ) {
    final off = persist[persistId];
    final r = off == null ? null : rec(off);
    var notes = '';
    if (r != null && r.type == 0x03EE) {
      final atom = child(r, 0x03EF);
      if (atom != null) {
        final notesId = u32(atom.offset + 16);
        final np = notesById[notesId];
        final noff = np == null ? null : persist[np];
        final nrec = noff == null ? null : rec(noff);
        if (nrec != null && nrec.type == 0x03F0) notes = _notesText(nrec);
      }
      return _slideFromContainer(index, r, texts, w, h, notes);
    }
    // No container: lay out the texts in a simple column.
    return _textOnlySlide(index, texts, w, h, notes);
  }

  String _notesText(_Rec notes) {
    final parts = <String>[];
    int? type;
    for (final box in descendants(notes, 0xF00D)) {
      for (final c in children(box)) {
        if (c.type == 0x0F9F) type = u32(c.offset);
        if (c.type == 0x0FA0 && type == 2) {
          parts.add(decodeUtf16le(Uint8List.sublistView(s, c.offset, c.end)));
        }
        if (c.type == 0x0FA8 && type == 2) {
          parts.add(decodeCp1252(Uint8List.sublistView(s, c.offset, c.end)));
        }
      }
    }
    return parts.join('\n').replaceAll('\r', '\n').trim();
  }

  Slide _slideFromContainer(
    int index,
    _Rec slide,
    List<_Text> texts,
    double w,
    double h,
    String notes,
  ) {
    final shapes = <SlideShape>[];
    final drawing = child(slide, 0x040C);
    var usedTexts = 0;
    if (drawing != null) {
      for (final sp in descendants(drawing, 0xF004)) {
        SlideRect? frame;
        int? pib;
        String? text;
        var textType = 4;
        int? fillColor;
        var filled = false;
        for (final c in children(sp)) {
          switch (c.type) {
            case 0xF010:
              if (c.length >= 16) {
                final top = i32(c.offset), left = i32(c.offset + 4);
                final right = i32(c.offset + 8), bottom = i32(c.offset + 12);
                frame = SlideRect(
                  left / 8,
                  top / 8,
                  (right - left) / 8,
                  (bottom - top) / 8,
                );
              } else if (c.length >= 8) {
                final top = i16(c.offset), left = i16(c.offset + 2);
                final right = i16(c.offset + 4), bottom = i16(c.offset + 6);
                frame = SlideRect(
                  left / 8,
                  top / 8,
                  (right - left) / 8,
                  (bottom - top) / 8,
                );
              }
            case 0xF00B:
              final count = c.instance;
              var p = c.offset;
              for (var k = 0; k < count && p + 6 <= c.end; k++) {
                final opid = u16(p) & 0x3FFF;
                final op = u32(p + 2);
                if (opid == 0x0104) pib = op;
                if (opid == 0x0181) fillColor = op;
                if (opid == 0x01BF) filled = (op & 0x10) != 0;
                p += 6;
              }
            case 0xF00D:
              for (final t in children(c)) {
                if (t.type == 0x0F9F) textType = u32(t.offset);
                if (t.type == 0x0FA0) {
                  text = decodeUtf16le(
                    Uint8List.sublistView(s, t.offset, t.end),
                  );
                }
                if (t.type == 0x0FA8) {
                  text = decodeCp1252(
                    Uint8List.sublistView(s, t.offset, t.end),
                  );
                }
                if (t.type == 0x0F9E) {
                  final idx = u32(t.offset);
                  if (idx < texts.length) {
                    text = texts[idx].text;
                    textType = texts[idx].type;
                    usedTexts++;
                  }
                }
              }
            case 0xF011:
              for (final t in descendants(c, 0x0F9E)) {
                final idx = u32(t.offset);
                if (idx < texts.length && text == null) {
                  text = texts[idx].text;
                  textType = texts[idx].type;
                  usedTexts++;
                }
              }
          }
        }
        if (frame == null || frame.w <= 0 || frame.h <= 0) continue;
        if (pib != null && pib > 0) {
          final id = _image(pib);
          if (id != null) {
            shapes.add(SlidePicture(frame: frame, imageId: id));
            continue;
          }
        }
        SlideFill? fill;
        if (filled && fillColor != null && (fillColor >> 24) == 0) {
          // COLORREF: 0x00BBGGRR.
          final r = fillColor & 0xFF,
              g = (fillColor >> 8) & 0xFF,
              b = (fillColor >> 16) & 0xFF;
          fill = SlideFill(color: 0xFF000000 | (r << 16) | (g << 8) | b);
        }
        if (text == null && fill == null) continue;
        shapes.add(
          SlideAutoShape(
            frame: frame,
            fill: fill,
            text: text == null ? null : _body(text, textType, frame),
            placeholder: textType == 0 || textType == 6
                ? 'title'
                : (textType == 1 || textType == 5 ? 'body' : null),
          ),
        );
      }
    }
    if (shapes.isEmpty && texts.isNotEmpty && usedTexts == 0) {
      return _textOnlySlide(index, texts, w, h, notes);
    }
    return Slide(
      index: index,
      shapes: shapes,
      notes: notes,
      background: const SlideFill(color: 0xFFFFFFFF),
    );
  }

  Slide _textOnlySlide(
    int index,
    List<_Text> texts,
    double w,
    double h,
    String notes,
  ) {
    final shapes = <SlideShape>[];
    var y = h * 0.08;
    for (final t in texts) {
      final title = t.type == 0 || t.type == 6;
      final boxH = title ? h * 0.18 : h * 0.6;
      final frame = SlideRect(w * 0.07, y, w * 0.86, boxH);
      shapes.add(
        SlideAutoShape(
          frame: frame,
          text: _body(t.text, t.type, frame),
          placeholder: title ? 'title' : 'body',
        ),
      );
      y += boxH + h * 0.04;
      if (y > h) break;
    }
    return Slide(
      index: index,
      shapes: shapes,
      notes: notes,
      background: const SlideFill(color: 0xFFFFFFFF),
    );
  }

  SlideTextBody _body(String text, int type, SlideRect frame) {
    final title = type == 0 || type == 6;
    final body = type == 1 || type == 5 || type == 7 || type == 8;
    final paras = text.replaceAll('\r\n', '\r').split('\r');
    var size = title ? 40.0 : (body ? 26.0 : 18.0);
    // Shrink until the text roughly fits its box.
    double estimate(double sz) {
      var lines = 0.0;
      for (final p in paras) {
        final width = p.length * sz * 0.5;
        lines += math.max(1, (width / math.max(20, frame.w - 14)).ceil());
      }
      return lines * sz * 1.25 + 8;
    }

    while (size > 10 && estimate(size) > frame.h * 1.05) {
      size -= 1;
    }
    return SlideTextBody(
      anchor: title ? 'ctr' : 't',
      paragraphs: [
        for (final p in paras)
          SlideParagraph(
            align: title || type == 5 ? SlideAlign.center : SlideAlign.left,
            bulletLabel: body && type != 5 && p.trim().isNotEmpty ? '•' : null,
            marginLeft: body && type != 5 ? size * 1.2 : 0,
            indent: body && type != 5 ? -size * 1.0 : 0,
            spaceBefore: body ? size * 0.2 : 0,
            endSize: size,
            runs: [
              SlideRun(
                text: p.replaceAll('\u000B', '\n'),
                size: size,
                bold: title,
                color: 0xFF000000,
              ),
            ],
          ),
      ],
    );
  }
}
