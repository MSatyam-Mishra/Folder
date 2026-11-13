import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/git_status/git_porcelain.dart';
import 'package:folders/features/git_status/git_repos.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Options > Git status: on unless turned off (computers only).
class GitStatusSettings extends ValueNotifier<bool> {
  GitStatusSettings._() : super(true);

  static final instance = GitStatusSettings._();
  static const _key = 'git_status';
  Future<void>? _loading;

  Future<void> load() => _loading ??= () async {
        final prefs = await SharedPreferences.getInstance();
        value = prefs.getBool(_key) ?? true;
      }();

  Future<void> set(bool on) async {
    value = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, on);
  }

  @visibleForTesting
  void reset() {
    _loading = null;
    value = true;
  }
}

/// The Git status of the folder a browser shows, for its branch chip and
/// its items' badges; null outside a work tree (or when it's off).
///
/// Follows the browser's folder, and runs `git status` again shortly after
/// the folder changes (the browser reloads when its files change), one run
/// at a time.
class GitStatusController extends ValueNotifier<GitStatus?> {
  GitStatusController({this.debounce = const Duration(milliseconds: 350)}) : super(null) {
    GitStatusSettings.instance.addListener(_settingChanged);
  }

  static final _ofBloc = Expando<GitStatusController>();

  /// The controller of [bloc]'s browser, following its folder.
  static GitStatusController of(FileExplorerBloc bloc) => _ofBloc[bloc] ??= GitStatusController().._follow(bloc);

  /// Widget tests run on a fake clock, where git's run would be a timer left
  /// over: off there, unless a test turns it on.
  @visibleForTesting
  static bool runInTests = false;
  static final bool _testing = Platform.environment.containsKey('FLUTTER_TEST');

  final Duration debounce;
  String? _folder;
  Timer? _timer;
  bool _running = false;
  bool _again = false;
  bool _closed = false;
  StreamSubscription<FileExplorerState>? _states;
  String? _shownPath;
  Object? _shownItems;

  void _follow(FileExplorerBloc bloc) {
    void onState(FileExplorerState state) {
      if (state is! FileExplorerLoaded) return;
      // Only a new folder or a reload, not a selection or a search.
      if (state.path == _shownPath && identical(state.entities, _shownItems)) return;
      _shownPath = state.path;
      _shownItems = state.entities;
      show(state.path);
    }

    _states = bloc.stream.listen(onState, onDone: close);
    onState(bloc.state);
  }

  /// Shows [folder]'s status, at once if it's known, then read again.
  void show(String? folder) {
    if (_closed) return;
    _folder = folder;
    if (folder == null || !ExplorerPaths.isDesktop || !GitStatusSettings.instance.value || (_testing && !runInTests)) {
      _timer?.cancel();
      value = null;
      return;
    }
    final root = GitRepos.rootOf(folder);
    if (root == null) {
      _timer?.cancel();
      value = null;
      return;
    }
    if (value?.root != root) value = GitRepos.cached(root);
    _timer?.cancel();
    _timer = Timer(debounce, _run);
    // The settings are read once; until then it shows as on.
    unawaited(GitStatusSettings.instance.load());
  }

  /// Reads the status again now (F5, or the chip's Refresh).
  void refresh() {
    _timer?.cancel();
    _run();
  }

  Future<void> _run() async {
    if (_closed) return;
    if (_running) {
      _again = true;
      return;
    }
    final folder = _folder;
    final root = folder == null ? null : GitRepos.rootOf(folder);
    if (root == null || !GitStatusSettings.instance.value) return;
    _running = true;
    try {
      final status = await GitRepos.load(root);
      final now = _folder;
      if (!_closed && now != null && GitStatusSettings.instance.value && GitRepos.rootOf(now) == root) value = status;
    } finally {
      _running = false;
      if (_again && !_closed) {
        _again = false;
        _timer?.cancel();
        _timer = Timer(debounce, _run);
      }
    }
  }

  void _settingChanged() => show(_folder);

  /// Stops following (the browser closed).
  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _states?.cancel();
    GitStatusSettings.instance.removeListener(_settingChanged);
  }
}
