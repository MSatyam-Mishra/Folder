import 'package:folders/core/services/search/smart_query.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smart search's reading of plain words, on a fixed clock: Friday 13
/// November 2026, 10:00.
void main() {
  final now = DateTime(2026, 11, 13, 10);
  SmartQuery parse(String text) => SmartQuery.parse(text, now: now);
  List<String> chips(String text) => [for (final c in parse(text).chips) c.label];
  const mb = 1024 * 1024;

  group('kinds', () {
    test('words for kinds of file', () {
      expect(parse('photos').kinds, {SearchKind.photos});
      expect(parse('pictures').kinds, {SearchKind.photos});
      expect(parse('images').kinds, {SearchKind.photos});
      expect(parse('videos').kinds, {SearchKind.videos});
      expect(parse('music').kinds, {SearchKind.music});
      expect(parse('songs').kinds, {SearchKind.music});
      expect(parse('audio').kinds, {SearchKind.music});
      expect(parse('docs').kinds, {SearchKind.documents});
      expect(parse('pdf').kinds, {SearchKind.pdf});
      expect(parse('spreadsheets').kinds, {SearchKind.spreadsheets});
      expect(parse('presentations').kinds, {SearchKind.presentations});
      expect(parse('zip').kinds, {SearchKind.archives});
      expect(parse('apks').kinds, {SearchKind.apps});
      expect(parse('ebooks').kinds, {SearchKind.ebooks});
      expect(parse('source code').kinds, {SearchKind.code});
      expect(parse('Photos and videos').kinds, {SearchKind.photos, SearchKind.videos});
    });

    test('file types by name', () {
      final q = parse('mp3 .docx');
      expect(q.extensions, {'mp3', 'docx'});
      expect(chips('mp3 .docx'), ['MP3', 'DOCX']);
    });

    test('what each kind takes', () {
      expect(SearchKind.photos.matches('a/IMG_1.HEIC'), isTrue);
      expect(SearchKind.photos.matches('a/raw.dng'), isTrue);
      expect(SearchKind.photos.matches('a/clip.mp4'), isFalse);
      expect(SearchKind.documents.matches('a/b.docx'), isTrue);
      expect(SearchKind.documents.matches('a/b.pdf'), isTrue);
      expect(SearchKind.apps.matches('a/b.apk'), isTrue);
      expect(SearchKind.archives.matches('a/b.7z'), isTrue);
      expect(SearchKind.ebooks.matches('a/b.epub'), isTrue);
      expect(SearchKind.code.matches('a/main.dart'), isTrue);
    });
  });

  group('dates', () {
    DateSpan only(String text) => parse(text).dates.single;

    test('today, yesterday, this and last week, month, year', () {
      expect(only('today').from, DateTime(2026, 11, 13));
      expect(only('today').to, DateTime(2026, 11, 14));
      expect(only('yesterday').from, DateTime(2026, 11, 12));
      expect(only('yesterday').to, DateTime(2026, 11, 13));
      // Weeks start on Monday.
      expect(only('this week').from, DateTime(2026, 11, 9));
      expect(only('last week').from, DateTime(2026, 11, 2));
      expect(only('last week').to, DateTime(2026, 11, 9));
      expect(only('this month').from, DateTime(2026, 11));
      expect(only('last month').from, DateTime(2026, 10));
      expect(only('last month').to, DateTime(2026, 11));
      expect(only('this year').from, DateTime(2026));
      expect(only('last year').from, DateTime(2025));
      expect(only('last year').to, DateTime(2026));
    });

    test('last N days, weeks, months', () {
      expect(only('last 7 days').from, DateTime(2026, 11, 7));
      expect(only('last 7 days').to, DateTime(2026, 11, 14));
      expect(only('last 7 days').label, 'Last 7 days');
      expect(only('past 2 weeks').from, DateTime(2026, 10, 31));
      expect(only('last 3 months').from, DateTime(2026, 8, 14));
      expect(only('last 1 day').label, 'Last 1 day');
    });

    test('a month, with or without its year', () {
      expect(only('march').from, DateTime(2026, 3));
      expect(only('march').to, DateTime(2026, 4));
      expect(only('March').label, 'March 2026');
      // In November, December is last year's.
      expect(only('december').from, DateTime(2025, 12));
      expect(only('march 2024').from, DateTime(2024, 3));
      expect(only('march 2024').label, 'March 2024');
      expect(only('in jan').from, DateTime(2026, 1));
      expect(only('sept 2025').from, DateTime(2025, 9));
    });

    test('"may" is a month only after "in", "from"... or before a year', () {
      expect(parse('may').dates, isEmpty);
      expect(parse('may').words, ['may']);
      expect(parse('notes I may need').dates, isEmpty);
      expect(parse('notes I may need').words, ['notes', 'i', 'may', 'need']);
      expect(only('photos in may').from, DateTime(2026, 5));
      expect(only('may 2025').from, DateTime(2025, 5));
      expect(parse('mar').dates, isEmpty, reason: 'short names need the same');
      expect(only('from mar').from, DateTime(2026, 3));
    });

    test('a year, but not a year in a word', () {
      expect(only('2025').from, DateTime(2025));
      expect(only('2025').to, DateTime(2026));
      final report = parse('2025-report');
      expect(report.dates, isEmpty);
      expect(report.words, ['2025-report']);
      expect(parse('1234').dates, isEmpty, reason: 'not a year anyone means');
      expect(parse('2099').dates, isEmpty);
    });

    test('ISO dates and months', () {
      expect(only('2025-03-14').from, DateTime(2025, 3, 14));
      expect(only('2025-03-14').to, DateTime(2025, 3, 15));
      expect(only('2025-03-14').label, '14 March 2025');
      expect(only('2025-03').from, DateTime(2025, 3));
      expect(only('2025-03').to, DateTime(2025, 4));
      expect(parse('2025-13').dates, isEmpty);
    });

    test('before, after, since, until', () {
      expect(only('before 2024').to, DateTime(2024));
      expect(only('before 2024').from, isNull);
      expect(only('before 2024').label, 'Before 2024');
      expect(only('after march 2025').from, DateTime(2025, 4));
      expect(only('after march 2025').label, 'After March 2025');
      expect(only('since 2026-01-15').from, DateTime(2026, 1, 15));
      expect(only('since last week').label, 'Since last week');
      expect(only('until yesterday').to, DateTime(2026, 11, 13));
      expect(only('since may').from, DateTime(2026, 5), reason: '"since" makes may a month');
    });

    test('ago, older and newer than, recent', () {
      expect(only('3 days ago').from, DateTime(2026, 11, 10));
      expect(only('3 days ago').to, DateTime(2026, 11, 11));
      expect(only('2 months ago').from, DateTime(2026, 9));
      expect(only('older than 2 years').to, DateTime(2024, 11, 13));
      expect(only('newer than 30 days').from, DateTime(2026, 10, 14));
      expect(only('recent').from, DateTime(2026, 11, 7));
    });

    test('spans contain what they should', () {
      final week = only('last week');
      expect(week.contains(DateTime(2026, 11, 2)), isTrue);
      expect(week.contains(DateTime(2026, 11, 8, 23, 59)), isTrue);
      expect(week.contains(DateTime(2026, 11, 9)), isFalse);
      expect(week.contains(DateTime(2026, 11, 1, 23)), isFalse);
    });
  });

  group('sizes', () {
    SizeSpan only(String text) => parse(text).sizes.single;

    test('bigger, smaller, at least, up to', () {
      expect(only('bigger than 10 MB').min, 10 * mb + 1);
      expect(only('bigger than 10 MB').label, 'Over 10 MB');
      expect(only('over 10mb').min, 10 * mb + 1);
      expect(only('larger than 1 GB').min, 1024 * mb + 1);
      expect(only('smaller than 500 KB').max, 500 * 1024 - 1);
      expect(only('under 500kb').label, 'Under 500 KB');
      expect(only('at least 2 MB').min, 2 * mb);
      expect(only('up to 2 MB').max, 2 * mb);
      expect(only('at most 3 gb').max, 3 * 1024 * mb);
    });

    test('symbols', () {
      expect(only('>10mb').min, 10 * mb + 1);
      expect(only('> 10 mb').min, 10 * mb + 1);
      expect(only('<1gb').max, 1024 * mb - 1);
      expect(only('>=5MB').min, 5 * mb);
      expect(only('<= 5 MB').max, 5 * mb);
    });

    test('decimals and thousands, with commas or points', () {
      expect(only('over 1,5 GB').min, (1.5 * 1024 * mb).round() + 1);
      expect(only('over 1,5 GB').label, 'Over 1.5 GB');
      expect(only('over 1.5 GB').min, (1.5 * 1024 * mb).round() + 1);
      expect(only('under 1,500 KB').max, 1500 * 1024 - 1);
      expect(only('under 1,500 KB').label, 'Under 1500 KB');
      expect(only('over 2,25 mb').min, (2.25 * mb).round() + 1);
      expect(only('over 1.234.567 bytes').min, 1234567 + 1);
      expect(only('over 1,234.5 KB').min, (1234.5 * 1024).round() + 1);
    });

    test('between', () {
      final span = only('between 1 and 5 MB');
      expect(span.min, mb);
      expect(span.max, 5 * mb);
      expect(span.label, '1–5 MB');
    });

    test('large, huge, small, tiny, empty', () {
      expect(only('large files').min, 128 * mb + 1);
      expect(only('large files').label, 'Large (over 128 MB)');
      expect(only('huge').min, 1024 * mb + 1);
      expect(only('small').max, mb - 1);
      expect(only('tiny').max, 16 * 1024 - 1);
      expect(only('empty files').max, 0);
      expect(parse('large files').words, isEmpty, reason: '"files" joins the others');
    });

    test('a number without a unit is a word', () {
      final q = parse('over 10');
      expect(q.sizes, isEmpty);
      expect(q.words, ['over', '10']);
      expect(parse('10 mb').sizes, isEmpty);
      expect(parse('more photos').sizes, isEmpty);
    });
  });

  group('places', () {
    test('downloads, screenshots, camera, apps', () {
      expect(parse('downloads').places, {SearchPlace.downloads});
      expect(parse('screenshots').places, {SearchPlace.screenshots});
      expect(parse('camera roll').places, {SearchPlace.camera});
      expect(parse('from WhatsApp').places, {SearchPlace.whatsapp});
      expect(chips('from WhatsApp'), ['From WhatsApp']);
      expect(parse('from WhatsApp').words, isEmpty);
      expect(parse('telegram').places, {SearchPlace.telegram});
    });

    test('a place holds its folders, folders named for it, and screenshots by name', () {
      expect(SearchPlace.downloads.holds('/home/me/Downloads/a.pdf', folders: ['/home/me/Downloads']), isTrue);
      expect(SearchPlace.downloads.holds('/home/me/Projects/download/a.pdf'), isTrue);
      expect(SearchPlace.downloads.holds('/home/me/Projects/a.pdf'), isFalse);
      expect(SearchPlace.whatsapp.holds('/s/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/1.jpg'), isTrue);
      expect(SearchPlace.whatsapp.holds('/s/Pictures/whatsapp-export.jpg'), isFalse, reason: 'only folders');
      expect(SearchPlace.telegram.holds('/s/Android/media/org.telegram.messenger/x/1.jpg'), isTrue);
      expect(SearchPlace.screenshots.holds('/Users/me/Desktop/Screenshot 2026-03-01 at 10.00.png'), isTrue);
      expect(SearchPlace.camera.holds('/s/DCIM/Camera/IMG_1.jpg'), isTrue);
    });
  });

  group('the queries Smart search is for', () {
    test('photos from last week', () {
      final q = parse('photos from last week');
      expect(q.kinds, {SearchKind.photos});
      expect(q.dates.single.from, DateTime(2026, 11, 2));
      expect(q.words, isEmpty);
      expect(chips('photos from last week'), ['Photos', 'Last week']);
    });

    test('pdf bigger than 10 MB', () {
      final q = parse('pdf bigger than 10 MB');
      expect(q.kinds, {SearchKind.pdf});
      expect(q.sizes.single.min, 10 * mb + 1);
      expect(q.words, isEmpty);
    });

    test('videos in March', () {
      expect(chips('videos in March'), ['Videos', 'March 2026']);
    });

    test('screenshots 2025', () {
      final q = parse('screenshots 2025');
      expect(q.places, {SearchPlace.screenshots});
      expect(q.dates.single.label, '2025');
    });

    test('receipts from March', () {
      final q = parse('receipts from March');
      expect(q.dates.single.from, DateTime(2026, 3));
      expect(q.words, ['receipts']);
      expect(chips('receipts from March'), ['March 2026', 'receipts']);
      expect(q.chips.last.type, QueryChipType.words);
    });

    test('music, apks, large files', () {
      expect(chips('music'), ['Music']);
      expect(chips('apks'), ['Apps']);
      expect(chips('large files'), ['Large (over 128 MB)']);
    });

    test('quoted words stay words', () {
      final q = parse('"last week" notes');
      expect(q.dates, isEmpty);
      expect(q.words, ['last week', 'notes']);
    });

    test('a * ? pattern is only a pattern', () {
      final q = parse('*.pdf');
      expect(q.hasFilters, isFalse);
      expect(q.words, isEmpty);
      expect(parse('IMG_20?? photos').hasFilters, isFalse);
    });

    test('punctuation around words', () {
      final q = parse('photos, last week.');
      expect(q.kinds, {SearchKind.photos});
      expect(q.dates.single.label, 'Last week');
    });
  });

  group('removing a chip', () {
    test('takes its words out of the query', () {
      final q = parse('photos from last week');
      expect(q.without(q.chips[1]), 'photos');
      expect(q.without(q.chips[0]), 'from last week');
    });

    test('and the little words that led to it', () {
      final q = parse('photos of receipts');
      final words = q.chips.firstWhere((c) => c.type == QueryChipType.words);
      expect(q.without(words), 'photos');
      final receipts = parse('receipts taken in March');
      expect(receipts.without(receipts.chips.first), 'receipts');
    });

    test('keeps what was typed as typed', () {
      final q = parse('Receipts from March');
      expect(q.without(q.chips.first), 'Receipts');
    });
  });
}
