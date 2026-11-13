import 'package:shared_preferences/shared_preferences.dart';

/// How the search box searches: in plain words or not, inside files or not,
/// this folder or everywhere. The first two are remembered.
class SearchOptions {
  const SearchOptions({this.smart = true, this.insideFiles = false, this.everywhere = false});

  /// Understands "photos from last week", "pdf over 10 MB"...
  final bool smart;

  /// Also looks for the words in documents' text (and photos').
  final bool insideFiles;

  /// The home folder and every drive, not this folder.
  final bool everywhere;

  SearchOptions copyWith({bool? smart, bool? insideFiles, bool? everywhere}) => SearchOptions(
        smart: smart ?? this.smart,
        insideFiles: insideFiles ?? this.insideFiles,
        everywhere: everywhere ?? this.everywhere,
      );

  static const _smartKey = 'search_smart';
  static const _insideKey = 'search_inside_files';

  /// The remembered choices (Smart search is on at first).
  static Future<SearchOptions> load() async {
    final prefs = await SharedPreferences.getInstance();
    return SearchOptions(
      smart: prefs.getBool(_smartKey) ?? true,
      insideFiles: prefs.getBool(_insideKey) ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_smartKey, smart);
    await prefs.setBool(_insideKey, insideFiles);
  }

  @override
  bool operator ==(Object other) =>
      other is SearchOptions && other.smart == smart && other.insideFiles == insideFiles && other.everywhere == everywhere;

  @override
  int get hashCode => Object.hash(smart, insideFiles, everywhere);
}
