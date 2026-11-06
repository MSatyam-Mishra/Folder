import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:folders/core/formats/archive_backend.dart';
import 'package:folders/core/formats/archive_comic.dart';
import 'package:folders/core/formats/archive_extract.dart';
import 'package:folders/core/formats/archive_session.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// State of one page.
class ComicPageState {
  const ComicPageState({this.bytes, this.file, this.error, this.waiting = false});

  final Uint8List? bytes;
  final File? file;
  final ArcException? error;

  /// The page is being unpacked by the sequential pass (solid archives).
  final bool waiting;

  bool get ready => bytes != null || file != null;
}

/// Loads a comic's pages lazily with a small read-ahead cache.
///
/// Random-access archives (ZIP, 7z, TAR, non-solid RAR) read single pages
/// on demand in the worker isolate. Solid RAR and compressed TAR can only
/// be decoded front to back, so one background pass unpacks every page to
/// a temporary folder in archive order (bounded memory) and pages appear as
/// they are written.
class ComicBook extends ChangeNotifier {
  ComicBook(this.file);

  final File file;

  ArchiveSession? _session;
  StreamSubscription<ArcOpenEvent>? _openSub;
  bool _disposed = false;

  bool loading = true;
  ArcException? error;
  String? password;
  String formatLabel = '';
  List<ArcEntry> pages = const [];
  bool sequential = false;

  /// Pages unpacked so far by the sequential pass.
  int unpacked = 0;

  final Map<int, ValueNotifier<ComicPageState>> _states = {};

  // Random access.
  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap();
  int _cacheBytes = 0;
  static const int _cacheLimit = 96 * 1024 * 1024;
  final List<int> _queue = [];
  bool _reading = false;
  int _focus = 0;

  // Sequential pass.
  ExtractJob? _fill;
  Directory? _cacheDir;
  final Map<int, String> _unpackedFiles = {};

  ValueListenable<ComicPageState> page(int i) =>
      _states.putIfAbsent(i, () => ValueNotifier(const ComicPageState()));

  void _set(int i, ComicPageState s) {
    if (_disposed) return;
    (page(i) as ValueNotifier<ComicPageState>).value = s;
  }

  Future<void> open({String? password}) async {
    this.password = password;
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (_session == null) {
        final session = await ArchiveSession.spawn();
        if (_disposed) {
          session.dispose();
          return;
        }
        _session = session;
      }
    } catch (e) {
      _fail(ArcException(ArcErrorKind.io, 'Couldn\'t start the reader.', detail: '$e'));
      return;
    }
    if (_disposed) return;
    await _openSub?.cancel();
    _openSub = _session!.open(file.path, password: password).listen(
      (event) {
        if (event is ArcOpenReady) _ready(event.summary);
      },
      onError: (Object e) => _fail(e is ArcException ? e : mapKoniError(e)),
    );
  }

  void _fail(ArcException e) {
    if (_disposed) return;
    loading = false;
    error = e;
    notifyListeners();
  }

  void _ready(ArcSummary summary) {
    if (_disposed) return;
    formatLabel = summary.formatLabel;
    pages = comicPages(summary.entries);
    sequential = summary.isSequential;
    loading = false;
    if (pages.isEmpty) {
      error = ArcException(
        ArcErrorKind.notArchive,
        'There are no images in this comic.',
      );
    }
    notifyListeners();
    if (pages.isEmpty) return;
    if (sequential) {
      _startSequentialPass();
    } else {
      focus(_focus);
    }
  }

  // ---------------------------------------------------------------------------
  // Random access
  // ---------------------------------------------------------------------------

  /// The reader is showing [index] (and maybe [index] + 1): load it first,
  /// then its neighbours.
  void focus(int index, {int visible = 1}) {
    if (pages.isEmpty) return;
    _focus = index.clamp(0, pages.length - 1);
    if (sequential) {
      for (var i = 0; i < visible; i++) {
        _publishSequential(_focus + i);
      }
      return;
    }
    final want = <int>[
      for (var i = 0; i < visible; i++) _focus + i,
      _focus + visible,
      _focus + visible + 1,
      _focus - 1,
      _focus + visible + 2,
    ].where((i) => i >= 0 && i < pages.length).toList();
    _queue
      ..clear()
      ..addAll(want.where((i) => !_cache.containsKey(i)));
    for (final i in want) {
      final cached = _cache.remove(i);
      if (cached != null) {
        _cache[i] = cached; // most recently used
        if (!page(i).value.ready) _set(i, ComicPageState(bytes: cached));
      }
    }
    _pump();
  }

  Future<void> _pump() async {
    if (_reading || _queue.isEmpty || _disposed) return;
    _reading = true;
    final i = _queue.removeAt(0);
    try {
      final bytes = await _session!.read(pages[i].index);
      if (_disposed) return;
      _cache[i] = bytes;
      _cacheBytes += bytes.length;
      // Evict least recently used pages far from the reader's position.
      while (_cacheBytes > _cacheLimit && _cache.length > 3) {
        final victim = _cache.keys.firstWhere(
          (k) => (k - _focus).abs() > 2,
          orElse: () => _cache.keys.first,
        );
        _cacheBytes -= _cache.remove(victim)!.length;
        _set(victim, const ComicPageState());
      }
      _set(i, ComicPageState(bytes: bytes));
    } on ArcException catch (e) {
      if (e.kind == ArcErrorKind.needPassword ||
          e.kind == ArcErrorKind.wrongPassword) {
        _queue.clear();
        _fail(e);
      } else {
        _set(i, ComicPageState(error: e));
      }
    } catch (e) {
      _set(i, ComicPageState(error: mapKoniError(e)));
    } finally {
      _reading = false;
    }
    _pump();
  }

  /// Retries a page that failed.
  void retry(int index) {
    _set(index, const ComicPageState());
    if (sequential) return;
    _queue.insert(0, index);
    _pump();
  }

  // ---------------------------------------------------------------------------
  // Sequential pass (solid archives)
  // ---------------------------------------------------------------------------

  Future<void> _startSequentialPass() async {
    final old = _cacheDir;
    if (old != null) {
      try {
        if (old.existsSync()) old.deleteSync(recursive: true);
      } catch (_) {}
    }
    unpacked = 0;
    _unpackedFiles.clear();
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(
      tmp.path,
      'comic_pages',
      '${file.path.hashCode.toUnsigned(32).toRadixString(16)}_'
          '${DateTime.now().millisecondsSinceEpoch}',
    ));
    await dir.create(recursive: true);
    _cacheDir = dir;
    final targets = <int, String>{};
    for (final pg in pages) {
      final ext = p.extension(pg.name).toLowerCase();
      targets[pg.index] = p.join(dir.path, '${pg.index}$ext');
    }
    final byIndex = {for (var i = 0; i < pages.length; i++) pages[i].index: i};
    ExtractJob job;
    try {
      job = await ExtractJob.start(ExtractRequest(
        archivePath: file.path,
        destination: dir.path,
        password: password,
        policy: ConflictPolicy.overwrite,
        targets: targets,
        reportEachFile: true,
      ));
    } catch (e) {
      _fail(ArcException(ArcErrorKind.io, 'Couldn\'t start unpacking.', detail: '$e'));
      return;
    }
    if (_disposed) {
      job.cancel();
      return;
    }
    _fill = job;
    for (var i = 0; i < pages.length; i++) {
      _set(i, const ComicPageState(waiting: true));
    }
    await for (final ev in job.events) {
      if (_disposed) break;
      switch (ev) {
        case ExtractFileDone(:final index, :final path):
          final pageIndex = byIndex[index];
          if (pageIndex == null) break;
          _unpackedFiles[pageIndex] = path;
          unpacked++;
          _publishSequential(pageIndex);
          notifyListeners();
        case ExtractDone(:final result):
          for (final (path, message) in result.failures) {
            final i = pages.indexWhere((e) => e.path == path);
            if (i >= 0) {
              _set(i, ComicPageState(
                error: ArcException(ArcErrorKind.corrupt, message),
              ));
            }
          }
        case ExtractFailed(:final error):
          if (error.kind != ArcErrorKind.cancelled) _fail(error);
        default:
          break;
      }
    }
    _fill = null;
  }

  void _publishSequential(int i) {
    if (i < 0 || i >= pages.length) return;
    final path = _unpackedFiles[i];
    if (path == null) return;
    if (page(i).value.file?.path != path) _set(i, ComicPageState(file: File(path)));
  }

  @override
  void dispose() {
    _disposed = true;
    _openSub?.cancel();
    _fill?.cancel();
    _session?.dispose();
    for (final n in _states.values) {
      n.dispose();
    }
    final dir = _cacheDir;
    if (dir != null) {
      // Let the cancelled job release its files first.
      Future<void>.delayed(const Duration(seconds: 1), () {
        try {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        } catch (_) {}
      });
    }
    super.dispose();
  }
}
