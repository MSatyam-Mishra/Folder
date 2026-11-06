import 'dart:async';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/shared/widgets/web_view_unavailable.dart';
import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/local_content_server.dart';
import 'package:folders/features/viewer_3d/models/viewer_3d_models.dart';
import 'package:folders/features/viewer_3d/services/three_d_viewer_controller.dart';
import 'package:folders/features/viewer_3d/widgets/model_info_panel.dart';
import 'package:folders/features/viewer_3d/widgets/viewer_status_views.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

/// Offline 3D model viewer built on three.js running in a WebView.
///
/// The bundled viewer (`assets/viewer3d`) and the model's folder (or, for a
/// model in a project subfolder, that folder's parent, see [_servedRootFor])
/// are served by [LocalContentServer], so external resources referenced by
/// the model (glTF `.bin` buffers, OBJ `.mtl` libraries, textures, also in
/// sibling folders like `../Textures`) load with their relative paths.
///
/// Opening is parallel: the WebView is created on the first frame while the
/// server mounts the folders, the page starts downloading the model before
/// its scripts load, and the folder index used for fuzzy texture lookups is
/// built meanwhile and only awaited right before parsing.
///
/// Pops with `true` when a screenshot was saved next to the model, so the
/// caller can refresh its file listing.
class ThreeDViewerScreen extends StatefulWidget {
  const ThreeDViewerScreen({
    super.key,
    required this.file,
    this.originalFile,
  });

  /// The model the page loads.
  final File file;

  /// The file the user opened, when [file] was converted from it (e.g. a
  /// .blend shown as glTF): used for the title, details, screenshots and
  /// "Open with".
  final File? originalFile;

  @override
  State<ThreeDViewerScreen> createState() => _ThreeDViewerScreenState();
}

class _ThreeDViewerScreenState extends State<ThreeDViewerScreen> {
  static const _assetPrefix = 'assets/viewer3d';

  /// Width at which the info pane docks beside the canvas.
  static const _splitWidth = 840.0;

  /// Limits for indexing the model's folder (used to resolve textures whose
  /// references have the wrong case or absolute author paths).
  static const _indexMaxEntries = 4000;
  static const _indexMaxDepth = 3;
  static const _indexTimeLimit = Duration(milliseconds: 1500);

  /// Share of the index left for the parent folder's other files.
  static const _siblingMaxEntries = 1000;
  static const _siblingMaxDepth = 2;

  /// Formats whose files can name other files (buffers, materials, textures),
  /// so the page needs the folder index. Self-contained formats (glb, stl,
  /// ply, zip-based ones...) skip it.
  static const _formatsWithExternalFiles = {
    'gltf', 'obj', 'fbx', 'dae', '3ds', 'wrl', 'vrml', 'lwo', 'md2', 'usda',
    'usd',
  };

  /// The bundled viewer is mounted once per run and kept, so every viewer
  /// uses the same URLs for the three.js scripts.
  static Future<Uri>? _assetsMount;

  final LocalContentServer _server = LocalContentServer.instance;
  late final ThreeDViewerController _viewer;

  Uri? _modelMount;
  Uri? _filesMount;
  WebUri? _pageUrl;
  double _pageInset = 0;
  int? _fileSize;
  bool _started = false;

  /// Keeps the WebView's element (and the native view) when the layout
  /// around it changes; replaced only by [_reload].
  GlobalKey _webViewKey = GlobalKey(debugLabel: 'viewer3d');
  Widget? _webView;
  InAppWebViewController? _web;
  InAppWebViewController? _loadedBy;

  bool _showDockedPanel = true;
  bool _screenshotSaved = false;
  Timer? _screenshotTimeout;

  /// The file the user opened.
  File get _userFile => widget.originalFile ?? widget.file;

  String get _fileName => p.basename(_userFile.path);

  String get _extension {
    final ext = p.extension(widget.file.path).toLowerCase();
    return ext.startsWith('.') ? ext.substring(1) : ext;
  }

  @override
  void initState() {
    super.initState();
    _viewer = ThreeDViewerController()
      ..onScreenshot = _onScreenshot
      ..onLoaded = _onModelLoaded;
    // Created on the first frame: starting the browser engine is the slowest
    // step, so it runs while the server mounts the folders.
    _webView = _buildWebView();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _prepare();
    }
  }

  @override
  void dispose() {
    _screenshotTimeout?.cancel();
    _web = null;
    _unmount();
    _viewer.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Setup
  // ---------------------------------------------------------------------------

  Future<void> _prepare() async {
    if (!mounted) return;
    final background = Theme.of(context).brightness == Brightness.light
        ? ViewerBackground.light
        : ViewerBackground.dark;
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    try {
      final file = widget.file;
      final modelDir = Directory(p.normalize(p.absolute(file.parent.path)));
      final served = _servedRootFor(modelDir);
      final widened = !p.equals(served.path, modelDir.path);

      // Everything starts at once; only the stat and the mounts gate the
      // page. The index is served to the page when ready (it waits for it
      // only right before parsing).
      final statFuture = _userFile.stat();
      final assetsFuture = _viewerAssets(_server);
      final modelFuture = _server.mountDirectory(served.path);
      Future<Uri>? filesFuture;
      if (_formatsWithExternalFiles.contains(_extension)) {
        final index = _indexFolder(
          modelDir,
          widened ? served : null,
        ).catchError((Object _) => const <String>[]);
        filesFuture = _server.mount(
          (path) async => path == 'files.json'
              ? Uint8List.fromList(utf8.encode(jsonEncode(await index)))
              : null,
        );
      }
      _modelMount = await modelFuture;
      _filesMount = await filesFuture;
      final assets = await assetsFuture;
      final stat = await statFuture;
      if (!mounted) {
        _unmount();
        return;
      }
      if (stat.type == FileSystemEntityType.notFound) {
        _viewer.fail('This file no longer exists.');
        return;
      }
      _fileSize = stat.size;

      final folder = widened
          ? '${Uri.encodeComponent(p.basename(modelDir.path))}/'
          : '';
      final src = _modelMount!.resolve(
        '$folder${Uri.encodeComponent(p.basename(file.path))}',
      );
      final page = assets.replace(
        path: '${assets.path}index.html',
        queryParameters: {
          'src': src.toString(),
          'ext': _extension,
          'name': _fileName,
          'size': '${_fileSize ?? 0}',
          'bg': background.id,
          'inset': topInset.toStringAsFixed(1),
          if (_filesMount != null)
            'files': _filesMount!.resolve('files.json').toString(),
        },
      );
      _pageUrl = WebUri.uri(page);
      _pageInset = topInset;
      _loadPage();
    } catch (e, st) {
      debugPrint('3D viewer: setup failed: $e\n$st');
      _unmount();
      if (!mounted) return;
      _viewer.fail(
        "Couldn't start the 3D viewer.",
        detail: '$e',
        code: 'page_load',
      );
    }
  }

  static Future<Uri> _viewerAssets(LocalContentServer server) async {
    try {
      return await (_assetsMount ??= server.mountAssets(_assetPrefix));
    } catch (_) {
      _assetsMount = null;
      rethrow;
    }
  }

  /// Points the current WebView at the viewer page once both exist.
  void _loadPage() {
    final web = _web;
    final url = _pageUrl;
    if (web == null || url == null || identical(_loadedBy, web)) return;
    if (_viewer.phase == ViewerPhase.error) return;
    _loadedBy = web;
    _viewer.initialTopInset(_pageInset);
    web.loadUrl(urlRequest: URLRequest(url: url)).catchError((Object e) {
      if (mounted) {
        _viewer.fail(
          "Couldn't load the 3D viewer.",
          detail: '$e',
          code: 'page_load',
        );
      }
    });
  }

  void _unmount() {
    final model = _modelMount;
    final files = _filesMount;
    _modelMount = null;
    _filesMount = null;
    if (model != null) _server.unmount(model);
    if (files != null) _server.unmount(files);
  }

  /// Folder served to the page: the model's parent, so references into
  /// sibling folders (`../Textures/wood.png`, common in asset packs laid out
  /// as Models/ + Textures/) load. It stays at the model's own folder when
  /// that parent is a broad location (a storage, drive or filesystem root,
  /// the home or temp folder), so a model in Downloads doesn't expose or
  /// index the rest of the user's storage. Never more than one level up.
  static Directory _servedRootFor(Directory modelDir) {
    final dir = modelDir.path;
    final parent = p.dirname(dir);
    if (parent == dir || _isBroadFolder(parent)) return modelDir;
    return Directory(parent);
  }

  static bool _isBroadFolder(String path) {
    if (p.dirname(path) == path) return true;
    bool same(String? other) =>
        other != null &&
        other.isNotEmpty &&
        p.equals(p.normalize(p.absolute(other)), path);
    if (same(Platform.environment['HOME']) ||
        same(Platform.environment['USERPROFILE']) ||
        same(Directory.systemTemp.path)) {
      return true;
    }
    // Android volumes: /storage, /storage/emulated/0, /storage/1A2B-3C4D,
    // /mnt/media_rw/1A2B-3C4D, /sdcard.
    final parts = p.split(path);
    if (parts.length < 2 || parts.first != '/') return false;
    switch (parts[1]) {
      case 'storage':
        final volumeDepth = parts.length > 2 && parts[2] == 'emulated' ? 4 : 3;
        return parts.length <= volumeDepth;
      case 'mnt':
        return parts.length <= 4;
      case 'sdcard':
        return parts.length <= 2;
    }
    return false;
  }

  /// Paths relative to the model's folder (with `/`) of files near it,
  /// breadth first: the model's folder, then (when [parent] is served) the
  /// parent's other files and folders as `../Textures/a.png`.
  static Future<List<String>> _indexFolder(
    Directory modelDir,
    Directory? parent,
  ) async {
    final out = <String>[];
    final watch = Stopwatch()..start();

    Future<void> walk(Directory root, int maxDepth, int maxEntries) async {
      final limit = out.length + maxEntries;
      final queue = <(Directory, int)>[(root, 0)];
      bool full() =>
          out.length >= limit ||
          out.length >= _indexMaxEntries ||
          watch.elapsed >= _indexTimeLimit;
      while (queue.isNotEmpty && !full()) {
        final (dir, depth) = queue.removeAt(0);
        try {
          await for (final entity in dir.list(followLinks: false)) {
            final name = p.basename(entity.path);
            if (name.startsWith('.')) continue;
            if (entity is File) {
              out.add(
                p
                    .relative(entity.path, from: modelDir.path)
                    .replaceAll(r'\', '/'),
              );
              if (full()) break;
            } else if (entity is Directory &&
                depth < maxDepth &&
                !p.equals(entity.path, modelDir.path)) {
              queue.add((entity, depth + 1));
            }
          }
        } catch (_) {
          // Unreadable folder: skip it.
        }
      }
    }

    await walk(modelDir, _indexMaxDepth, _indexMaxEntries);
    if (parent != null) {
      await walk(parent, _siblingMaxDepth, _siblingMaxEntries);
    }
    return out;
  }

  void _reload() {
    _viewer.resetForReload();
    _web = null;
    setState(() {
      _webViewKey = GlobalKey(debugLabel: 'viewer3d');
      _webView = _buildWebView();
    });
    if (_pageUrl == null) _prepare();
  }

  Widget _buildWebView() {
    // No initial URL: the page is loaded by [_loadPage] once the server is
    // ready, which is usually before the native view finishes starting.
    return InAppWebView(
      key: _webViewKey,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        hardwareAcceleration: true,
        supportZoom: false,
        builtInZoomControls: false,
        displayZoomControls: false,
        disableContextMenu: true,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        overScrollMode: OverScrollMode.NEVER,
        disallowOverScroll: true,
        allowsLinkPreview: false,
        isInspectable: kDebugMode,
      ),
      // Let the canvas own every touch (rotate / pinch / pan).
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: ThreeDViewerController.handlerName,
          callback: (args) {
            _viewer.handleMessage(args.isEmpty ? null : args.first);
            return null;
          },
        );
        _viewer.attach(controller);
        _web = controller;
        _loadPage();
      },
      onReceivedError: (controller, request, error) {
        if (!_isMainFrame(request)) return;
        _viewer.fail(
          "Couldn't load the 3D viewer.",
          detail: error.description,
          code: 'page_load',
        );
      },
      onReceivedHttpError: (controller, request, response) {
        if (!_isMainFrame(request)) return;
        _viewer.fail(
          "Couldn't load the 3D viewer.",
          detail: 'HTTP ${response.statusCode} ${response.reasonPhrase ?? ''}',
          code: 'page_load',
        );
      },
      onRenderProcessGone: (controller, detail) => _onRendererGone(),
      onWebContentProcessDidTerminate: (controller) => _onRendererGone(),
      onConsoleMessage: kDebugMode
          ? (controller, message) => debugPrint('3D viewer console: ${message.message}')
          : null,
    );
  }

  bool _isMainFrame(WebResourceRequest request) {
    if (request.isForMainFrame != null) return request.isForMainFrame!;
    return request.url.path.endsWith('/index.html');
  }

  void _onRendererGone() {
    _viewer.detach();
    _viewer.fail(
      'The 3D view stopped unexpectedly. The model may be too large for this '
      "device's memory.",
      code: 'render_process_gone',
    );
  }

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  void _onModelLoaded() {
    if (!mounted || _viewer.warnings.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          _viewer.warnings.length == 1
              ? _viewer.warnings.first
              : 'Some parts of the model could not be loaded.',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        action: SnackBarAction(label: 'Details', onPressed: _showInfo),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _takeScreenshot() {
    if (!_viewer.isReady || _screenshotTimeout != null) return;
    _screenshotTimeout = Timer(const Duration(seconds: 15), () {
      _screenshotTimeout = null;
      _snack("Couldn't capture a screenshot.");
    });
    _viewer.requestScreenshot();
  }

  Future<void> _onScreenshot(String? dataUrl, String? error) async {
    _screenshotTimeout?.cancel();
    _screenshotTimeout = null;
    if (!mounted) return;
    if (dataUrl == null || !dataUrl.startsWith('data:image/png;base64,')) {
      _snack("Couldn't capture a screenshot${error == null ? '' : ': $error'}");
      return;
    }
    try {
      final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
      final target = await _screenshotTarget();
      await target.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      _screenshotSaved = true;
      _snack('Screenshot saved as ${p.basename(target.path)}');
    } catch (e) {
      if (!mounted) return;
      _snack("Couldn't save the screenshot: $e");
    }
  }

  Future<File> _screenshotTarget() async {
    final dir = _userFile.parent.path;
    final stem = p.basenameWithoutExtension(_userFile.path);
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    var candidate = File(p.join(dir, '${stem}_$stamp.png'));
    var n = 2;
    while (await candidate.exists()) {
      candidate = File(p.join(dir, '${stem}_${stamp}_$n.png'));
      n++;
    }
    return candidate;
  }

  Future<void> _openWithAnotherApp() async {
    try {
      final result = await OpenFilex.open(_userFile.path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        _snack(result.type == ResultType.noAppToOpen
            ? 'No other app can open this file.'
            : "Couldn't open the file: ${result.message}");
      }
    } catch (e) {
      if (mounted) _snack("Couldn't open the file: $e");
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isSplit(BuildContext context) =>
      AdaptiveSplitView.isSplit(context, minWidthForSplit: _splitWidth);

  void _showInfo() {
    if (!mounted) return;
    if (_isSplit(context)) {
      setState(() => _showDockedPanel = true);
      return;
    }
    AppSheet.show<void>(
      context,
      style: SheetStyle.side,
      maxHeightFraction: 0.72,
      child: ModelInfoPanel(
        controller: _viewer,
        fileName: _fileName,
        fileSize: _fileSize,
        scrollable: false,
        onScreenshot: () {
          Navigator.of(context).maybePop();
          _takeScreenshot();
        },
      ),
    );
  }

  void _toggleInfo() {
    if (_isSplit(context)) {
      setState(() => _showDockedPanel = !_showDockedPanel);
    } else {
      _showInfo();
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // The viewer is a three.js page, and Linux has no web view.
    if (!Desktop.webViewsSupported) {
      return ExplorerScaffold(
        title: _fileName,
        body: WebViewUnavailable(
          file: widget.originalFile ?? widget.file,
          title: "The 3D viewer isn't available here",
          inBrowser: false,
        ),
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_screenshotSaved);
      },
      child: ListenableBuilder(
        listenable: _viewer,
        builder: (context, _) {
          final split = _isSplit(context);
          return ExplorerScaffold(
            title: _fileName,
            trailing: _buildActions(context, split),
            body: _buildBody(context, split),
          );
        },
      ),
    );
  }

  /// The canvas is always the first child of the same Row, whether or not
  /// the details pane is docked: moving the WebView to another place in the
  /// tree destroys the native view and reloads the model.
  Widget _buildBody(BuildContext context, bool split) {
    final canvas = _buildCanvasArea(context);
    final showPanel = split && _showDockedPanel;
    final fold = FoldInfo.of(context);
    final hinge = fold != null && fold.isVertical ? fold.bounds : null;
    // Opaque card: blurs can't sample the WebView on Android.
    final panel = !showPanel
        ? null
        : AppPanel(
            margin: EdgeInsets.fromLTRB(
              0,
              DockedGlossyTopBar.contentTopInset(context) + 12,
              12,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            child: ModelInfoPanel(
              controller: _viewer,
              fileName: _fileName,
              fileSize: _fileSize,
              onScreenshot: _takeScreenshot,
              onClose: () => setState(() => _showDockedPanel = false),
            ),
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: canvas),
        if (panel != null && hinge != null) ...[
          // Book posture: canvas left of the hinge, pane right of it.
          SizedBox(width: hinge.width),
          SizedBox(
            width: MediaQuery.sizeOf(context).width - hinge.right,
            child: panel,
          ),
        ] else if (panel != null)
          SizedBox(width: 340, child: panel),
      ],
    );
  }

  Widget _buildCanvasArea(BuildContext context) {
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final phase = _viewer.phase;
    final webView = _webView;
    // Keeps framing right after rotation / window resizes (no-op otherwise).
    _viewer.updateTopInset(topInset);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Full-bleed canvas (it may sit behind the floating top bar).
        if (webView != null && phase != ViewerPhase.error) webView,
        if (phase == ViewerPhase.preparing || phase == ViewerPhase.loading)
          Padding(
            padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
            child: Center(
              child: ViewerProgressCard(
                label: _viewer.progressLabel,
                progress: _viewer.progress,
              ),
            ),
          ),
        if (phase == ViewerPhase.error)
          Padding(
            padding: EdgeInsets.fromLTRB(20, topInset + 8, 20, bottomInset + 20),
            child: ViewerErrorView(
              message: _viewer.errorMessage ?? 'The model could not be displayed.',
              detail: _viewer.errorDetail,
              onOpenWith: _openWithAnotherApp,
              onRetry: _viewer.canRetry ? _reload : null,
            ),
          ),
        if (phase == ViewerPhase.ready && _viewer.clips.isNotEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: bottomInset + 16,
            child: Center(child: _AnimationBar(controller: _viewer)),
          ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, bool split) {
    final ready = _viewer.isReady;

    Widget toggle({
      required IconData icon,
      required String tooltip,
      required bool value,
      required ValueChanged<bool> onChanged,
    }) {
      return ToolButton(
        icon: icon,
        tooltip: tooltip,
        size: 40,
        iconSize: 20,
        selected: ready && value,
        onPressed: ready ? () => onChanged(!value) : null,
      );
    }

    final reset = AppIconButton(
      icon: const Icon(LucideIcons.scan),
      tooltip: 'Reset view',
      onPressed: ready ? _viewer.resetView : null,
    );
    final autoRotate = toggle(
      icon: LucideIcons.rotate3d,
      tooltip: 'Auto-rotate',
      value: _viewer.autoRotate,
      onChanged: _viewer.setAutoRotate,
    );
    final info = ToolButton(
      icon: LucideIcons.panelRight,
      tooltip: 'Details & controls',
      size: 40,
      iconSize: 20,
      selected: split && _showDockedPanel,
      onPressed: _toggleInfo,
    );

    if (!split) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          reset,
          autoRotate,
          info,
          _MoreMenu(
            controller: _viewer,
            enabled: ready,
            onScreenshot: _takeScreenshot,
            onOpenWith: _openWithAnotherApp,
          ),
          const SizedBox(width: 4),
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        reset,
        autoRotate,
        if (_viewer.hasMeshes)
          toggle(
            icon: LucideIcons.box,
            tooltip: 'Wireframe',
            value: _viewer.wireframe,
            onChanged: _viewer.setWireframe,
          ),
        toggle(
          icon: LucideIcons.grid3x3,
          tooltip: 'Ground grid',
          value: _viewer.grid,
          onChanged: _viewer.setGrid,
        ),
        if (ready && _viewer.clips.isNotEmpty)
          _AnimationMenu(controller: _viewer),
        AppIconButton(
          icon: const Icon(LucideIcons.camera),
          tooltip: 'Screenshot',
          onPressed: ready ? _takeScreenshot : null,
        ),
        const ToolDivider(),
        info,
        const SizedBox(width: 4),
      ],
    );
  }
}

/// Overflow menu for phones: less common toggles and actions.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.controller,
    required this.enabled,
    required this.onScreenshot,
    required this.onOpenWith,
  });

  final ThreeDViewerController controller;
  final bool enabled;
  final VoidCallback onScreenshot;
  final VoidCallback onOpenWith;

  @override
  Widget build(BuildContext context) {
    return MenuIconButton<String>(
      onSelected: (value) {
        switch (value) {
          case 'wireframe':
            controller.setWireframe(!controller.wireframe);
          case 'grid':
            controller.setGrid(!controller.grid);
          case 'axes':
            controller.setAxes(!controller.axes);
          case 'animations':
            _showAnimationSheet(context, controller);
          case 'screenshot':
            onScreenshot();
          case 'open':
            onOpenWith();
        }
      },
      itemBuilder: (context) => [
        if (enabled && controller.hasMeshes)
          menuItem(
            value: 'wireframe',
            icon: LucideIcons.box,
            label: 'Wireframe',
            checked: controller.wireframe,
          ),
        if (enabled)
          menuItem(
            value: 'grid',
            icon: LucideIcons.grid3x3,
            label: 'Ground grid',
            checked: controller.grid,
          ),
        if (enabled)
          menuItem(
            value: 'axes',
            icon: LucideIcons.move3d,
            label: 'Axes',
            checked: controller.axes,
          ),
        if (enabled && controller.clips.isNotEmpty)
          menuItem(
            value: 'animations',
            icon: LucideIcons.film,
            label: 'Animations…',
          ),
        if (enabled) const PopupMenuDivider(),
        if (enabled)
          menuItem(
            value: 'screenshot',
            icon: LucideIcons.camera,
            label: 'Save screenshot',
          ),
        menuItem(
          value: 'open',
          icon: LucideIcons.externalLink,
          label: 'Open with another app',
        ),
      ],
    );
  }
}

void _showAnimationSheet(BuildContext context, ThreeDViewerController controller) {
  AppSheet.show<void>(
    context,
    maxHeightFraction: 0.5,
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final colors = context.colors;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Animations', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final entry in _clipEntries(controller))
              ListRow(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                selected: controller.animationIndex == entry.$1,
                leading: IconBox(
                  controller.animationIndex == entry.$1 &&
                          controller.animationPlaying
                      ? LucideIcons.pause
                      : LucideIcons.play,
                  size: 32,
                  color: controller.animationIndex == entry.$1
                      ? colors.primary
                      : colors.foreground,
                ),
                title: entry.$2,
                onTap: () => controller.animationIndex == entry.$1
                    ? controller.toggleAnimation()
                    : controller.playAnimation(entry.$1),
              ),
            if (controller.animationIndex != -2)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.stopAnimation,
                  icon: const Icon(LucideIcons.square, size: 14),
                  label: const Text('Stop'),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// (index, label) pairs for the clip pickers; -1 plays all clips together.
List<(int, String)> _clipEntries(ThreeDViewerController controller) => [
      for (final clip in controller.clips)
        (clip.index, '${clip.name}  ·  ${clip.duration.toStringAsFixed(1)} s'),
      if (controller.clips.length > 1) (-1, 'Play all together'),
    ];

/// Top-bar animation picker (wide screens).
class _AnimationMenu extends StatelessWidget {
  const _AnimationMenu({required this.controller});

  final ThreeDViewerController controller;

  @override
  Widget build(BuildContext context) {
    return MenuIconButton<int>(
      tooltip: 'Animations',
      icon: LucideIcons.film,
      onSelected: (value) {
        if (value == -3) {
          controller.stopAnimation();
        } else {
          controller.playAnimation(value);
        }
      },
      itemBuilder: (context) => [
        for (final entry in _clipEntries(controller))
          menuItem(
            value: entry.$1,
            label: entry.$2,
            icon: LucideIcons.clapperboard,
            checked: controller.animationIndex == entry.$1,
          ),
        if (controller.animationIndex != -2) ...[
          const PopupMenuDivider(),
          menuItem(value: -3, icon: LucideIcons.square, label: 'Stop'),
        ],
      ],
    );
  }
}

/// Floating play/pause pill with the current clip name.
class _AnimationBar extends StatelessWidget {
  const _AnimationBar({required this.controller});

  final ThreeDViewerController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final clips = controller.clips;
    final index = controller.animationIndex;
    final name = index == -1
        ? 'All animations'
        : index >= 0 && index < clips.length
            ? clips[index].name
            : 'Animations';
    return AppPanel(
      borderRadius: 999,
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: colors.primary,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: controller.toggleAnimation,
              child: Tooltip(
                message: controller.animationPlaying ? 'Pause' : 'Play',
                child: SizedBox.square(
                  dimension: 36,
                  child: Icon(
                    controller.animationPlaying
                        ? LucideIcons.pause
                        : LucideIcons.play,
                    size: 16,
                    color: colors.primaryForeground,
                  ),
                ),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: PopupMenuButton<int>(
              tooltip: 'Choose animation',
              onSelected: controller.playAnimation,
              position: PopupMenuPosition.over,
              itemBuilder: (context) => [
                for (final entry in _clipEntries(controller))
                  menuItem(
                    value: entry.$1,
                    label: entry.$2,
                    icon: LucideIcons.clapperboard,
                    checked: controller.animationIndex == entry.$1,
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      LucideIcons.chevronsUpDown,
                      size: 14,
                      color: colors.mutedForeground,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
