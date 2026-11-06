import 'dart:convert';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/shared/widgets/web_view_unavailable.dart';
import 'dart:io';

import 'package:folders/core/services/local_content_server.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/features/viewer_text/screens/text_editor_screen.dart';
import 'package:folders/features/viewer_text/text_document.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

/// Renders an HTML page (with its relative CSS/JS/images) and lets the user
/// edit the source.
///
/// Opened files are untrusted: scripts are off until the user turns them on
/// for this page, the loopback mount serves only web-resource file types
/// (never documents or databases from the same folder), and navigation away
/// from the page is confirmed and handed to the system browser.
class HtmlViewerScreen extends StatefulWidget {
  final File file;
  const HtmlViewerScreen({super.key, required this.file});

  @override
  State<HtmlViewerScreen> createState() => _HtmlViewerScreenState();
}

class _HtmlViewerScreenState extends State<HtmlViewerScreen> {
  final _editorKey = GlobalKey<TextEditorPaneState>();
  // No web view on Linux: start on the source.
  bool _showSource = !Desktop.webViewsSupported;

  /// The source editor is built on first use: laying out a whole page's
  /// source in a hidden TextField would slow down showing the page.
  bool _sourceCreated = !Desktop.webViewsSupported;
  bool _dirty = false;
  Uri? _base;
  int _renderToken = 0;
  bool _scriptsEnabled = false;
  bool _pageHasScripts = false;

  @override
  void initState() {
    super.initState();
    // Served over loopback HTTP: Android blocks file:// access in WebViews
    // by default, and relative resources then resolve like on a web server.
    LocalContentServer.instance
        .mountDirectory(
          widget.file.parent.path,
          allowedExtensions: LocalContentServer.webPageExtensions,
        )
        .then((base) {
      if (!mounted) {
        LocalContentServer.instance.unmount(base);
        return;
      }
      setState(() => _base = base);
    });
    _detectScripts();
  }

  @override
  void dispose() {
    final base = _base;
    if (base != null) LocalContentServer.instance.unmount(base);
    super.dispose();
  }

  /// Only pages that actually contain script get the "scripts are off"
  /// notice.
  Future<void> _detectScripts() async {
    try {
      final head = await readHead(widget.file, 512 * 1024);
      final text = latin1.decode(head, allowInvalid: true).toLowerCase();
      final hasScripts = text.contains('<script') ||
          text.contains('javascript:') ||
          RegExp(r'<[a-z][^>]*\son[a-z]+\s*=').hasMatch(text);
      if (mounted && hasScripts) setState(() => _pageHasScripts = true);
    } catch (_) {}
  }

  Future<void> _save() async {
    final ok = await _editorKey.currentState?.save() ?? false;
    if (ok && mounted) {
      setState(() => _renderToken++);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    }
  }

  Future<NavigationActionPolicy> _onNavigate(NavigationAction action) async {
    final url = action.request.url;
    final base = _base;
    if (url == null || base == null) return NavigationActionPolicy.CANCEL;
    final text = url.toString();
    if (text.startsWith(base.toString()) ||
        text.startsWith('about:') ||
        text.startsWith('data:') ||
        text.startsWith('blob:')) {
      return NavigationActionPolicy.ALLOW;
    }
    // Leaving the page (or a sub-frame loading something external).
    if (action.isForMainFrame &&
        (url.scheme == 'http' || url.scheme == 'https' || url.scheme == 'mailto')) {
      _offerExternal(text);
    }
    return NavigationActionPolicy.CANCEL;
  }

  void _offerExternal(String url) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Link to $url', maxLines: 2, overflow: TextOverflow.ellipsis),
        action: SnackBarAction(
          label: 'Open',
          onPressed: () async {
            try {
              await InAppBrowser.openWithSystemBrowser(url: WebUri(url));
            } catch (_) {
              await Clipboard.setData(ClipboardData(text: url));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              }
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved changes?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.destructive,
                  foregroundColor: context.colors.destructiveForeground,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && context.mounted) Navigator.pop(context);
      },
      child: ExplorerScaffold(
        title: p.basename(widget.file.path),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showSource && _dirty)
              AppIconButton(
                icon: Icon(LucideIcons.save, color: context.colors.primary),
                tooltip: 'Save',
                onPressed: _save,
              ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(LucideIcons.appWindow, size: 16),
                    tooltip: 'Rendered page',
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(LucideIcons.code, size: 16),
                    tooltip: 'Source',
                  ),
                ],
                selected: {_showSource},
                onSelectionChanged: (s) => setState(() {
                  _showSource = s.first;
                  if (_showSource) _sourceCreated = true;
                }),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: EdgeInsets.only(top: DockedGlossyTopBar.contentTopInset(context)),
          child: IndexedStack(
            index: _showSource ? 1 : 0,
            children: [
              _buildRendered(),
              if (_sourceCreated)
                TextEditorPane(
                  key: _editorKey,
                  file: widget.file,
                  onDirtyChanged: (dirty) => setState(() => _dirty = dirty),
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRendered() {
    if (!Desktop.webViewsSupported) {
      return WebViewUnavailable(
        file: widget.file,
        title: "The page can't be shown here",
      );
    }
    final base = _base;
    if (base == null) return const ViewerLoading();
    final url = base.resolve(Uri.encodeComponent(p.basename(widget.file.path)));
    return Column(
      children: [
        if (_pageHasScripts && !_scriptsEnabled)
          ViewerNotice(
            icon: LucideIcons.shieldAlert,
            tone: Tone.warning,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            message: 'Scripts on this page are off. Turn them on only if you '
                'trust where the file came from.',
            actions: [
              TextButton(
                onPressed: () => setState(() => _scriptsEnabled = true),
                child: const Text('Enable scripts'),
              ),
            ],
          ),
        Expanded(
          child: InAppWebView(
            key: ValueKey('$_renderToken/$_scriptsEnabled'),
            initialUrlRequest: URLRequest(url: WebUri.uri(url)),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: _scriptsEnabled,
              javaScriptCanOpenWindowsAutomatically: false,
              useShouldOverrideUrlLoading: true,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
            ),
            shouldOverrideUrlLoading: (controller, action) => _onNavigate(action),
          ),
        ),
      ],
    );
  }
}
