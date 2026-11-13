import 'package:folders/core/services/search/search_criteria.dart';
import 'package:folders/core/services/search/smart_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 13, 10);
  SearchCriteria smart(String query, {bool inside = false}) =>
      SearchCriteria(query, smart: SmartQuery.parse(query, now: now), insideFiles: inside);

  group('names', () {
    test('words understood still match names as typed', () {
      final march = smart('march');
      expect(march.literal('march-report.pdf'), isTrue, reason: 'a month, and a word');
      expect(march.literal('notes.txt'), isFalse);
      expect(smart('2025').literal('invoice 2025.pdf'), isTrue);
      expect(smart('receipts from march').literal('Receipts March.pdf'), isTrue,
          reason: 'every word but the little ones, in any order');
      expect(smart('receipts from march').literal('receipts.pdf'), isFalse);
    });

    test('plural words find the singular', () {
      expect(smart('receipts').literal('receipt-0042.jpg'), isTrue);
      expect(smart('glass').literal('glas.txt'), isFalse);
    });

    test('Smart search off: the name as before', () {
      final plain = SearchCriteria('receipts from march');
      expect(plain.literal('Receipts March.pdf'), isFalse);
      expect(plain.literal('old receipts from march.txt'), isTrue);
      expect(SearchCriteria('*.pdf').literal('a.PDF'), isTrue);
      expect(plain.beyondNames, isFalse);
    });
  });

  group('filters', () {
    test('kinds, sizes and dates', () {
      final c = smart('photos bigger than 1 MB from last week');
      expect(c.beyondNames, isTrue);
      expect(c.needsStat, isTrue);
      expect(c.passesName('a/IMG_1.jpg', isDirectory: false), isTrue);
      expect(c.passesName('a/notes.txt', isDirectory: false), isFalse);
      expect(c.passesName('a/Photos', isDirectory: true), isFalse, reason: 'folders are no kind of file');
      expect(c.passesStat(size: 2 << 20, modified: DateTime(2026, 11, 4)), isTrue);
      expect(c.passesStat(size: 2 << 20, modified: DateTime(2026, 11, 10)), isFalse);
      expect(c.passesStat(size: 1 << 20, modified: DateTime(2026, 11, 4)), isFalse);
    });

    test('places pass folders too', () {
      final c = SearchCriteria(
        'downloads',
        smart: SmartQuery.parse('downloads', now: now),
        placeFolders: {SearchPlace.downloads: ['/home/me/Downloads']},
      );
      expect(c.passesName('/home/me/Downloads/Work', isDirectory: true), isTrue);
      expect(c.passesName('/home/me/Documents/a.txt', isDirectory: false), isFalse);
      expect(c.words, isEmpty);
    });

    test('words left over are looked for, and inside files when asked', () {
      final c = smart('receipts from march', inside: true);
      expect(c.words, ['receipt']);
      expect(c.wordsIn('the receipt for march'), isTrue);
      expect(c.beyondNames, isTrue);
      expect(smart('report').beyondNames, isFalse, reason: 'only a name to look for');
      expect(smart('report', inside: true).beyondNames, isTrue);
      expect(smart('the').beyondNames, isFalse, reason: 'nothing to look for');
    });

    test('with Smart search off, inside files looks for the whole query', () {
      final c = SearchCriteria('Annual Report', insideFiles: true);
      expect(c.words, ['annual report']);
      expect(SearchCriteria('*.txt', insideFiles: true).words, isEmpty);
    });
  });

  group('snippets', () {
    test('the words in context, highlighted', () {
      final c = smart('budget', inside: true);
      final text = 'Minutes of the meeting.\n\nWe agreed the BUDGET for next year, '
          'then talked about the budget again for a long time without deciding anything at all.';
      final snippet = c.matchText('/notes/minutes.txt', text)!;
      expect(snippet.text, contains('BUDGET'));
      for (final (start, end) in snippet.highlights) {
        expect(snippet.text.substring(start, end).toLowerCase(), 'budget');
      }
      expect(snippet.highlights, hasLength(2));
      expect(snippet.text, isNot(contains('\n')), reason: 'one line');
    });

    test('a long text is cut around the first match', () {
      final text = '${'lorem ipsum ' * 50}the invoice number is 42 ${'dolor sit ' * 50}';
      final snippet = SearchSnippet.find(text, ['invoice'])!;
      expect(snippet.text.startsWith('…'), isTrue);
      expect(snippet.text.endsWith('…'), isTrue);
      expect(snippet.text.length, lessThan(170));
      expect(snippet.text, contains('invoice number is 42'));
    });

    test('words split between the name and the text match', () {
      final c = smart('tax receipt', inside: true);
      expect(c.matchText('/a/tax-2025.pdf', 'Receipt no. 7'), isNotNull);
      expect(c.matchText('/a/other.pdf', 'Receipt no. 7'), isNull);
    });

    test('overlapping highlights merge', () {
      expect(SearchSnippet.highlightsIn('abcabc', ['abc', 'bca']), [(0, 6)]);
    });
  });
}
