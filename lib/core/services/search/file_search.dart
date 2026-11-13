import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/services/search/pdf_text.dart';
import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:folders/core/services/search/search_criteria.dart';
import 'package:folders/core/services/search/smart_query.dart';
import 'package:folders/core/services/search/text_extract.dart';
import 'package:path/path.dart' as p;

/// What to search and where.
class SearchSpec {
  const SearchSpec({
    required this.query,
    this.roots = const [],
    this.files = const [],
    this.rootItems = true,
    this.smart,
    this.insideFiles = false,
    this.photoText = false,
    this.showHidden = false,
    this.limit = 2000,
    this.placeFolders = const {},
  });

  /// As typed.
  final String query;

  /// Folders searched with everything inside them, nearest items first...
  final List<String> roots;

  /// ...and files looked at on their own (a category's).
  final List<String> files;

  /// Whether the roots' own items are looked at too, or only what's in
  /// their subfolders.
  final bool rootItems;

  /// What the query means in plain words; null with Smart search off.
  final SmartQuery? smart;

  /// Whether the words are looked for inside files, and in photos' text.
  final bool insideFiles;
  final bool photoText;

  final bool showHidden;

  /// Stops after this many.
  final int limit;

  /// Each place's folders on this device.
  final Map<SearchPlace, List<String>> placeFolders;

  SearchCriteria get criteria => SearchCriteria(
        query,
        smart: smart,
        insideFiles: insideFiles,
        photoText: photoText,
        placeFolders: placeFolders,
      );
}

/// A file or folder found, with its words in context when they were found
/// inside it.
class SearchHit {
  const SearchHit(this.path, {this.isDirectory = false, this.snippet});

  final String path;
  final bool isDirectory;
  final SearchSnippet? snippet;

  FileSystemEntity get entity => isDirectory ? Directory(path) : File(path);

  @override
  String toString() => 'SearchHit($path${snippet == null ? '' : ', $snippet'})';
}

/// How far a search has got.
class SearchProgress {
  const SearchProgress({
    this.checked = 0,
    this.walking = false,
    this.pdfs = 0,
    this.photos = 0,
    this.photosLeftOut = 0,
  });

  /// Files and folders looked at.
  final int checked;

  /// Still going through folders.
  final bool walking;

  /// PDFs still to read, and photos whose text is still to be read.
  final int pdfs;
  final int photos;

  /// Photos not read this time, past [FileSearch.photoReadCap]: the next
  /// search reads them.
  final int photosLeftOut;

  bool get busy => walking || pdfs > 0 || photos > 0;

  /// The same, finished.
  SearchProgress get done => SearchProgress(checked: checked, photosLeftOut: photosLeftOut);

  @override
  String toString() => 'SearchProgress(checked: $checked, walking: $walking, pdfs: $pdfs, photos: $photos, '
      'left out: $photosLeftOut)';
}

/// What a search found since the last update, and how far it's got.
class SearchUpdate {
  const SearchUpdate(this.hits, this.progress);

  final List<SearchHit> hits;
  final SearchProgress progress;
}

/// Searches folders in an isolate: names, and with [SearchSpec.insideFiles]
/// the text inside files. PDFs and photos come back to this isolate, as
/// PDFium and the system's text recognition can't be used from another.
abstract final class FileSearch {
  /// Reads PDFs' text; tests replace it.
  static PdfTextReader readPdf = PdfText.read;

  /// Photos read at most per search; the index keeps them, so the next
  /// search goes on with the rest.
  static int photoReadCap = 200;

  /// Runs [spec]. Cancelling the stream stops it at once. [photos] reads and
  /// keeps photos' text (with [SearchSpec.photoText]).
  static Stream<SearchUpdate> run(SearchSpec spec, {PhotoTextIndex? photos}) {
    final criteria = spec.criteria;
    final port = ReceivePort();
    Isolate? isolate;
    var cancelled = false;
    var walking = true;
    var checked = 0;
    var found = 0;
    var newPhotos = 0;
    var photosLeftOut = 0;
    final pdfQueue = <String>[];
    final photoQueue = <(String, int, int)>[];
    var readingPdf = false;
    var readingPhoto = false;
    late final StreamController<SearchUpdate> controller;

    SearchProgress progress() => SearchProgress(
          checked: checked,
          walking: walking,
          pdfs: pdfQueue.length + (readingPdf ? 1 : 0),
          photos: photoQueue.length + (readingPhoto ? 1 : 0),
          photosLeftOut: photosLeftOut,
        );

    void send([List<SearchHit> hits = const []]) {
      if (!cancelled && !controller.isClosed) controller.add(SearchUpdate(hits, progress()));
    }

    void stopWalking() {
      isolate?.kill(priority: Isolate.immediate);
      port.close();
      walking = false;
    }

    void finishIfDone() {
      if (cancelled || controller.isClosed) return;
      if (found >= spec.limit) {
        stopWalking();
        pdfQueue.clear();
        photoQueue.clear();
      }
      if (walking || readingPdf || readingPhoto || pdfQueue.isNotEmpty || photoQueue.isNotEmpty) return;
      unawaited(photos?.save());
      send();
      controller.close();
    }

    SearchHit? matchText(String path, String? text) {
      if (text == null) return null;
      final snippet = criteria.matchText(path, text);
      return snippet == null ? null : SearchHit(path, snippet: snippet);
    }

    Future<void> readPdfs() async {
      if (readingPdf) return;
      readingPdf = true;
      while (pdfQueue.isNotEmpty && !cancelled && found < spec.limit) {
        final path = pdfQueue.removeAt(0);
        send();
        String? text;
        try {
          text = await readPdf(path);
        } catch (_) {
          text = null;
        }
        if (cancelled) return;
        final hit = matchText(path, text);
        if (hit != null) {
          found++;
          send([hit]);
        }
      }
      readingPdf = false;
      send();
      finishIfDone();
    }

    Future<void> readPhotos() async {
      final index = photos;
      if (readingPhoto || index == null) return;
      readingPhoto = true;
      while (photoQueue.isNotEmpty && !cancelled && found < spec.limit) {
        final (path, size, modified) = photoQueue.removeAt(0);
        send();
        final text = await index.read(path, size, modified);
        if (cancelled) return;
        final hit = matchText(path, text);
        if (hit != null) {
          found++;
          send([hit]);
        }
      }
      readingPhoto = false;
      send();
      finishIfDone();
    }

    void onPhotos(List<(String, int, int)> batch) {
      final index = photos;
      if (index == null) return;
      final hits = <SearchHit>[];
      for (final photo in batch) {
        final (path, size, modified) = photo;
        final known = index.known(path, size, modified);
        if (known != null) {
          final hit = matchText(path, known);
          if (hit != null) {
            hits.add(hit);
            found++;
          }
        } else if (newPhotos < photoReadCap) {
          newPhotos++;
          photoQueue.add(photo);
        } else {
          photosLeftOut++;
        }
      }
      send(hits);
      unawaited(readPhotos());
    }

    controller = StreamController<SearchUpdate>(
      onListen: () async {
        if (spec.photoText) await photos?.load();
        if (cancelled) return;
        isolate = await Isolate.spawn(_walk, (port.sendPort, spec));
        if (cancelled) {
          isolate?.kill(priority: Isolate.immediate);
          return;
        }
        port.listen((message) {
          if (cancelled) return;
          switch (message) {
            case null:
              port.close();
              walking = false;
              send();
              finishIfDone();
            case (int count, List<SearchHit> hits, List<String> pdfs, List<(String, int, int)> photoBatch):
              checked = count;
              found += hits.length;
              pdfQueue.addAll(pdfs);
              send(hits);
              if (photoBatch.isNotEmpty) onPhotos(photoBatch);
              if (pdfs.isNotEmpty) unawaited(readPdfs());
              if (found >= spec.limit) finishIfDone();
          }
        });
      },
      onCancel: () {
        cancelled = true;
        isolate?.kill(priority: Isolate.immediate);
        port.close();
        unawaited(photos?.save());
      },
    );
    return controller.stream;
  }

  /// Goes through [SearchSpec]'s folders, breadth first, in its own isolate.
  /// Sends (files looked at, hits, PDFs to read, photos to read) about every
  /// 150 ms, then null.
  static void _walk((SendPort, SearchSpec) message) {
    final (port, spec) = message;
    final criteria = spec.criteria;
    // Goes by the name: no extra I/O per folder.
    final skipPackages = Platform.isMacOS;
    var hits = <SearchHit>[];
    var pdfs = <String>[];
    var photos = <(String, int, int)>[];
    var checked = 0;
    var found = 0;
    final clock = Stopwatch()..start();

    void flush({bool force = false}) {
      if (!force && clock.elapsedMilliseconds < 150) return;
      port.send((checked, hits, pdfs, photos));
      hits = [];
      pdfs = [];
      photos = [];
      clock.reset();
    }

    void hit(String path, bool isDirectory, [SearchSnippet? snippet]) {
      hits.add(SearchHit(path, isDirectory: isDirectory, snippet: snippet));
      found++;
    }

    void check(String path, bool isDirectory) {
      checked++;
      final name = p.basename(path);
      if (criteria.literal(name)) return hit(path, isDirectory);
      if (!criteria.beyondNames || !criteria.passesName(path, isDirectory: isDirectory)) return;
      final format = isDirectory ? null : TextExtract.formatOf(path);
      final photo = !isDirectory && spec.photoText && PhotoTextIndex.canRead(path);
      var size = 0;
      var modified = DateTime(0);
      if (criteria.needsStat || (spec.insideFiles && format != null) || photo) {
        final stat = FileStat.statSync(path);
        if (stat.type == FileSystemEntityType.notFound) return;
        size = stat.size;
        modified = stat.modified;
        if (!criteria.passesStat(size: size, modified: modified)) return;
      }
      // Only kinds, dates, sizes or places were asked for.
      if (criteria.words.isEmpty) return hit(path, isDirectory);
      if (criteria.wordsIn(name.toLowerCase())) return hit(path, isDirectory);
      if (isDirectory) return;
      if (spec.insideFiles && format != null) {
        if (format == ContentFormat.pdf) {
          if (size <= TextExtract.maxPdfBytes) pdfs.add(path);
          return;
        }
        final text = TextExtract.read(path, format, size: size);
        final snippet = text == null ? null : criteria.matchText(path, text);
        if (snippet != null) return hit(path, false, snippet);
      }
      if (photo && size <= PhotoTextIndex.maxPhotoBytes) {
        photos.add((path, size, modified.millisecondsSinceEpoch));
      }
    }

    bool hidden(String path) => !spec.showHidden && LocalFileRepository.isHidden(path);
    bool searchInside(String path) => !(skipPackages && FileTypes.isMacPackage(path));

    for (final path in spec.files) {
      if (found >= spec.limit) break;
      check(path, false);
      flush();
    }
    final pending = <String>[];
    for (final root in spec.roots) {
      if (spec.rootItems) {
        pending.add(root);
        continue;
      }
      try {
        for (final entity in Directory(root).listSync(followLinks: false)) {
          if (entity is Directory && searchInside(entity.path) && !hidden(entity.path)) pending.add(entity.path);
        }
      } on FileSystemException {
        // Unreadable root: nothing to search.
      }
    }
    for (var i = 0; i < pending.length && found < spec.limit; i++) {
      final List<FileSystemEntity> children;
      try {
        children = Directory(pending[i]).listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in children) {
        if (hidden(entity.path)) continue;
        final isDirectory = entity is Directory;
        if (isDirectory && searchInside(entity.path)) pending.add(entity.path);
        check(entity.path, isDirectory);
        if (found >= spec.limit) break;
        flush();
      }
    }
    flush(force: true);
    port.send(null);
  }
}
