import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:folders/core/services/search/file_search.dart';
import 'package:folders/core/services/search/photo_text_index.dart';
import 'package:folders/core/services/search/smart_query.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The search itself: an isolate going through real folders, with PDFs and
/// photos read back on this side (a fake PDF reader and a fake OCR here).
void main() {
  late Directory root;
  final now = DateTime(2026, 11, 13, 10);
  final realReadPdf = FileSearch.readPdf;
  final realCap = FileSearch.photoReadCap;

  setUp(() async => root = await Directory.systemTemp.createTemp('file_search_test'));
  tearDown(() async {
    FileSearch.readPdf = realReadPdf;
    FileSearch.photoReadCap = realCap;
    await root.delete(recursive: true);
  });

  String at(String relative) => p.joinAll([root.path, ...relative.split('/')]);

  Future<File> file(String relative, {List<int>? bytes, String? text, DateTime? modified}) async {
    final f = File(at(relative));
    await f.create(recursive: true);
    await f.writeAsBytes(bytes ?? utf8.encode(text ?? 'x'));
    if (modified != null) await f.setLastModified(modified);
    return f;
  }

  String rel(String path) => p.relative(path, from: root.path).replaceAll(r'\', '/');

  /// Everything a search finds, and its last progress.
  Future<(Map<String, SearchHit>, SearchProgress)> run(SearchSpec spec, {PhotoTextIndex? photos}) async {
    final hits = <String, SearchHit>{};
    var progress = const SearchProgress();
    await for (final update in FileSearch.run(spec, photos: photos)) {
      for (final hit in update.hits) {
        hits[rel(hit.path)] = hit;
      }
      progress = update.progress;
    }
    return (hits, progress);
  }

  SearchSpec spec(
    String query, {
    bool smart = true,
    bool inside = false,
    bool photoText = false,
    bool showHidden = false,
    int limit = 2000,
    Map<SearchPlace, List<String>> placeFolders = const {},
  }) =>
      SearchSpec(
        query: query,
        roots: [root.path],
        smart: smart ? SmartQuery.parse(query, now: now) : null,
        insideFiles: inside,
        photoText: photoText,
        showHidden: showHidden,
        limit: limit,
        placeFolders: placeFolders,
      );

  test('names in this folder and the ones inside, hidden ones only when shown', () async {
    await file('budget.txt');
    await file('Work/2026/budget-final.md');
    await file('Work/.secret/budget.tmp');
    await file('Work/other.txt');
    final (hits, progress) = await run(spec('budget'));
    expect(hits.keys, unorderedEquals(['budget.txt', 'Work/2026/budget-final.md']));
    expect(progress.busy, isFalse);
    expect(progress.checked, greaterThanOrEqualTo(5));
    final (shown, _) = await run(spec('budget', showHidden: true));
    expect(shown.keys, contains('Work/.secret/budget.tmp'));
  });

  test('inside files: text, Office and code, with the words in context', () async {
    await file('notes/minutes.txt', text: 'We agreed the quarterly BUDGET today.');
    final archive = Archive();
    final xml = utf8.encode('<w:document><w:p><w:r><w:t>The budget is approved</w:t></w:r></w:p></w:document>');
    archive.addFile(ArchiveFile('word/document.xml', xml.length, xml));
    await file('notes/letter.docx', bytes: ZipEncoder().encode(archive)!);
    await file('notes/unrelated.txt', text: 'Nothing to see here');
    await file('notes/photo.jpg', bytes: [0xFF, 0xD8, 0xFF, 0, 0, 0]);

    final (byName, _) = await run(spec('budget'));
    expect(byName, isEmpty, reason: 'no name has the word');

    final (hits, _) = await run(spec('budget', inside: true));
    expect(hits.keys, unorderedEquals(['notes/minutes.txt', 'notes/letter.docx']));
    final snippet = hits['notes/minutes.txt']!.snippet!;
    expect(snippet.text, contains('quarterly BUDGET today'));
    final (start, end) = snippet.highlights.single;
    expect(snippet.text.substring(start, end), 'BUDGET');
  });

  test('inside files without Smart search looks for the whole phrase', () async {
    await file('a.txt', text: 'the annual report is late');
    await file('b.txt', text: 'report: annual');
    final (hits, _) = await run(spec('annual report', smart: false, inside: true));
    expect(hits.keys, ['a.txt']);
  });

  test('PDFs are read on this side', () async {
    await file('scans/invoice.pdf', text: '%PDF-1.4');
    await file('scans/manual.pdf', text: '%PDF-1.4');
    final read = <String>[];
    FileSearch.readPdf = (path) async {
      read.add(p.basename(path));
      return p.basename(path) == 'invoice.pdf' ? 'Invoice 42\nTotal due: 99 EUR' : 'How to set up the printer';
    };
    final (hits, progress) = await run(spec('total due', inside: true));
    expect(hits.keys, ['scans/invoice.pdf']);
    expect(hits['scans/invoice.pdf']!.snippet!.text, contains('Total due'));
    expect(read, unorderedEquals(['invoice.pdf', 'manual.pdf']));
    expect(progress.pdfs, 0);
    final (none, _) = await run(spec('total due'));
    expect(none, isEmpty, reason: 'not read unless asked');
  });

  test('kinds, dates and sizes', () async {
    await file('Camera/beach.jpg', modified: DateTime(2026, 11, 4, 12));
    await file('Camera/old.jpg', modified: DateTime(2025, 6, 1));
    await file('Camera/clip.mp4', modified: DateTime(2026, 11, 4, 12));
    await file('Docs/big.pdf', bytes: List.filled(3 << 20, 1));
    await file('Docs/small.pdf', bytes: List.filled(100, 1));
    await file('Docs/march-report.pdf', modified: DateTime(2026, 10, 1));
    await file('Docs/plan.pdf', modified: DateTime(2026, 3, 10));

    final (week, _) = await run(spec('photos from last week'));
    expect(week.keys, ['Camera/beach.jpg']);

    final (big, _) = await run(spec('pdf bigger than 2 MB'));
    expect(big.keys, ['Docs/big.pdf']);

    final (march, _) = await run(spec('march'));
    expect(march.keys, unorderedEquals(['Docs/plan.pdf', 'Docs/march-report.pdf']),
        reason: 'changed in March, or "march" in the name');

    final (folders, _) = await run(spec('2026'));
    expect(folders.keys, isNot(contains('Camera')), reason: 'folders are no kind of file and have no year');
  });

  test('places: only what is in them', () async {
    await file('Downloads/setup.exe');
    await file('Downloads/Work/notes.txt');
    await file('Documents/notes.txt');
    final (hits, _) = await run(spec('downloads', placeFolders: {SearchPlace.downloads: [at('Downloads')]}));
    expect(hits.keys,
        unorderedEquals(['Downloads', 'Downloads/setup.exe', 'Downloads/Work', 'Downloads/Work/notes.txt']),
        reason: 'the folder by its name, and all that is in it');
    final (apps, _) = await run(spec('apps in downloads', placeFolders: {SearchPlace.downloads: [at('Downloads')]}));
    expect(apps.keys, ['Downloads/setup.exe']);
  });

  test("photos' text through the index, read once, at most so many per search", () async {
    await file('Receipts/shop.jpg', modified: DateTime(2026, 3, 5));
    await file('Receipts/cafe.png', modified: DateTime(2026, 3, 20));
    await file('Receipts/cat.jpg', modified: DateTime(2026, 3, 21));
    await file('Receipts/april.jpg', modified: DateTime(2026, 4, 2));
    final texts = {
      'shop.jpg': 'SUPERMARKET\nRECEIPT\nTotal 12.40',
      'cafe.png': 'Café Nero receipt no. 7',
      'cat.jpg': '',
      'april.jpg': 'Receipt April',
    };
    final read = <String>[];
    final photos = PhotoTextIndex(
      folder: () async => at('.index'),
      ocr: (path) async {
        read.add(p.basename(path));
        return texts[p.basename(path)];
      },
    );
    FileSearch.photoReadCap = 2;
    final (first, progress) = await run(spec('receipts from march', photoText: true), photos: photos);
    expect(read, hasLength(2), reason: 'two photos per search');
    expect(read, isNot(contains('april.jpg')), reason: 'only photos from March');
    expect(progress.photosLeftOut, 1);
    expect(first, isNotEmpty);

    final (second, again) = await run(spec('receipts from march', photoText: true), photos: photos);
    expect(read, hasLength(3), reason: 'the photos read before are known');
    expect(again.photosLeftOut, 0);
    expect(second.keys, unorderedEquals(['Receipts/shop.jpg', 'Receipts/cafe.png']));
    expect(second['Receipts/shop.jpg']!.snippet!.text, contains('RECEIPT'));
    await photos.save();
    expect(File(at('.index/photo_text.json')).existsSync(), isTrue, reason: 'kept on disk');
  });

  test('stops at the limit', () async {
    for (var i = 0; i < 30; i++) {
      await file('many/note $i.txt');
    }
    final (hits, progress) = await run(spec('note', limit: 10));
    expect(hits, hasLength(10));
    expect(progress.busy, isFalse);
  });

  test('cancelling stops it', () async {
    for (var i = 0; i < 20; i++) {
      await file('deep/$i/a.txt', text: 'needle');
    }
    final completer = Completer<void>();
    late StreamSubscription<SearchUpdate> subscription;
    var updates = 0;
    subscription = FileSearch.run(spec('needle', inside: true)).listen((_) {
      updates++;
      subscription.cancel();
      completer.complete();
    });
    await completer.future;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(updates, 1);
  });

  test('a category: its files only, never walked', () async {
    final listed = await file('Video/a.mp4', modified: DateTime(2026, 11, 12));
    await file('Video/b.mp4', modified: DateTime(2024, 1, 1));
    await file('Video/sub/c.mp4', modified: DateTime(2026, 11, 12));
    final (hits, _) = await run(SearchSpec(
      query: 'yesterday',
      files: [listed.path, at('Video/b.mp4')],
      smart: SmartQuery.parse('yesterday', now: now),
    ));
    expect(hits.keys, ['Video/a.mp4']);
  });
}
