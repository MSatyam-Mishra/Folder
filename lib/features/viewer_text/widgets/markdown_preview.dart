import 'dart:async';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/shared/widgets/web_view_unavailable.dart';
import 'dart:convert';
import 'dart:io';

import 'package:folders/core/services/local_content_server.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders Markdown (GitHub flavoured) to HTML in a WebView. Relative image
/// links resolve against the document's folder via the loopback server.
class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    super.key,
    required this.markdown,
    required this.file,
    this.topPadding = 0,
  });

  final String markdown;
  final File file;
  final double topPadding;

  static String toHtml(String markdown) => md.markdownToHtml(
        markdown,
        extensionSet: md.ExtensionSet.gitHubWeb,
        // GFM tag filter: <script>, <iframe>, <style>... are escaped.
        enableTagfilter: true,
      );

  /// The page never runs its own scripts: content is pushed in from Dart
  /// with evaluateJavascript, which a page CSP doesn't apply to. This blocks
  /// `<script>`, inline handlers (`<img onerror>`), fetch/XHR and forms, so a
  /// hostile document can't read files next to it through the loopback
  /// mount. Remote images (badges) still load.
  static const _csp = "default-src 'none'; script-src 'none'; "
      "img-src * data: blob:; media-src * data: blob:; font-src * data:; "
      "style-src 'unsafe-inline'; connect-src 'none'; form-action 'none'; "
      "frame-src 'none'; object-src 'none'; base-uri 'none'";

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  InAppWebViewController? _controller;
  Uri? _base;
  Timer? _debounce;
  bool _pageReady = false;

  @override
  void initState() {
    super.initState();
    // Relative links only need images/media; nothing else is served.
    LocalContentServer.instance
        .mountDirectory(
          widget.file.parent.path,
          allowedExtensions: LocalContentServer.imageAndMediaExtensions,
        )
        .then((base) {
      if (!mounted) {
        LocalContentServer.instance.unmount(base);
        return;
      }
      setState(() => _base = base);
    });
  }

  @override
  void didUpdateWidget(MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.markdown != widget.markdown ||
        oldWidget.topPadding != widget.topPadding) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 250), _pushContent);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    final base = _base;
    if (base != null) LocalContentServer.instance.unmount(base);
    super.dispose();
  }

  Future<void> _pushContent() async {
    final controller = _controller;
    if (controller == null || !_pageReady) return;
    final html = MarkdownPreview.toHtml(widget.markdown);
    await controller.evaluateJavascript(
      source: 'document.getElementById("content").innerHTML = '
          '${jsonEncode(html)};'
          'document.body.style.paddingTop = "${widget.topPadding + 16}px";',
    );
  }

  String _page(BuildContext context) {
    final c = context.colors;
    String hex(Color color) =>
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    String rgba(Color color, double alpha) =>
        'rgba(${(color.r * 255).round()}, ${(color.g * 255).round()}, '
        '${(color.b * 255).round()}, $alpha)';
    final dark = context.isDarkMode;
    return """<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="${MarkdownPreview._csp}">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: ${dark ? 'dark' : 'light'}; }
  body { margin: 0; padding: ${widget.topPadding + 16}px 20px 48px;
    font: 15px/1.65 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: ${hex(c.foreground)}; background: ${hex(c.background)};
    word-wrap: break-word; -webkit-text-size-adjust: 100%; }
  #content { max-width: 780px; margin: 0 auto; }
  h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 600;
    letter-spacing: -0.01em; margin: 1.6em 0 0.6em; }
  h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
  #content > :first-child { margin-top: 0; }
  p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
  a { color: ${hex(c.primary)}; text-underline-offset: 3px; }
  img { max-width: 100%; border-radius: 8px; }
  pre { background: ${hex(c.muted)}; border: 1px solid ${hex(c.border)};
    padding: 12px 14px; border-radius: 8px; overflow-x: auto; line-height: 1.5; }
  code { font-family: ui-monospace, "SF Mono", "JetBrains Mono", Menlo,
    Consolas, monospace; font-size: .875em; }
  :not(pre) > code { background: ${hex(c.muted)}; padding: 2px 6px;
    border-radius: 6px; }
  blockquote { padding: 0 1em; border-left: 3px solid ${hex(c.border)};
    color: ${hex(c.mutedForeground)}; }
  table { border-collapse: collapse; display: block; overflow-x: auto; }
  th, td { border: 1px solid ${hex(c.border)}; padding: 6px 12px; }
  th { background: ${rgba(c.muted, 0.6)}; font-weight: 600; text-align: left; }
  h1, h2 { border-bottom: 1px solid ${hex(c.border)}; padding-bottom: .3em; }
  hr { border: 0; border-top: 1px solid ${hex(c.border)}; margin: 2em 0; }
  input[type=checkbox] { margin-right: .5em; accent-color: ${hex(c.primary)}; }
  ::selection { background: ${rgba(c.primary, 0.25)}; }
</style></head><body><div id="content">${MarkdownPreview.toHtml(widget.markdown)}</div></body></html>""";
  }

  @override
  Widget build(BuildContext context) {
    if (!Desktop.webViewsSupported) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPadding),
        child: WebViewUnavailable(
          file: widget.file,
          title: "The preview can't be shown here",
        ),
      );
    }
    final base = _base;
    if (base == null) return const ViewerLoading();
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _page(context),
        baseUrl: WebUri.uri(base),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        transparentBackground: true,
        javaScriptEnabled: true,
        useShouldOverrideUrlLoading: true,
      ),
      onWebViewCreated: (c) => _controller = c,
      onLoadStop: (_, _) {
        _pageReady = true;
      },
      shouldOverrideUrlLoading: (controller, action) async {
        // Keep the preview in place: allow the page itself and in-page
        // anchors, block navigation to other documents.
        final url = action.request.url?.toString() ?? '';
        final page = url.split('#').first;
        return page == base.toString() || page.isEmpty || url.startsWith('about:')
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
    );
  }
}
