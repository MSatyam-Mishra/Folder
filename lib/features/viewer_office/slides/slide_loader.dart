import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:folders/core/formats/cfb_reader.dart';
import 'package:image/image.dart' as img;

import '../common/office_package.dart';
import 'odp_parser.dart';
import 'ppt_parser.dart';
import 'pptx_parser.dart';
import 'slide_model.dart';
import 'zip_reader.dart';

export 'ppt_parser.dart' show PresentationEncryptedException;

/// Parses any supported presentation, sniffing the real format from its
/// bytes. Pure Dart; call through `Isolate.run`.
SlideDeck parseAnyPresentation(Uint8List bytes, String extension) {
  if (bytes.isEmpty) throw const FormatException('The file is empty.');
  if (OfficePackage.isZip(bytes)) {
    final pkg = OfficePackage.decode(bytes);
    final mime = pkg.text('mimetype')?.trim() ?? '';
    if (mime.contains('opendocument') ||
        (pkg.has('content.xml') && !pkg.has('[Content_Types].xml'))) {
      return parseOdpBytes(bytes);
    }
    return PptxParser(pkg).parse();
  }
  if (CfbReader.isCfb(bytes)) {
    final cfb = CfbReader(bytes);
    if (cfb.find('EncryptedPackage') != null) {
      throw const PresentationEncryptedException();
    }
    return parsePptBytes(bytes);
  }
  final head = String.fromCharCodes(bytes.take(64)).trimLeft();
  if (head.startsWith('<?xml') || head.startsWith('<office:document')) {
    return parseOdpBytes(bytes);
  }
  throw const FormatException(
    'This file isn\'t a presentation format we can read.',
  );
}

/// Whether [deck] can be edited and saved back (PPTX family only).
bool isEditablePresentation(SlideDeck deck) => deck.format == 'pptx';

// ---------------------------------------------------------------------------
// Reading straight from the file

/// Image part extensions mapped to the type they're shown as. Listed types
/// are referenced instead of read while parsing; TIFF is converted to PNG
/// when loaded.
const _imageExtensions = {
  'png': 'png',
  'jpg': 'jpeg',
  'jpeg': 'jpeg',
  'jpe': 'jpeg',
  'jfif': 'jpeg',
  'gif': 'gif',
  'bmp': 'bmp',
  'webp': 'webp',
  'tif': 'png',
  'tiff': 'png',
  'emf': 'emf',
  'wmf': 'wmf',
  'emz': 'emz',
  'wmz': 'wmz',
  'svg': 'svg',
  'wdp': 'wdp',
  'jxr': 'jxr',
};

/// PPTX parts read from the zip on demand; images become references.
class _ZipParts extends PptxParts {
  _ZipParts(this.zip);
  final LazyZip zip;

  @override
  Uint8List? bytes(String name) => zip.read(name);

  @override
  SlideImageData? imageRef(String name) {
    final e = zip.entry(name);
    if (e == null || e.encrypted || (e.method != 0 && e.method != 8)) {
      return null;
    }
    final dot = name.lastIndexOf('.');
    final ext = _imageExtensions[name.substring(dot + 1).toLowerCase()];
    if (dot < 0 || ext == null) return null;
    return SlideImageData.lazy(
      SlideImageRef(
        path: zip.path,
        entry: name,
        fileLength: zip.length,
        fileModified: zip.modified,
        offset: e.offset,
        compressedSize: e.compressedSize,
        method: e.method,
      ),
      ext,
    );
  }
}

bool _isOpenDocument(LazyZip zip) {
  final mime = zip.has('mimetype')
      ? utf8.decode(zip.read('mimetype') ?? const [], allowMalformed: true)
      : '';
  return mime.contains('opendocument') ||
      (zip.has('content.xml') && !zip.has('[Content_Types].xml'));
}

/// Parses the presentation at [path] in one go. PPTX parts are read
/// straight from the zip and pictures stay references (read when shown);
/// other formats read the whole file. Pure Dart; call through `Isolate.run`.
SlideDeck loadPresentationFile(String path, String extension) {
  final zip = LazyZip.open(path);
  if (zip != null) {
    try {
      if (!_isOpenDocument(zip)) {
        return PptxParser.fromParts(_ZipParts(zip)).parse();
      }
    } finally {
      zip.close();
    }
  }
  return parseAnyPresentation(File(path).readAsBytesSync(), extension);
}

/// Reads the image [ref] points at (TIFF is converted to PNG). When the
/// file was rewritten since it was opened, the entry is found again by
/// name. Pure Dart; call through `Isolate.run`. Throws when unreadable.
Uint8List readSlideImage(SlideImageRef ref) {
  Uint8List? data;
  final file = File(ref.path);
  final stat = file.statSync();
  if (stat.size == ref.fileLength &&
      stat.modified.millisecondsSinceEpoch == ref.fileModified) {
    final f = file.openSync();
    try {
      data = LazyZip.readEntry(
        f,
        ZipEntry(
          name: ref.entry,
          method: ref.method,
          flags: 0,
          compressedSize: ref.compressedSize,
          size: 0,
          offset: ref.offset,
        ),
        checkName: true,
      );
    } finally {
      f.closeSync();
    }
  }
  if (data == null) {
    final zip = LazyZip.open(ref.path);
    try {
      data = zip?.read(ref.entry);
    } finally {
      zip?.close();
    }
  }
  if (data == null) throw StateError('Image ${ref.entry} is missing');
  if (sniffImageExtension(data) == 'tiff') {
    final decoded = img.decodeTiff(data);
    if (decoded == null) throw StateError('Unreadable TIFF ${ref.entry}');
    data = Uint8List.fromList(img.encodePng(decoded));
  }
  return data;
}

// ---------------------------------------------------------------------------
// Progressive loading

sealed class SlideLoadEvent {
  const SlideLoadEvent();
}

/// Slide size and list are known. Every slide of [deck] is still
/// [Slide.pending]; [SlidesParsed] events replace them.
class SlideDeckOpened extends SlideLoadEvent {
  const SlideDeckOpened(this.deck);
  final SlideDeck deck;
}

/// Parsed slides by deck index (without notes) and the images they
/// introduced.
class SlidesParsed extends SlideLoadEvent {
  const SlidesParsed(this.slides, this.images);
  final Map<int, Slide> slides;
  final Map<String, SlideImageData> images;
}

/// Speaker notes by deck index (slides without notes are left out).
class SlideNotesParsed extends SlideLoadEvent {
  const SlideNotesParsed(this.notes);
  final Map<int, String> notes;
}

/// The whole deck at once (PPT, ODP, or a zip the lazy reader can't read).
class SlideDeckParsed extends SlideLoadEvent {
  const SlideDeckParsed(this.deck);
  final SlideDeck deck;
}

class SlideLoadDone extends SlideLoadEvent {
  const SlideLoadDone();
}

class SlideLoadFailed extends SlideLoadEvent {
  const SlideLoadFailed(this.error);

  /// A [FormatException], [PresentationEncryptedException] or a message.
  final Object error;
}

/// Loads a presentation in a background isolate and reports it slide by
/// slide: slide size and count first, then the first slide, then the rest
/// (a slide passed to [prioritize] jumps the queue), then speaker notes.
///
/// Pictures aren't read here: PPTX images arrive as [SlideImageRef]s.
class PresentationLoader {
  PresentationLoader(this.path, this.extension);

  final String path;
  final String extension;

  final StreamController<SlideLoadEvent> _events = StreamController();
  final ReceivePort _port = ReceivePort();
  final List<int> _early = [];
  Isolate? _isolate;
  SendPort? _control;
  bool _done = false;

  Stream<SlideLoadEvent> get events => _events.stream;

  Future<void> start() async {
    _port.listen(_onMessage);
    try {
      _isolate = await Isolate.spawn(
        _loaderMain,
        (_port.sendPort, path, extension),
        onExit: _port.sendPort,
        onError: _port.sendPort,
        debugName: 'presentation-loader',
      );
      if (_done) _isolate?.kill(priority: Isolate.immediate);
    } catch (e) {
      _finish(SlideLoadFailed('$e'));
    }
  }

  /// Parses slide [index] next if it's still pending.
  void prioritize(int index) {
    final c = _control;
    if (c == null) {
      _early.add(index);
    } else {
      c.send(index);
    }
  }

  void dispose() {
    _done = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port.close();
    if (!_events.isClosed) _events.close();
  }

  void _onMessage(Object? m) {
    if (_done) return;
    switch (m) {
      case SendPort p:
        _control = p;
        _early.forEach(p.send);
        _early.clear();
      case SlideLoadDone() || SlideLoadFailed() || SlideDeckParsed():
        _finish(m as SlideLoadEvent);
      case SlideLoadEvent e:
        _events.add(e);
      case List e:
        // Uncaught error in the isolate: [message, stack].
        _finish(SlideLoadFailed(e.isEmpty ? 'Unknown error' : '${e.first}'));
      case null:
        // Exited without finishing (e.g. out of memory).
        _finish(const SlideLoadFailed('The presentation loader stopped.'));
    }
  }

  void _finish(SlideLoadEvent last) {
    if (_done) return;
    _events.add(last);
    dispose();
  }
}

Object _sendable(Object e) =>
    e is FormatException || e is PresentationEncryptedException ? e : '$e';

Future<void> _loaderMain((SendPort, String, String) args) async {
  final (out, path, extension) = args;
  final control = ReceivePort();
  out.send(control.sendPort);
  final wanted = <int>[];
  control.listen((m) {
    if (m is int) wanted.add(m);
  });

  LazyZip? zip;
  try {
    zip = LazyZip.open(path);
    if (zip == null || _isOpenDocument(zip)) {
      zip?.close();
      final deck = parseAnyPresentation(
        File(path).readAsBytesSync(),
        extension,
      );
      Isolate.exit(out, SlideDeckParsed(deck));
    }
    final parser = PptxParser.fromParts(_ZipParts(zip))..open();
    final n = parser.entries.length;
    out.send(
      SlideDeckOpened(
        SlideDeck(
          format: 'pptx',
          width: parser.width,
          height: parser.height,
          slides: [
            for (var i = 0; i < n; i++)
              Slide(
                index: i,
                partName: parser.entries[i].part,
                relId: parser.entries[i].relId,
                slideId: parser.entries[i].slideId,
                pending: true,
              ),
          ],
        ),
      ),
    );

    final pending = List<bool>.filled(n, true);
    final sentImages = <String>{};
    var next = 0;
    for (var left = n; left > 0; left--) {
      var i = -1;
      while (wanted.isNotEmpty && i < 0) {
        final w = wanted.removeLast();
        if (w >= 0 && w < n && pending[w]) i = w;
      }
      wanted.clear();
      if (i < 0) {
        while (!pending[next]) {
          next++;
        }
        i = next;
      }
      pending[i] = false;
      final slide = parser.slideAt(i, notes: false);
      final images = <String, SlideImageData>{
        for (final e in parser.images.entries)
          if (sentImages.add(e.key)) e.key: e.value,
      };
      out.send(SlidesParsed({i: slide}, images));
      // Lets a prioritize() message arrive before the next slide.
      await Future<void>.delayed(Duration.zero);
    }

    final notes = <int, String>{};
    for (var i = 0; i < n; i++) {
      final t = parser.notesAt(i);
      if (t.isNotEmpty) notes[i] = t;
    }
    out.send(SlideNotesParsed(notes));
    zip.close();
    Isolate.exit(out, const SlideLoadDone());
  } catch (e) {
    zip?.close();
    Isolate.exit(out, SlideLoadFailed(_sendable(e)));
  }
}
