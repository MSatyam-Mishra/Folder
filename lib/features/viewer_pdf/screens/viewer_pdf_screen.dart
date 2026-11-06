import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:folders/core/services/bookmark_service.dart';
import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:folders/features/viewer_pdf/models/pdf_edit_models.dart';
import 'package:folders/features/viewer_pdf/screens/pdf_page_canvas_screen.dart';
import 'package:folders/features/viewer_pdf/services/pdf_annotation_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdf_document_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdf_form_ops.dart';
import 'package:folders/features/viewer_pdf/services/pdf_page_rasterizer.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_annotation_toolbar.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_dialogs.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_page_manager.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_search_bar.dart';
import 'package:folders/features/viewer_pdf/widgets/pdf_side_panel.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// PDF viewer and editor: reading, search, outline, bookmarks, annotations,
/// form filling, drawing/stamps and page organisation.
class PdfViewerScreen extends StatefulWidget {
  final File pdfFile;

  const PdfViewerScreen({super.key, required this.pdfFile});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

enum _LoadState { loading, locked, error, ready }

enum _MenuAction {
  save,
  saveCopy,
  share,
  goToPage,
  toggleBookmark,
  pages,
  insertPdf,
  layout,
  nightMode,
  zoomIn,
  zoomOut,
  setPassword,
  removePassword,
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  static const _prefNightMode = 'pdf_viewer.night_mode';
  static const _prefSinglePage = 'pdf_viewer.single_page';
  static const _historyLimit = 10;
  static const _historyByteBudget = 160 * 1024 * 1024;

  /// "Smart invert": flips lightness but keeps hues recognisable.
  static const _nightMatrix = <double>[
    0.574, -1.430, -0.144, 0, 255, //
    -0.426, -0.430, -0.144, 0, 255, //
    -0.426, -1.430, 0.856, 0, 255, //
    0, 0, 0, 1, 0,
  ];
  static const _identityMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  final BookmarkService _bookmarkService = BookmarkService();
  final GlobalKey _bodyKey = GlobalKey();
  final ValueNotifier<int> _currentPage = ValueNotifier(1);
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // Document state.
  late File _file = widget.pdfFile;
  _LoadState _loadState = _LoadState.loading;
  String? _errorMessage;
  Uint8List? _sourceBytes;

  /// Bytes the viewer was created from; only changes when it is reloaded.
  Uint8List? _viewerBytes;

  /// Latest known document bytes, without unsaved viewer annotations.
  Uint8List? _latestBytes;
  String? _password;
  bool _unlocking = false;
  PdfViewerController _controller = PdfViewerController();
  int _docVersion = 0;
  int _initialPage = 1;
  bool _viewerReady = false;
  int _pageCount = 0;
  PdfDocument? _viewerDocument;
  List<PdfOutlineEntry>? _outline;
  bool _outlineLoading = false;

  /// Zoom and scroll position to restore after the viewer reloads.
  Matrix4? _restoreMatrix;

  /// Interactive form fields of the shown document, by page index.
  Map<int, List<PdfFormField>> _formFields = const {};

  /// Annotation edits made in the open document not yet in [_latestBytes].
  bool _viewerHasChanges = false;
  bool _dirty = false;
  bool _folderChanged = false;
  String? _busyLabel;
  final List<Uint8List> _history = [];
  final List<Uint8List> _redoHistory = [];

  // Page manager data.
  List<PdfPageMeta>? _pageMetas;
  PdfPageRasterizer? _rasterizer;
  bool _pageDataLoading = false;
  int _pageDataFailedVersion = -1;

  // UI state.
  List<Bookmark> _bookmarks = [];
  bool _editMode = false;
  bool _nightMode = false;
  bool _singlePage = false;
  bool? _panelOpen;
  int _panelTab = 0;
  bool _searchOpen = false;
  bool _searching = false;
  bool _matchCase = false;
  bool _wholeWords = false;
  PdfTextSearcher? _searcher;
  PdfAnnotationMode _annotationMode = PdfAnnotationMode.none;
  PdfAnnotationInfo? _selectedAnnotation;
  bool _hasTextSelection = false;
  Color _canvasColor = const Color(0xFFF44336);
  final Map<PdfAnnotationMode, Color> _markupColors = {
    PdfAnnotationMode.highlight: const Color(0xFFFFEB3B),
    PdfAnnotationMode.underline: const Color(0xFF4CAF50),
    PdfAnnotationMode.strikethrough: const Color(0xFFF44336),
    PdfAnnotationMode.squiggly: const Color(0xFFFF9800),
    PdfAnnotationMode.stickyNote: const Color(0xFFFFEB3B),
  };
  Timer? _lastReadTimer;

  bool get _busy => _busyLabel != null;
  String get _bookmarkKey => widget.pdfFile.path;
  String get _fileName => p.basename(_file.path);

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _loadBookmarks();
    _open();
  }

  @override
  void dispose() {
    _lastReadTimer?.cancel();
    if (_viewerReady) {
      _bookmarkService.saveLastReadPosition(
        _bookmarkKey,
        _currentPage.value - 1,
      );
    }
    _rasterizer?.close();
    _searcher?.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _currentPage.dispose();
    super.dispose();
  }

  /// setState that is safe to call from viewer callbacks, which can fire
  /// during build or while the old viewer is being disposed.
  void _post(VoidCallback change) {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(change);
      });
    } else {
      setState(change);
    }
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _nightMode = prefs.getBool(_prefNightMode) ?? false;
        _singlePage = prefs.getBool(_prefSinglePage) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _savePreference(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _loadBookmarks() async {
    try {
      final bookmarks = await _bookmarkService.getBookmarks(_bookmarkKey);
      if (mounted) setState(() => _bookmarks = bookmarks);
    } catch (_) {}
  }

  /// Reads the file and shows it; password-protected files are unlocked
  /// first, so the viewer always works on a plain copy.
  Future<void> _open() async {
    if (_loadState != _LoadState.loading) {
      setState(() {
        _loadState = _LoadState.loading;
        _errorMessage = null;
      });
    }
    final initialPage = _lastReadPage();
    try {
      _sourceBytes ??= await widget.pdfFile.readAsBytes();
    } catch (e) {
      _fail('The file could not be read.', e);
      return;
    }
    final PdfProbeResult probe;
    try {
      probe = await PdfDocumentOps.probe(_sourceBytes!);
    } catch (e) {
      _fail('This file could not be opened as a PDF.', e);
      return;
    }
    if (!mounted) return;
    switch (probe.status) {
      case PdfOpenStatus.needsPassword:
        await _promptPassword();
      case PdfOpenStatus.invalid:
        _fail('This file could not be opened as a PDF.', probe.message);
      case PdfOpenStatus.ok:
        final page = await initialPage;
        if (mounted) _reloadViewer(_sourceBytes!, page: page);
    }
  }

  Future<int> _lastReadPage() async {
    try {
      final lastRead = await _bookmarkService.getLastReadPosition(_bookmarkKey);
      // The viewer ignores a page past the end of the document.
      if (lastRead is num) return math.max(1, lastRead.toInt() + 1);
    } catch (_) {}
    return 1;
  }

  /// Asks for the password of the (encrypted) source file and shows the
  /// decrypted copy.
  Future<void> _promptPassword() async {
    final bytes = _sourceBytes;
    if (bytes == null || !mounted || _unlocking) return;
    setState(() {
      _loadState = _LoadState.loading;
      _errorMessage = null;
    });
    _unlocking = true;
    final Uint8List? unlocked;
    try {
      unlocked = await _unlock(bytes);
    } finally {
      _unlocking = false;
    }
    if (!mounted) return;
    if (unlocked == null) {
      // Only a cancelled prompt locks; a failure keeps _unlock's error.
      if (_loadState != _LoadState.error) {
        setState(() => _loadState = _LoadState.locked);
      }
      return;
    }
    final page = await _lastReadPage();
    if (mounted) _reloadViewer(unlocked, page: page);
  }

  /// Prompts for the password until it is right or the user gives up.
  /// Returns the decrypted bytes, or null when cancelled or when decrypting
  /// failed (then the screen is already in the error state).
  Future<Uint8List?> _unlock(Uint8List bytes) async {
    var wrong = false;
    while (true) {
      if (!mounted) return null;
      final password = await showPdfPasswordDialog(
        context,
        fileName: _fileName,
        wrongPassword: wrong,
      );
      if (password == null || !mounted) return null;
      try {
        final probe = await PdfDocumentOps.probe(bytes, password: password);
        if (probe.status == PdfOpenStatus.ok) {
          final plain = await PdfDocumentOps.decrypt(bytes, password);
          _password = password;
          return plain;
        }
        if (probe.status == PdfOpenStatus.invalid) {
          _fail('This file could not be opened as a PDF.', probe.message);
          return null;
        }
      } catch (e) {
        _fail('The PDF could not be decrypted.', e);
        return null;
      }
      wrong = true;
    }
  }

  void _fail(String message, [Object? error]) {
    if (!mounted) return;
    debugPrint('PdfViewerScreen: $message ${error ?? ''}');
    setState(() {
      _loadState = _LoadState.error;
      _errorMessage = message;
    });
  }

  // ---------------------------------------------------------------------------
  // Viewer callbacks
  // ---------------------------------------------------------------------------

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    if (!identical(controller, _controller)) return;
    final searcher = PdfTextSearcher(controller)..addListener(_onSearchChanged);
    final restore = _restoreMatrix;
    _restoreMatrix = null;
    _post(() {
      _viewerDocument = document;
      _viewerReady = true;
      _pageCount = document.pages.length;
      _searcher = searcher;
      final page = controller.pageNumber;
      if (page != null) _currentPage.value = page;
    });
    if (restore != null) {
      unawaited(controller.goTo(restore, duration: Duration.zero));
    }
    _loadFormFields();
    _sweepTempFilesOnce();
  }

  void _onSearchChanged() => _post(() {});

  Future<void> _loadFormFields() async {
    final bytes = _viewerBytes;
    final version = _docVersion;
    if (bytes == null) return;
    try {
      final fields = await PdfFormOps.fields(bytes);
      if (!mounted || version != _docVersion) return;
      final byPage = <int, List<PdfFormField>>{};
      for (final field in fields) {
        if (field.isEditable) (byPage[field.pageIndex] ??= []).add(field);
      }
      setState(() => _formFields = byPage);
    } catch (_) {
      // No form, or one PDFium can't read: the document still shows.
    }
  }

  /// The outline is read the first time the side panel is built rather than
  /// when the document loads.
  List<PdfOutlineEntry>? get _outlineIfLoaded {
    final document = _viewerDocument;
    if (document == null) return null;
    if (_outline == null && !_outlineLoading) {
      _outlineLoading = true;
      final version = _docVersion;
      PdfOutlineEntry.read(document).then((outline) {
        if (version != _docVersion) return;
        _outlineLoading = false;
        _post(() => _outline = outline);
      });
    }
    return _outline;
  }

  void _onPageChanged(int? page) {
    if (page == null) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _currentPage.value = page;
      });
    } else {
      _currentPage.value = page;
    }
    _lastReadTimer?.cancel();
    _lastReadTimer = Timer(const Duration(milliseconds: 600), () {
      _bookmarkService.saveLastReadPosition(_bookmarkKey, page - 1);
    });
  }

  Future<void> _onLinkTap(PdfLink link) async {
    final dest = link.dest;
    if (dest != null) {
      await _controller.goToDest(dest);
      return;
    }
    final url = link.url;
    if (url == null || !mounted) return;
    final open = await showPdfConfirmDialog(
      context,
      title: 'Open link?',
      message: url.toString(),
      confirmLabel: 'Open',
    );
    if (!open) return;
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        _showError('No app can open this link');
      }
    } catch (e) {
      _showError('Could not open the link', e);
    }
  }

  // ---------------------------------------------------------------------------
  // Document bytes, history and reloads
  // ---------------------------------------------------------------------------

  /// Current document including annotation/form edits made in the viewer.
  Future<Uint8List> _currentBytes() async {
    final document = _viewerDocument;
    if (_viewerReady && _viewerHasChanges && document != null) {
      final saved = await document.encodePdf();
      _latestBytes = saved;
      _viewerHasChanges = false;
      return saved;
    }
    return _latestBytes!;
  }

  void _pushHistory(List<Uint8List> stack, Uint8List bytes) {
    stack.add(bytes);
    var total = stack.fold<int>(0, (sum, b) => sum + b.length);
    while (stack.length > _historyLimit ||
        (stack.length > 1 && total > _historyByteBudget)) {
      total -= stack.removeAt(0).length;
    }
  }

  /// Shows [bytes] in a fresh viewer, keeping the reading position.
  void _reloadViewer(Uint8List bytes, {int? page, bool keepPosition = false}) {
    final oldRasterizer = _rasterizer;
    final controller = PdfViewerController();
    _restoreMatrix = keepPosition && _controller.isReady
        ? _controller.value.clone()
        : null;
    _searcher?.dispose();
    setState(() {
      _loadState = _LoadState.ready;
      _errorMessage = null;
      _viewerBytes = bytes;
      _latestBytes = bytes;
      _viewerHasChanges = false;
      _docVersion++;
      _controller = controller;
      _initialPage = math.max(1, page ?? _currentPage.value);
      _currentPage.value = _initialPage;
      _viewerReady = false;
      _viewerDocument = null;
      _outline = null;
      _outlineLoading = false;
      _formFields = const {};
      _selectedAnnotation = null;
      _hasTextSelection = false;
      _searcher = null;
      _searching = false;
      _pageMetas = null;
      _rasterizer = null;
    });
    oldRasterizer?.close();
  }

  /// Runs a structural edit on the current bytes and reloads the viewer.
  Future<bool> _runDocumentEdit(
    String label,
    Future<Uint8List> Function(Uint8List current) edit, {
    int? targetPage,
    bool keepPosition = false,
  }) async {
    if (_busy || _latestBytes == null) return false;
    _setBusy(label);
    try {
      final current = await _currentBytes();
      final next = await edit(current);
      if (!mounted) return false;
      _pushHistory(_history, current);
      _redoHistory.clear();
      _dirty = true;
      _reloadViewer(next, page: targetPage, keepPosition: keepPosition);
      return true;
    } catch (e) {
      _showError('$label failed', e);
      return false;
    } finally {
      _setBusy(null);
    }
  }

  void _setBusy(String? label) {
    if (mounted) setState(() => _busyLabel = label);
  }

  bool get _canUndo => _history.isNotEmpty;
  bool get _canRedo => _redoHistory.isNotEmpty;

  Future<void> _undo() async {
    if (_busy) return;
    if (_history.isEmpty) return;
    _setBusy('Undoing…');
    try {
      final current = await _currentBytes();
      _pushHistory(_redoHistory, current);
      final previous = _history.removeLast();
      if (!mounted) return;
      _dirty = true;
      _reloadViewer(previous, keepPosition: true);
    } catch (e) {
      _showError('Undo failed', e);
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _redo() async {
    if (_busy) return;
    if (_redoHistory.isEmpty) return;
    _setBusy('Redoing…');
    try {
      final current = await _currentBytes();
      _pushHistory(_history, current);
      final next = _redoHistory.removeLast();
      if (!mounted) return;
      _dirty = true;
      _reloadViewer(next, keepPosition: true);
    } catch (e) {
      _showError('Redo failed', e);
    } finally {
      _setBusy(null);
    }
  }

  // ---------------------------------------------------------------------------
  // Saving and sharing
  // ---------------------------------------------------------------------------

  Future<Uint8List> _bytesForDisk() async {
    final bytes = await _currentBytes();
    final password = _password;
    if (password == null || password.isEmpty) return bytes;
    return PdfDocumentOps.encrypt(bytes, password);
  }

  Future<bool> _save({required bool asCopy}) async {
    if (_busy || _latestBytes == null) return false;
    // A PDF-compatible file of another type (e.g. an Illustrator .ai opened
    // as PDF) would lose its own data if overwritten with a plain PDF.
    asCopy = asCopy || p.extension(_file.path).toLowerCase() != '.pdf';
    _setBusy(asCopy ? 'Saving a copy…' : 'Saving…');
    try {
      final out = await _bytesForDisk();
      final target = asCopy
          ? File(
              await _uniquePath(
                _file.parent.path,
                '${p.basenameWithoutExtension(_file.path)}_edited',
                '.pdf',
              ),
            )
          : _file;
      await _writeSafely(target, out);
      if (!mounted) return true;
      setState(() {
        _file = target;
        _dirty = false;
        _folderChanged = true;
      });
      _showMessage(asCopy ? 'Saved as ${p.basename(target.path)}' : 'Saved');
      return true;
    } on FileSystemException catch (e) {
      _showError(
        asCopy ? 'Could not save a copy' : 'Could not save this file',
        e.osError?.message ?? e.message,
        asCopy
            ? null
            : SnackBarAction(
                label: 'Save copy',
                onPressed: () => _save(asCopy: true),
              ),
      );
      return false;
    } catch (e) {
      _showError('Saving failed', e);
      return false;
    } finally {
      _setBusy(null);
    }
  }

  /// Writes [bytes] to [target] through a temporary file in the same folder
  /// that then replaces it, so a failed or interrupted write (full disk,
  /// removed card, app killed) never leaves the original truncated.
  static Future<void> _writeSafely(File target, Uint8List bytes) async {
    var path = target.path;
    try {
      // Replace the real file, not a symbolic link pointing at it.
      path = await target.resolveSymbolicLinks();
    } catch (_) {
      // A new file (save as copy) has nothing to resolve yet.
    }
    final temp = File(
      p.join(
        p.dirname(path),
        '.${p.basename(path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    // iPad shows the share sheet as a popover that needs an anchor: the
    // top bar's trailing corner, where the menu was opened.
    final size = MediaQuery.sizeOf(context);
    final origin = Rect.fromLTWH(
      math.max(0, size.width - 64),
      MediaQuery.paddingOf(context).top + 12,
      48,
      48,
    );
    Directory? shareDir;
    try {
      String path = _file.path;
      if (_dirty) {
        _setBusy('Preparing to share…');
        final out = await _bytesForDisk();
        // One fixed folder, emptied first: at most one shared copy is kept.
        shareDir = Directory(p.join(Directory.systemTemp.path, _shareDirName));
        await _deleteQuietly(shareDir);
        await shareDir.create(recursive: true);
        path = p.join(shareDir.path, _fileName);
        await File(path).writeAsBytes(out, flush: true);
        _setBusy(null);
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
      );
      // On Android share_plus copies the file into its own cache before
      // returning; elsewhere the target app may still be reading ours.
      if (shareDir != null && Platform.isAndroid) {
        await _deleteQuietly(shareDir);
      }
    } catch (e) {
      _setBusy(null);
      _showError('Sharing failed', e);
    }
  }

  static const _shareDirName = 'pdf_share';
  static bool _tempSwept = false;

  /// Once per run, removes temp copies left behind when the app was killed
  /// (shares of edited documents, page renderer copies).
  static void _sweepTempFilesOnce() {
    if (_tempSwept) return;
    _tempSwept = true;
    unawaited(() async {
      try {
        // The age check spares another running instance's files (desktop).
        final cutoff = DateTime.now().subtract(const Duration(hours: 1));
        await for (final entity in Directory.systemTemp.list()) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          final ours =
              name.startsWith('pdf_share') || name.startsWith('pdf_pages_');
          if (ours && (await entity.stat()).modified.isBefore(cutoff)) {
            await _deleteQuietly(entity);
          }
        }
      } catch (_) {
        // Best effort.
      }
    }());
  }

  static Future<void> _deleteQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<String> _uniquePath(String dir, String base, String ext) async {
    var candidate = p.join(dir, '$base$ext');
    var n = 2;
    while (await File(candidate).exists() ||
        await Directory(candidate).exists()) {
      candidate = p.join(dir, '$base ($n)$ext');
      n++;
    }
    return candidate;
  }

  Future<void> _handleBack() async {
    if (_busy) return;
    if (_dirty) {
      final choice = await showUnsavedPdfDialog(context);
      if (choice == null || !mounted) return;
      switch (choice) {
        case UnsavedChoice.save:
          if (!await _save(asCopy: false)) return;
        case UnsavedChoice.saveCopy:
          if (!await _save(asCopy: true)) return;
        case UnsavedChoice.discard:
          break;
      }
    }
    if (mounted) Navigator.of(context).pop(_folderChanged ? true : null);
  }

  // ---------------------------------------------------------------------------
  // Page editing
  // ---------------------------------------------------------------------------

  Future<void> _ensurePageData() async {
    if (_pageDataLoading || _latestBytes == null) return;
    if (_pageMetas != null &&
        (_rasterizer != null || _pageDataFailedVersion == _docVersion)) {
      return;
    }
    _pageDataLoading = true;
    final version = _docVersion;
    final bytes = _viewerBytes!;
    try {
      final metas = _pageMetas ?? await PdfDocumentOps.pageMetas(bytes);
      var rasterizer = _rasterizer;
      if (rasterizer == null && _pageDataFailedVersion != version) {
        try {
          rasterizer = await PdfPageRasterizer.open(bytes);
        } catch (_) {
          // Thumbnails are optional; the page list still works without.
          _pageDataFailedVersion = version;
        }
      }
      if (!mounted || version != _docVersion) {
        if (rasterizer != _rasterizer) await rasterizer?.close();
        return;
      }
      setState(() {
        _pageMetas = metas;
        _rasterizer = rasterizer;
      });
    } catch (e) {
      _pageDataFailedVersion = version;
      _showError('Could not read the pages', e);
    } finally {
      _pageDataLoading = false;
      if (mounted && version != _docVersion) _ensurePageData();
    }
  }

  Future<void> _applyPagePlan(List<PagePlanEntry> plan) async {
    final page = _currentPage.value - 1;
    final newIndex = plan.indexWhere((e) => e.sourceIndex == page);
    final ok = await _runDocumentEdit(
      'Updating pages',
      (bytes) => PdfDocumentOps.applyPagePlan(bytes, plan),
      targetPage: newIndex >= 0
          ? newIndex + 1
          : math.min(page + 1, plan.length),
    );
    if (ok) _showMessage('Pages updated');
  }

  Future<void> _extractPages(Set<int> pages) async {
    if (_busy) return;
    _setBusy('Extracting pages…');
    try {
      final current = await _currentBytes();
      var out = await PdfDocumentOps.extractPages(current, pages);
      final password = _password;
      if (password != null && password.isNotEmpty) {
        out = await PdfDocumentOps.encrypt(out, password);
      }
      final path = await _uniquePath(
        _file.parent.path,
        '${p.basenameWithoutExtension(_file.path)}_pages',
        '.pdf',
      );
      await _writeSafely(File(path), out);
      _folderChanged = true;
      _showMessage(
        'Saved ${pages.length} page${pages.length == 1 ? '' : 's'} to '
        '${p.basename(path)}',
      );
    } catch (e) {
      _showError('Extracting pages failed', e);
    } finally {
      _setBusy(null);
    }
  }

  Future<void> _insertPdf() async {
    if (_busy) return;
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
    } catch (e) {
      _showError('Could not open the file picker', e);
      return;
    }
    final picked = result?.files.singleOrNull;
    if (picked == null || !mounted) return;

    Uint8List other;
    try {
      other = picked.bytes ?? await File(picked.path!).readAsBytes();
    } catch (e) {
      _showError('Could not read ${picked.name}', e);
      return;
    }

    String? otherPassword;
    var probe = await PdfDocumentOps.probe(other);
    var wrong = false;
    while (probe.status == PdfOpenStatus.needsPassword) {
      if (!mounted) return;
      otherPassword = await showPdfPasswordDialog(
        context,
        fileName: picked.name,
        wrongPassword: wrong,
      );
      if (otherPassword == null) return;
      probe = await PdfDocumentOps.probe(other, password: otherPassword);
      wrong = true;
    }
    if (!mounted) return;
    if (probe.status != PdfOpenStatus.ok) {
      _showError('${picked.name} is not a readable PDF', probe.message);
      return;
    }

    final current = _currentPage.value;
    final position = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          'Insert ${probe.pageCount} page'
          '${probe.pageCount == 1 ? '' : 's'}',
        ),
        contentPadding: const EdgeInsets.fromLTRB(4, 12, 4, 16),
        children: [
          ViewerListTile(
            leading: const Icon(LucideIcons.betweenHorizontalStart),
            title: 'After page $current',
            onTap: () => Navigator.pop(context, current),
          ),
          ViewerListTile(
            leading: const Icon(LucideIcons.arrowDownToLine),
            title: 'At the end',
            onTap: () => Navigator.pop(context, _pageCount),
          ),
          ViewerListTile(
            leading: const Icon(LucideIcons.arrowUpToLine),
            title: 'At the beginning',
            onTap: () => Navigator.pop(context, 0),
          ),
        ],
      ),
    );
    if (position == null || !mounted) return;
    final ok = await _runDocumentEdit(
      'Inserting PDF',
      (bytes) => PdfDocumentOps.insertPdf(
        bytes,
        other,
        otherPassword: otherPassword,
        index: position,
      ),
      targetPage: position + 1,
    );
    if (ok) _showMessage('Inserted ${picked.name}');
  }

  PdfPageMeta? _metaForPage(int pageIndex) {
    final document = _viewerDocument;
    if (document == null || pageIndex < 0) return null;
    if (pageIndex >= document.pages.length) return null;
    final page = document.pages[pageIndex];
    final rotation = page.rotation.index * 90;
    final sideways = rotation == 90 || rotation == 270;
    // pdfrx reports the displayed (rotated) size.
    return PdfPageMeta(
      width: sideways ? page.height : page.width,
      height: sideways ? page.width : page.height,
      rotation: rotation,
    );
  }

  Future<void> _openCanvas(PageCanvasTool tool, PageCanvasStart start) async {
    if (_busy || !_viewerReady) return;
    final pageIndex = _currentPage.value - 1;
    final meta = _metaForPage(pageIndex);
    if (meta == null) return;
    _setBusy('Preparing page…');
    Uint8List bytes;
    try {
      bytes = await _currentBytes();
    } catch (e) {
      _showError('Could not prepare the page', e);
      return;
    } finally {
      _setBusy(null);
    }
    if (!mounted) return;
    // The canvas stays open until the marks are burned in, so a failure
    // (e.g. an unreadable image) doesn't throw away the whole session.
    await Navigator.push<List<PageMark>>(
      context,
      MaterialPageRoute(
        builder: (_) => PdfPageCanvasScreen(
          documentBytes: bytes,
          pageNumber: pageIndex + 1,
          meta: meta,
          initialTool: tool,
          start: start,
          initialColor: _canvasColor,
          onApply: (marks) => _runDocumentEdit(
            'Adding to page',
            (current) => PdfDocumentOps.drawOnPage(current, pageIndex, marks),
            targetPage: pageIndex + 1,
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Annotation tools
  // ---------------------------------------------------------------------------

  void _setEditMode(bool on) {
    setState(() {
      _editMode = on;
      if (!on) {
        _annotationMode = PdfAnnotationMode.none;
        _selectedAnnotation = null;
      }
    });
    _controller.invalidate();
  }

  void _setAnnotationMode(PdfAnnotationMode mode) {
    setState(() {
      _annotationMode = mode;
      _selectedAnnotation = null;
    });
    _controller.invalidate();
  }

  Color get _toolbarColor {
    final selected = _selectedAnnotation;
    if (selected != null) return selected.color;
    return _markupColors[_annotationMode] ?? _canvasColor;
  }

  /// Runs an in-place change to the open document's annotations, with an
  /// undo step, and redraws the pages.
  Future<bool> _changeAnnotations(
    String failure,
    Future<void> Function(PdfDocument document) change,
  ) async {
    final document = _viewerDocument;
    if (document == null || _busy) return false;
    try {
      final before = await _currentBytes();
      await change(document);
      _pushHistory(_history, before);
      _redoHistory.clear();
      _viewerHasChanges = true;
      _controller.forceRepaintAllPageImages();
      if (mounted) setState(() => _dirty = true);
      return true;
    } catch (e) {
      _showError(failure, e);
      return false;
    }
  }

  /// Marks up the selected text; [kind] defaults to the active tool.
  Future<void> _markUpSelection([PdfMarkupKind? kind]) async {
    final markup = kind ?? _annotationMode.markup;
    if (markup == null || !_viewerReady) return;
    final mode = switch (markup) {
      PdfMarkupKind.highlight => PdfAnnotationMode.highlight,
      PdfMarkupKind.underline => PdfAnnotationMode.underline,
      PdfMarkupKind.strikeout => PdfAnnotationMode.strikethrough,
      PdfMarkupKind.squiggly => PdfAnnotationMode.squiggly,
    };
    final selection = _controller.textSelectionDelegate;
    final ranges = await selection.getSelectedTextRanges();
    if (ranges.isEmpty) return;
    final ok = await _changeAnnotations('Could not mark up the text', (
      doc,
    ) async {
      for (final range in ranges) {
        final lines = _lineRects(range);
        if (lines.isEmpty) continue;
        await PdfAnnotationOps.addMarkup(
          doc,
          range.pageNumber - 1,
          markup,
          lines,
          _markupColors[mode]!,
        );
      }
    });
    if (ok) await selection.clearTextSelection();
  }

  /// One rect per line of the characters in [range].
  static List<PdfRect> _lineRects(PdfPageTextRange range) {
    final rects = range.pageText.charRects;
    final lines = <PdfRect>[];
    PdfRect? line;
    for (var i = range.start; i < range.end && i < rects.length; i++) {
      final r = rects[i];
      if (r.width <= 0 || r.height <= 0) continue;
      final current = line;
      final centre = (r.top + r.bottom) / 2;
      if (current != null &&
          centre <= current.top &&
          centre >= current.bottom &&
          r.left >= current.left - 1) {
        line = current.merge(r);
      } else {
        if (current != null) lines.add(current);
        line = r;
      }
    }
    if (line != null) lines.add(line);
    return lines;
  }

  /// Taps in edit mode: place a note, or select the annotation tapped.
  bool _onGeneralTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    if (!_editMode || details.type != PdfViewerGeneralTapType.tap) {
      return false;
    }
    final hit = controller.getPdfPageHitTestResult(
      details.documentPosition,
      useDocumentLayoutCoordinates: true,
    );
    if (hit == null) return false;
    final pageIndex = hit.page.pageNumber - 1;
    if (_annotationMode == PdfAnnotationMode.stickyNote) {
      _addNote(pageIndex, hit.offset);
      return true;
    }
    if (_annotationMode == PdfAnnotationMode.none) {
      _selectAnnotationAt(pageIndex, hit.offset);
    }
    return false;
  }

  Future<void> _addNote(int pageIndex, PdfPoint at) async {
    final text = await showPdfTextInputDialog(
      context,
      title: 'Add note',
      hint: 'Your note',
      confirmLabel: 'Add',
      multiline: true,
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _changeAnnotations(
      'Could not add the note',
      (doc) => PdfAnnotationOps.addNote(
        doc,
        pageIndex,
        at,
        text,
        _markupColors[PdfAnnotationMode.stickyNote]!,
      ),
    );
  }

  Future<void> _selectAnnotationAt(int pageIndex, PdfPoint at) async {
    final document = _viewerDocument;
    if (document == null) return;
    try {
      final hit = await PdfAnnotationOps.hitTest(document, pageIndex, at);
      if (!mounted) return;
      setState(() => _selectedAnnotation = hit);
      _controller.invalidate();
    } catch (_) {}
  }

  Future<void> _pickColor() async {
    final color = await showPdfColorPicker(context, _toolbarColor);
    if (color == null || !mounted) return;
    final selected = _selectedAnnotation;
    if (selected != null) {
      final ok = await _changeAnnotations(
        'Could not change the colour',
        (doc) => PdfAnnotationOps.setColor(doc, selected, color),
      );
      if (ok && mounted) {
        setState(
          () => _selectedAnnotation = PdfAnnotationInfo(
            pageIndex: selected.pageIndex,
            index: selected.index,
            subtype: selected.subtype,
            bounds: selected.bounds,
            color: color,
            contents: selected.contents,
          ),
        );
      }
      return;
    }
    setState(() {
      if (_markupColors.containsKey(_annotationMode)) {
        _markupColors[_annotationMode] = color;
      } else {
        _canvasColor = color;
      }
    });
  }

  Future<void> _deleteSelectedAnnotation() async {
    final selected = _selectedAnnotation;
    if (selected == null) return;
    final ok = await _changeAnnotations(
      'Could not delete the annotation',
      (doc) => PdfAnnotationOps.remove(doc, selected),
    );
    if (ok && mounted) setState(() => _selectedAnnotation = null);
  }

  Future<void> _editSelectedNote() async {
    final note = _selectedAnnotation;
    if (note == null || !note.isNote) return;
    final text = await showPdfTextInputDialog(
      context,
      title: 'Edit note',
      initialText: note.contents,
      confirmLabel: 'Save',
      multiline: true,
    );
    if (text == null || !mounted) return;
    await _changeAnnotations(
      'Could not change the note',
      (doc) => PdfAnnotationOps.setContents(doc, note, text),
    );
  }

  // ---------------------------------------------------------------------------
  // Forms
  // ---------------------------------------------------------------------------

  Future<void> _editField(PdfFormField field) async {
    if (_busy) return;
    Future<Uint8List> Function(Uint8List) edit;
    switch (field.type) {
      case PdfFormFieldType.text:
        final text = await showPdfTextInputDialog(
          context,
          title: field.name.isEmpty ? 'Fill in' : _fieldLabel(field.name),
          initialText: field.value,
          confirmLabel: 'Done',
          multiline: field.multiline,
        );
        if (text == null || text == field.value) return;
        edit = (bytes) => PdfFormOps.setText(bytes, field, text);
      case PdfFormFieldType.checkbox || PdfFormFieldType.radio:
        edit = (bytes) => PdfFormOps.toggle(bytes, field);
      case PdfFormFieldType.combo || PdfFormFieldType.list:
        if (field.options.isEmpty) return;
        final picked = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(
              field.name.isEmpty ? 'Choose' : _fieldLabel(field.name),
            ),
            children: [
              for (var i = 0; i < field.options.length; i++)
                ViewerListTile(
                  leading: Icon(
                    field.selected.contains(i)
                        ? LucideIcons.circleCheck
                        : LucideIcons.circle,
                  ),
                  title: field.options[i],
                  onTap: () => Navigator.pop(context, i),
                ),
            ],
          ),
        );
        if (picked == null) return;
        edit = (bytes) => PdfFormOps.select(bytes, field, picked);
      default:
        return;
    }
    if (!mounted) return;
    await _runDocumentEdit(
      'Filling in the form',
      edit,
      targetPage: field.pageIndex + 1,
      keepPosition: true,
    );
  }

  /// "invoice.billing_name" → "billing name".
  static String _fieldLabel(String name) =>
      name.split('.').last.replaceAll(RegExp(r'[_-]+'), ' ').trim();

  // ---------------------------------------------------------------------------
  // Navigation, search, bookmarks
  // ---------------------------------------------------------------------------

  ScaffoldState? get _scaffold {
    final context = _bodyKey.currentContext;
    return context == null ? null : Scaffold.maybeOf(context);
  }

  void _closeDrawerIfOpen() {
    final scaffold = _scaffold;
    if (scaffold != null && scaffold.isDrawerOpen) scaffold.closeDrawer();
  }

  void _goToPageIndex(int index) {
    if (!_viewerReady) return;
    _controller.goToPage(
      pageNumber: (index + 1).clamp(1, math.max(1, _pageCount)),
    );
    _closeDrawerIfOpen();
  }

  Future<void> _openOutlineNode(PdfOutlineEntry node) async {
    if (!_viewerReady) return;
    final dest = node.dest;
    if (dest != null && await _controller.goToDest(dest)) {
      _closeDrawerIfOpen();
      return;
    }
    _showMessage('This outline entry has no page to go to');
  }

  Future<void> _showGoToPage() async {
    if (!_viewerReady) return;
    final page = await showGoToPageDialog(
      context,
      pageCount: _pageCount,
      currentPage: _currentPage.value,
    );
    if (page != null && mounted) _controller.goToPage(pageNumber: page);
  }

  Bookmark? get _bookmarkOnCurrentPage {
    final index = _currentPage.value - 1;
    for (final bookmark in _bookmarks) {
      final position = bookmark.position;
      if (position is num && position.toInt() == index) return bookmark;
    }
    return null;
  }

  Future<void> _toggleBookmark() async {
    final existing = _bookmarkOnCurrentPage;
    if (existing != null) {
      await _removeBookmark(existing);
      return;
    }
    final page = _currentPage.value;
    try {
      await _bookmarkService.addBookmark(_bookmarkKey, page - 1, 'Page $page');
      await _loadBookmarks();
      _showMessage('Bookmarked page $page');
    } catch (e) {
      _showError('Could not add the bookmark', e);
    }
  }

  Future<void> _removeBookmark(Bookmark bookmark) async {
    try {
      await _bookmarkService.removeBookmark(_bookmarkKey, bookmark.id);
      await _loadBookmarks();
    } catch (e) {
      _showError('Could not remove the bookmark', e);
    }
  }

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    _searcher?.resetTextSearch();
    setState(() {
      _searchOpen = false;
      _searching = false;
    });
  }

  void _submitSearch(String text) {
    final query = text.trim();
    final searcher = _searcher;
    searcher?.resetTextSearch();
    if (query.isEmpty || !_viewerReady || searcher == null) {
      setState(() => _searching = false);
      return;
    }
    final escaped = RegExp.escape(query);
    searcher.startTextSearch(
      RegExp(
        _wholeWords ? '\\b$escaped\\b' : escaped,
        caseSensitive: _matchCase,
        unicode: true,
      ),
      caseInsensitive: !_matchCase,
      searchImmediately: true,
    );
    setState(() => _searching = true);
  }

  void _openPanel(int tab) {
    setState(() => _panelTab = tab);
    if (AdaptiveSplitView.isSplit(context)) {
      setState(() => _panelOpen = true);
    } else {
      _scaffold?.openDrawer();
    }
  }

  void _togglePanel() {
    if (AdaptiveSplitView.isSplit(context)) {
      setState(() => _panelOpen = !(_panelOpen ?? true));
    } else {
      _scaffold?.openDrawer();
    }
  }

  // ---------------------------------------------------------------------------
  // Menu
  // ---------------------------------------------------------------------------

  Future<void> _onMenu(_MenuAction action) async {
    switch (action) {
      case _MenuAction.save:
        await _save(asCopy: false);
      case _MenuAction.saveCopy:
        await _save(asCopy: true);
      case _MenuAction.share:
        await _share();
      case _MenuAction.goToPage:
        await _showGoToPage();
      case _MenuAction.toggleBookmark:
        await _toggleBookmark();
      case _MenuAction.pages:
        _openPanel(2);
      case _MenuAction.insertPdf:
        await _insertPdf();
      case _MenuAction.layout:
        setState(() => _singlePage = !_singlePage);
        _savePreference(_prefSinglePage, _singlePage);
      case _MenuAction.nightMode:
        setState(() => _nightMode = !_nightMode);
        _savePreference(_prefNightMode, _nightMode);
      case _MenuAction.zoomIn:
        await _controller.zoomUp();
      case _MenuAction.zoomOut:
        await _controller.zoomDown();
      case _MenuAction.setPassword:
        final password = await showSetPdfPasswordDialog(context);
        if (password == null || !mounted) return;
        setState(() {
          _password = password;
          _dirty = true;
        });
        _showMessage('The password will be applied when you save');
      case _MenuAction.removePassword:
        final confirmed = await showPdfConfirmDialog(
          context,
          title: 'Remove password?',
          message: 'The saved file will open without a password.',
          confirmLabel: 'Remove',
        );
        if (!confirmed || !mounted) return;
        setState(() {
          _password = null;
          _dirty = true;
        });
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String message, [Object? error, SnackBarAction? action]) {
    if (!mounted) return;
    debugPrint('PdfViewerScreen: $message ${error ?? ''}');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final split = AdaptiveSplitView.isSplit(context);
    final width = MediaQuery.sizeOf(context).width;
    final ready = _loadState == _LoadState.ready;

    return PopScope(
      canPop: !_dirty && !_busy && !_folderChanged,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _openSearch,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_dirty) _save(asCopy: false);
          },
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () {
            if (_dirty) _save(asCopy: false);
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_searchOpen) _closeSearch();
          },
        },
        child: Focus(
          autofocus: true,
          child: ExplorerScaffold(
            title: _dirty ? '$_fileName •' : _fileName,
            drawer: ready && !split
                ? AppSidebar(
                    width: math.min(380, width * 0.9),
                    child: _buildSidePanel(docked: false),
                  )
                : null,
            trailing: ready ? _buildTopActions(context, split) : null,
            body: KeyedSubtree(
              key: _bodyKey,
              child: _buildBody(context, split),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopActions(BuildContext context, bool split) {
    final hasPassword = _password != null && _password!.isNotEmpty;
    final bookmarked = _bookmarkOnCurrentPage != null;
    final panelShown = split && (_panelOpen ?? true);
    return ViewerActions(
      children: [
        ViewerAction(
          icon: LucideIcons.search,
          tooltip: 'Search',
          selected: _searchOpen,
          onPressed: _viewerReady
              ? () => _searchOpen ? _closeSearch() : _openSearch()
              : null,
        ),
        ViewerAction(
          icon: split
              ? (panelShown
                    ? LucideIcons.panelLeftClose
                    : LucideIcons.panelLeft)
              : LucideIcons.listTree,
          tooltip: 'Outline, bookmarks and pages',
          onPressed: _togglePanel,
        ),
        ViewerAction(
          icon: _editMode ? LucideIcons.check : LucideIcons.penLine,
          tooltip: _editMode ? 'Done editing' : 'Edit and annotate',
          selected: _editMode,
          onPressed: _viewerReady ? () => _setEditMode(!_editMode) : null,
        ),
        ViewerMenuButton<_MenuAction>(
          enabled: !_busy,
          badge: _dirty,
          onSelected: _onMenu,
          itemBuilder: (context) => [
            viewerMenuItem(
              value: _MenuAction.save,
              icon: LucideIcons.save,
              label: 'Save',
              hint: 'Ctrl+S',
              enabled: _dirty,
            ),
            viewerMenuItem(
              value: _MenuAction.saveCopy,
              icon: LucideIcons.copy,
              label: 'Save as copy',
            ),
            viewerMenuItem(
              value: _MenuAction.share,
              icon: LucideIcons.share2,
              label: 'Share',
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: _MenuAction.goToPage,
              icon: LucideIcons.fileSearch,
              label: 'Go to page…',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.toggleBookmark,
              icon: bookmarked
                  ? LucideIcons.bookmarkMinus
                  : LucideIcons.bookmarkPlus,
              label: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.pages,
              icon: LucideIcons.layers,
              label: 'Organise pages',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.insertPdf,
              icon: LucideIcons.filePlus,
              label: 'Insert PDF…',
              enabled: _viewerReady,
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: _MenuAction.layout,
              icon: LucideIcons.galleryVertical,
              label: 'Continuous scroll',
              checked: !_singlePage,
            ),
            viewerMenuItem(
              value: _MenuAction.nightMode,
              icon: LucideIcons.moon,
              label: 'Night mode',
              checked: _nightMode,
            ),
            viewerMenuItem(
              value: _MenuAction.zoomIn,
              icon: LucideIcons.zoomIn,
              label: 'Zoom in',
              enabled: _viewerReady,
            ),
            viewerMenuItem(
              value: _MenuAction.zoomOut,
              icon: LucideIcons.zoomOut,
              label: 'Zoom out',
              enabled: _viewerReady,
            ),
            viewerMenuDivider(),
            viewerMenuItem(
              value: _MenuAction.setPassword,
              icon: LucideIcons.lock,
              label: hasPassword ? 'Change password…' : 'Set password…',
            ),
            if (hasPassword)
              viewerMenuItem(
                value: _MenuAction.removePassword,
                icon: LucideIcons.lockOpen,
                label: 'Remove password',
                destructive: true,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, bool split) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    switch (_loadState) {
      case _LoadState.loading:
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: const _PageSkeleton(),
        );
      case _LoadState.locked:
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: ViewerMessage(
            icon: LucideIcons.lock,
            title: 'This PDF is password protected',
            message: 'Enter its password to open it.',
            actions: [
              FilledButton.icon(
                onPressed: _promptPassword,
                icon: const Icon(LucideIcons.keyRound, size: 16),
                label: const Text('Enter password'),
              ),
            ],
          ),
        );
      case _LoadState.error:
        return Padding(
          padding: EdgeInsets.only(top: top),
          child: ViewerMessage(
            icon: LucideIcons.fileX,
            destructive: true,
            title: "Couldn't open this PDF",
            message: _errorMessage ?? 'This PDF could not be opened.',
            actions: [
              FilledButton.icon(
                onPressed: () {
                  _sourceBytes = null;
                  _open();
                },
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('Try again'),
              ),
            ],
          ),
        );
      case _LoadState.ready:
        break;
    }

    final viewerArea = _buildViewerArea(context);
    final showPane = split && (_panelOpen ?? true);
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: showPane
          ? AdaptiveSplitView(
              secondaryWidth: 340,
              primary: viewerArea,
              secondary: _buildSidePanel(docked: true),
            )
          : viewerArea,
    );
  }

  Widget _buildSidePanel({required bool docked}) {
    final panel = ValueListenableBuilder<int>(
      valueListenable: _currentPage,
      builder: (context, page, _) => _buildSidePanelContent(docked, page),
    );
    if (!docked) return panel;
    return ColoredBox(color: context.colors.background, child: panel);
  }

  Widget _buildSidePanelContent(bool docked, int currentPage) {
    return PdfSidePanel(
      tabIndex: _panelTab,
      onTabChanged: (tab) => _post(() => _panelTab = tab),
      outline: _outlineIfLoaded,
      onOutlineSelected: _openOutlineNode,
      bookmarks: _bookmarks,
      currentPage: currentPage,
      onBookmarkSelected: _goToPageIndex,
      onBookmarkRemoved: _removeBookmark,
      onAddBookmark: _viewerReady ? _toggleBookmark : null,
      onClose: docked ? () => setState(() => _panelOpen = false) : null,
      pages: PdfPageManager(
        metas: _pageMetas,
        rasterizer: _rasterizer,
        currentPage: _currentPage,
        busy: _busy || !_viewerReady,
        onOpenPage: _goToPageIndex,
        onApply: _applyPagePlan,
        onExtract: _extractPages,
        onInsertPdf: _insertPdf,
        onNeedData: _ensurePageData,
      ),
    );
  }

  /// [color] through the night-mode matrix (which is its own inverse).
  static Color _invert(Color color) {
    final r = color.r * 255, g = color.g * 255, b = color.b * 255;
    double channel(int row) {
      final m = _nightMatrix;
      final i = row * 5;
      return (m[i] * r + m[i + 1] * g + m[i + 2] * b + m[i + 4]).clamp(0, 255);
    }

    return Color.fromARGB(
      255,
      channel(0).round(),
      channel(1).round(),
      channel(2).round(),
    );
  }

  Widget _buildViewer(BuildContext context) {
    final colors = context.colors;
    // Night mode inverts the whole viewer, surround included: give it the
    // colour that inverts to a dark surround.
    final surround = _nightMode
        ? _invert(context.isDarkMode ? colors.muted : const Color(0xFF27272A))
        : ViewerSurface.canvas(context);
    final selected = _selectedAnnotation;
    return PdfViewer.data(
      _viewerBytes!,
      key: ValueKey(_docVersion),
      sourceName: '${_file.path}#$_docVersion',
      controller: _controller,
      initialPageNumber: _initialPage,
      params: PdfViewerParams(
        backgroundColor: surround,
        margin: 12,
        pageDropShadow: const BoxShadow(
          color: Color(0x29000000),
          blurRadius: 6,
          offset: Offset(0, 1),
        ),
        layoutPages: _singlePage ? _sideBySide : null,
        onViewerReady: _onViewerReady,
        onPageChanged: _onPageChanged,
        linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLinkTap),
        onGeneralTap: _onGeneralTap,
        textSelectionParams: PdfTextSelectionParams(
          onTextSelectionChange: (selection) {
            final has = selection.hasSelectedText;
            if (has != _hasTextSelection) _post(() => _hasTextSelection = has);
          },
        ),
        customizeContextMenuItems: (params, items) {
          if (!params.textSelectionDelegate.hasSelectedText) return;
          void add(String label, PdfMarkupKind kind) => items.add(
            ContextMenuButtonItem(
              label: label,
              onPressed: () {
                params.dismissContextMenu();
                _markUpSelection(kind);
              },
            ),
          );
          add('Highlight', PdfMarkupKind.highlight);
          add('Underline', PdfMarkupKind.underline);
          add('Strike out', PdfMarkupKind.strikeout);
        },
        pagePaintCallbacks: [
          if (_searcher != null) _searcher!.pageTextMatchPaintCallback,
          if (selected != null)
            (canvas, pageRect, page) {
              if (page.pageNumber != selected.pageIndex + 1) return;
              final rect = selected.bounds
                  .toRectInDocument(page: page, pageRect: pageRect)
                  .inflate(3);
              canvas.drawRRect(
                RRect.fromRectAndRadius(rect, const Radius.circular(3)),
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2
                  ..color = colors.primary,
              );
            },
        ],
        pageOverlaysBuilder: _formFields.isEmpty ? null : _formOverlays,
        viewerOverlayBuilder: (context, size, handleLinkTap) => [
          // Double tap zooms in (and back out at the largest zoom).
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: () => _controller.zoomUp(loop: true),
            child: IgnorePointer(
              child: SizedBox(width: size.width, height: size.height),
            ),
          ),
          PdfViewerScrollThumb(
            controller: _controller,
            orientation: _singlePage
                ? ScrollbarOrientation.bottom
                : ScrollbarOrientation.right,
            thumbSize: const Size(44, 26),
            thumbBuilder: (context, thumbSize, pageNumber, controller) =>
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.popover,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colors.border),
                    boxShadow: const [
                      BoxShadow(color: Color(0x22000000), blurRadius: 6),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      '${pageNumber ?? ''}',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.popoverForeground,
                      ),
                    ),
                  ),
                ),
          ),
        ],
        loadingBannerBuilder: (context, bytesDownloaded, totalBytes) =>
            const _PageSkeleton(),
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            ViewerMessage(
              icon: LucideIcons.fileX,
              destructive: true,
              title: "Couldn't show this PDF",
              message: '$error',
            ),
      ),
    );
  }

  /// Pages side by side (the "continuous scroll" setting off).
  static PdfPageLayout _sideBySide(
    List<PdfPage> pages,
    PdfViewerParams params,
  ) {
    final height =
        pages.fold(0.0, (h, page) => math.max(h, page.height)) +
        params.margin * 2;
    final layouts = <Rect>[];
    var x = params.margin;
    for (final page in pages) {
      layouts.add(
        Rect.fromLTWH(x, (height - page.height) / 2, page.width, page.height),
      );
      x += page.width + params.margin;
    }
    return PdfPageLayout(pageLayouts: layouts, documentSize: Size(x, height));
  }

  /// Tappable boxes over the form fields of [page].
  List<Widget> _formOverlays(
    BuildContext context,
    Rect pageRect,
    PdfPage page,
  ) {
    final fields = _formFields[page.pageNumber - 1];
    if (fields == null) return const [];
    final highlight = context.colors.primary.withValues(alpha: 0.08);
    return [
      for (final field in fields)
        Positioned.fromRect(
          rect: field.bounds.toRect(page: page, scaledPageSize: pageRect.size),
          child: Material(
            color: highlight,
            child: InkWell(
              onTap: _busy ? null : () => _editField(field),
              child: Tooltip(
                message: field.name.isEmpty
                    ? 'Form field'
                    : _fieldLabel(field.name),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildViewerArea(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottom = media.padding.bottom;
    final hasHint =
        PdfAnnotationToolbar.hintFor(_annotationMode, _selectedAnnotation) !=
        null;
    final toolbarSpace = !_editMode ? 0.0 : (hasHint ? 100.0 : 60.0);

    return Padding(
      padding: EdgeInsets.only(
        left: media.padding.left,
        right: media.padding.right,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(
                _nightMode ? _nightMatrix : _identityMatrix,
              ),
              child: _buildViewer(context),
            ),
          ),
          // Until the first document is shown (the viewer has its own
          // progress bar; later reloads keep the old pages' layout).
          if (!_viewerReady && _pageCount == 0)
            const Positioned.fill(
              child: IgnorePointer(child: _PageSkeleton(showProgress: false)),
            ),
          if (_searchOpen)
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: PdfSearchBar(
                    controller: _searchText,
                    focusNode: _searchFocus,
                    result: _searcher,
                    searching: _searching,
                    matchCase: _matchCase,
                    wholeWords: _wholeWords,
                    onSubmitted: _submitSearch,
                    onOptionsChanged: ({matchCase, wholeWords}) {
                      setState(() {
                        _matchCase = matchCase ?? _matchCase;
                        _wholeWords = wholeWords ?? _wholeWords;
                      });
                      if (_searching) _submitSearch(_searchText.text);
                    },
                    onClose: _closeSearch,
                  ),
                ),
              ),
            ),
          if (_viewerReady)
            Positioned(
              left: 12,
              bottom: bottom + 12 + toolbarSpace,
              child: ValueListenableBuilder<int>(
                valueListenable: _currentPage,
                builder: (context, page, _) => ViewerPill(
                  text: '$page / $_pageCount',
                  semanticsLabel:
                      'Page $page of $_pageCount. Tap to go to a page',
                  onTap: _showGoToPage,
                ),
              ),
            ),
          if (_editMode && _hasTextSelection && _annotationMode.markup != null)
            Positioned(
              left: 8,
              right: 8,
              bottom: bottom + 8 + toolbarSpace,
              child: Center(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _markUpSelection(),
                  icon: const Icon(LucideIcons.check, size: 16),
                  label: Text(switch (_annotationMode) {
                    PdfAnnotationMode.underline => 'Underline selection',
                    PdfAnnotationMode.strikethrough => 'Strike out selection',
                    PdfAnnotationMode.squiggly =>
                      'Squiggly-underline selection',
                    _ => 'Highlight selection',
                  }),
                ),
              ),
            ),
          if (_editMode)
            Positioned(
              left: 8,
              right: 8,
              bottom: bottom + 8,
              child: Center(
                child: PdfAnnotationToolbar(
                  mode: _annotationMode,
                  onModeChanged: _setAnnotationMode,
                  color: _toolbarColor,
                  onPickColor: _pickColor,
                  onDraw: () =>
                      _openCanvas(PageCanvasTool.pen, PageCanvasStart.none),
                  onText: () =>
                      _openCanvas(PageCanvasTool.text, PageCanvasStart.none),
                  onImage: () =>
                      _openCanvas(PageCanvasTool.select, PageCanvasStart.image),
                  onSignature: () => _openCanvas(
                    PageCanvasTool.select,
                    PageCanvasStart.signature,
                  ),
                  canUndo: _canUndo,
                  canRedo: _canRedo,
                  onUndo: _undo,
                  onRedo: _redo,
                  selected: _selectedAnnotation,
                  onDeleteSelected: _deleteSelectedAnnotation,
                  onEditNote: _editSelectedNote,
                  enabled: !_busy && _viewerReady,
                ),
              ),
            ),
          if (_busy)
            Positioned.fill(child: ViewerBusyOverlay(label: _busyLabel!)),
        ],
      ),
    );
  }
}

/// Page-shaped placeholder shown from the first frame until the document is
/// on screen.
class _PageSkeleton extends StatelessWidget {
  const _PageSkeleton({this.showProgress = true});

  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ColoredBox(
      color: ViewerSurface.canvas(context),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(
            0.0,
            math.min(constraints.maxWidth - 24, 760.0),
          );
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  top: 12,
                  left: (constraints.maxWidth - width) / 2,
                  width: width,
                  height: width * math.sqrt2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.background,
                      border: Border.all(color: colors.border),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                if (showProgress)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
