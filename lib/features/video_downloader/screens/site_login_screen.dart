import 'package:folders/core/services/video_downloader/cookie_store.dart';
import 'package:folders/core/services/video_downloader/netscape_cookies.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Opens [site]'s sign-in page in a web view; when the user taps Done,
/// returns the cookies the site left (null if they went back). Not on
/// Linux, which has no web view here (`Desktop.webViewsSupported`).
Future<List<NetscapeCookie>?> showSiteLogin(
  BuildContext context, {
  required CookieSite site,
  String? userAgent,
}) =>
    Navigator.push<List<NetscapeCookie>>(
      context,
      MaterialPageRoute(builder: (_) => SiteLoginScreen(site: site, userAgent: userAgent)),
    );

/// Forgets [site]'s cookies in the web view too, so the next sign-in
/// starts afresh. Best effort.
Future<void> clearWebViewCookies(CookieSite site) async {
  try {
    final manager = CookieManager.instance();
    for (final url in site.cookieUrls) {
      await manager.deleteCookies(url: WebUri(url));
      await manager.deleteCookies(url: WebUri(url), domain: '.${site.domain}');
    }
  } catch (e) {
    debugPrint('Video downloader: web view cookies not cleared ($e)');
  }
}

class SiteLoginScreen extends StatefulWidget {
  const SiteLoginScreen({super.key, required this.site, this.userAgent});

  final CookieSite site;

  /// The downloader's User-Agent, so the site sees the same browser as
  /// yt-dlp later; null for the web view's own.
  final String? userAgent;

  @override
  State<SiteLoginScreen> createState() => _SiteLoginScreenState();
}

class _SiteLoginScreenState extends State<SiteLoginScreen> {
  InAppWebViewController? _web;
  double _progress = 0;
  bool _reading = false;

  /// Google said this browser may not be secure.
  bool _refused = false;

  CookieSite get _site => widget.site;

  Future<void> _done() async {
    setState(() => _reading = true);
    final found = <String, NetscapeCookie>{};
    try {
      final manager = CookieManager.instance();
      for (final url in _site.cookieUrls) {
        final cookies = await manager.getCookies(url: WebUri(url), webViewController: _web);
        for (final c in cookies) {
          final cookie = _toNetscape(c);
          if (cookie != null && cookie.isFor(_site.domain)) found[cookie.key] = cookie;
        }
      }
    } catch (e) {
      debugPrint('Video downloader: cookies not read ($e)');
    }
    if (!mounted) return;
    setState(() => _reading = false);
    if (found.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${_site.name} left no cookies yet. Sign in, wait for the page to load, then tap Done.'),
      ));
      return;
    }
    Navigator.pop(context, found.values.toList());
  }

  /// Android gives only names and values; the others give everything.
  NetscapeCookie? _toNetscape(Cookie c) {
    final domain = c.domain;
    final expires = c.expiresDate;
    return NetscapeCookies.make(
      domain: domain == null || domain.isEmpty ? '.${_site.domain}' : domain,
      // A cookie for one host only has no dot; Android's (no domain) are
      // the whole site's.
      includeSubdomains: domain == null || domain.isEmpty || domain.startsWith('.'),
      path: c.path ?? '/',
      secure: c.isSecure ?? true,
      httpOnly: c.isHttpOnly ?? false,
      expires: c.isSessionOnly == true ? 0 : NetscapeCookies.expiryFrom(expires),
      name: c.name,
      value: '${c.value ?? ''}',
    );
  }

  void _pageLoaded(WebUri? url) {
    final refused = url != null &&
        url.host == 'accounts.google.com' &&
        url.path.contains('/signin/rejected');
    if (refused != _refused) setState(() => _refused = refused);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ExplorerScaffold(
      title: 'Sign in to ${_site.name}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconButton(
            icon: const Icon(LucideIcons.rotateCw),
            tooltip: 'Reload',
            onPressed: () => _web?.reload(),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 8),
            child: FilledButton.icon(
              onPressed: _reading ? null : _done,
              icon: _reading
                  ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(LucideIcons.check, size: 16),
              label: const Text('Done'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(top: DockedGlossyTopBar.contentTopInset(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ViewerNotice(
              icon: _refused ? LucideIcons.triangleAlert : LucideIcons.info,
              tone: _refused ? Tone.warning : Tone.neutral,
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              message: _refused
                  ? "Google won't sign in inside this app. Go back and import a "
                      'cookie file or paste cookies instead (see How to use cookies?).'
                  : 'Sign in, then tap Done. Folders keeps only ${_site.domain} '
                      'cookies, on this device, and sends them only to yt-dlp.'
                      '${_site.id == CookieSite.youtube.id ? ' Google sometimes refuses to sign in inside apps; '
                          'a cookie file works then.' : ''}',
            ),
            if (_progress < 1)
              LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress,
                minHeight: 2,
                backgroundColor: colors.muted,
              ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_site.loginUrl)),
                initialSettings: InAppWebViewSettings(
                  userAgent: widget.userAgent,
                  javaScriptEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  sharedCookiesEnabled: true,
                  supportMultipleWindows: false,
                ),
                onWebViewCreated: (controller) => _web = controller,
                onProgressChanged: (_, progress) {
                  if (mounted) setState(() => _progress = progress / 100);
                },
                onLoadStop: (_, url) => _pageLoaded(url),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
