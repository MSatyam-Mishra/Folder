import 'package:folders/features/category_view/bloc/bloc/category_bloc.dart';
import 'package:folders/features/category_view/home_media.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Photos, Video and Audio categories built from home folders (and, for
/// macOS videos, merged with the Photos library).
void main() {
  test('media inside macOS packages is left out of the categories', () {
    for (final path in [
      '/Users/me/Movies/iMovie Library.imovielibrary/Trip/Original Media/a.mov',
      '/Users/me/Music/GarageBand/Song.band/Media/take 1.aif',
      '/Users/me/Downloads/film.mp4.download/film.mp4',
      '/Users/me/Pictures/Photos Library.photoslibrary/originals/0/b.mov',
    ]) {
      expect(HomeMedia.insideMacPackage(path), isTrue, reason: path);
    }
    for (final path in [
      '/Users/me/Downloads/holiday.mov',
      '/Users/me/Movies/TV/Media.localized/Movies/film.m4v',
      '/Users/me/Music/Music/Media.localized/Music/Artist/Album/01 Song.m4a',
      '/Users/me/Desktop/clip.band.mov',
    ]) {
      expect(HomeMedia.insideMacPackage(path), isFalse, reason: path);
    }
  });

  test('library items and loose files merge by date, newest first', () {
    final library = [
      (DateTime(2026, 10, 24, 18), 'library 24 18h'),
      (DateTime(2026, 10, 24, 9), 'library 24 9h'),
      (DateTime(2026, 10, 20, 12), 'library 20'),
    ];
    final loose = [
      (DateTime(2026, 10, 25, 8), 'file 25'),
      (DateTime(2026, 10, 24, 12), 'file 24 12h'),
      (DateTime(2026, 10, 22, 7), 'file 22'),
    ];
    final groups = CategoryBloc.mergeByDay(library, loose);
    expect(groups.keys, [
      DateTime(2026, 10, 25),
      DateTime(2026, 10, 24),
      DateTime(2026, 10, 22),
      DateTime(2026, 10, 20),
    ]);
    expect(groups[DateTime(2026, 10, 24)], [
      'library 24 18h',
      'file 24 12h',
      'library 24 9h',
    ]);
    expect(CategoryBloc.mergeByDay(const [], loose).values.expand((e) => e), [
      'file 25',
      'file 24 12h',
      'file 22',
    ]);
    expect(CategoryBloc.mergeByDay(const [], const []), isEmpty);
  });
}
