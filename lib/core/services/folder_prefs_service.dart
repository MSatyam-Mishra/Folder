import 'dart:convert';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';

enum ViewMode { list, grid, compact, gallery }

enum SortOption { name, size, date, type }

enum SortOrder { ascending, descending }

/// Headings a folder's items are grouped under, as in File Explorer.
enum GroupBy { none, name, date, type, size }

class FolderPrefsService {
  static final FolderPrefsService _instance = FolderPrefsService._internal();
  factory FolderPrefsService() => _instance;
  FolderPrefsService._internal();

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (!_initialized) {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;
    }
  }

  static const _showHiddenKey = 'show_hidden_files';

  /// Whether dotfiles and hidden or system files are listed. The phone app
  /// always listed them; on computers they're hidden, as in other file
  /// managers. Call [init] first.
  bool get showHidden =>
      (_initialized ? _prefs.getBool(_showHiddenKey) : null) ??
      !ExplorerPaths.isDesktop;

  Future<void> setShowHidden(bool value) async {
    await init();
    await _prefs.setBool(_showHiddenKey, value);
  }

  // Generate a hash for the path to keep keys short and clean
  String _getPathKey(String path) {
    var bytes = utf8.encode(path);
    var digest = sha256.convert(bytes);
    return 'folder_prefs_${digest.toString().substring(0, 16)}';
  }

  ViewMode getViewMode(String path) {
    final key = _getPathKey(path);
    final jsonString = _prefs.getString(key);
    if (jsonString == null) {
      final pictures = path == ExplorerPaths.categoryPath('Photos') || path == ExplorerPaths.categoryPath('Video');
      return pictures ? ViewMode.gallery : ViewMode.list; // Default
    }

    final map = jsonDecode(jsonString);
    return ViewMode.values[map['viewMode'] ?? 0];
  }

  SortOption getSortOption(String path) {
    final key = _getPathKey(path);
    final jsonString = _prefs.getString(key);
    if (jsonString == null) {
      return ExplorerPaths.isCategory(path) ? SortOption.date : SortOption.name; // Default
    }

    final map = jsonDecode(jsonString);
    return SortOption.values[map['sortOption'] ?? 0];
  }

  SortOrder getSortOrder(String path) {
    final key = _getPathKey(path);
    final jsonString = _prefs.getString(key);
    if (jsonString == null) {
      return ExplorerPaths.isCategory(path) ? SortOrder.descending : SortOrder.ascending; // Default
    }

    final map = jsonDecode(jsonString);
    return SortOrder.values[map['sortOrder'] ?? 0];
  }

  GroupBy getGroupBy(String path) {
    final jsonString = _prefs.getString(_getPathKey(path));
    if (jsonString == null) return GroupBy.none;
    final index = jsonDecode(jsonString)['groupBy'];
    return index is int && index < GroupBy.values.length
        ? GroupBy.values[index]
        : GroupBy.none;
  }

  Future<void> setGroupBy(String path, GroupBy groupBy) async {
    await _updatePrefs(path, {'groupBy': groupBy.index});
  }

  Future<void> setViewMode(String path, ViewMode mode) async {
    await _updatePrefs(path, {'viewMode': mode.index});
  }

  Future<void> setSort(String path, SortOption option, SortOrder order) async {
    await _updatePrefs(path, {
      'sortOption': option.index,
      'sortOrder': order.index,
    });
  }

  Future<void> _updatePrefs(String path, Map<String, dynamic> updates) async {
    final key = _getPathKey(path);
    final jsonString = _prefs.getString(key);
    Map<String, dynamic> currentPrefs = {};

    if (jsonString != null) {
      currentPrefs = jsonDecode(jsonString);
    }

    currentPrefs.addAll(updates);
    await _prefs.setString(key, jsonEncode(currentPrefs));
  }
}
